import Foundation
import AppKit
import Darwin

protocol Desktop: Sendable {
    func close() async throws -> Bool
    func open() async throws
}

private final class RememberedDesktop: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL?) { lock.lock(); value = url; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return value }
}

struct DesktopLaunchPlan {
    static let bundleID = "com.openai.codex"
    static func choose(captured: URL?, registered: URL?, bundleID: String = bundleID, installed: [URL] = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")]) -> URL? {
        for url in [captured, registered].compactMap({ $0 }) + installed {
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
                  let executable = bundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            return url.standardizedFileURL
        }
        return nil
    }
}

struct DesktopRelauncher: Sendable {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ action: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; action() } }
    }
    let launch: @Sendable (URL) async throws -> Void
    let fallback: @Sendable (URL) async throws -> Void
    let isRunning: @Sendable (URL) async -> Bool
    let wait: @Sendable (Duration) async -> Void
    let launchTimeout: Duration

    init(launch: @escaping @Sendable (URL) async throws -> Void,
         fallback: @escaping @Sendable (URL) async throws -> Void,
         isRunning: @escaping @Sendable (URL) async -> Bool,
         wait: @escaping @Sendable (Duration) async -> Void,
         launchTimeout: Duration = .seconds(15)) {
        self.launch = launch; self.fallback = fallback; self.isRunning = isRunning
        self.wait = wait; self.launchTimeout = launchTimeout
    }

    func open(_ bundle: URL) async throws {
        if await isRunning(bundle) { return }
        var firstError: Error?
        do { try await boundedLaunch(bundle, launcher: launch) } catch { firstError = error }
        if await observe(bundle, attempts: 32) { return }
        var fallbackError: Error?
        do { try await boundedLaunch(bundle, launcher: fallback) } catch { fallbackError = error }
        if await observe(bundle, attempts: 80) { return }
        let details = [firstError, fallbackError].compactMap { $0.map(safeMessage) }.joined(separator: " ")
        throw AccountError.message("Codex wurde nach dem Öffnen nicht als laufender Prozess bestätigt. \(details) Bitte \(bundle.path) manuell öffnen.")
    }

    private func boundedLaunch(_ bundle: URL, launcher: @escaping @Sendable (URL) async throws -> Void) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached {
                do { try await launcher(bundle); once.run { continuation.resume() } }
                catch { once.run { continuation.resume(throwing: error) } }
            }
            Task.detached {
                try? await Task.sleep(for: launchTimeout)
                once.run { continuation.resume(throwing: AccountError.message("Codex-Startaufruf hat nicht rechtzeitig geantwortet.")) }
            }
        }
    }

    private func observe(_ bundle: URL, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if await isRunning(bundle) { return true }
            await wait(.milliseconds(250))
        }
        return await isRunning(bundle)
    }
}

struct LiveDesktop: Desktop {
    let bundleID: String
    let installed: [URL]
    private let remembered = RememberedDesktop()
    init(bundleID: String = DesktopLaunchPlan.bundleID, installed: [URL] = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")]) { self.bundleID = bundleID; self.installed = installed }

    struct ProcessIdentity: Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicros: UInt64
        init?(pid: pid_t) {
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
            self.pid = pid; startSeconds = info.pbi_start_tvsec; startMicros = info.pbi_start_tvusec
        }
        var isAlive: Bool {
            guard let current = Self(pid: pid) else { return kill(pid, 0) == 0 || errno == EPERM }
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
               info.pbi_status == SZOMB { return false }
            return current.startSeconds == startSeconds && current.startMicros == startMicros
        }
    }

    static func waitForExit(processes: [ProcessIdentity], attempts: Int, wait: @Sendable (Duration) async -> Void) async -> Bool {
        for _ in 0..<attempts {
            if processes.allSatisfy({ !$0.isAlive }) { return true }
            await wait(.milliseconds(250))
        }
        return processes.allSatisfy { !$0.isAlive }
    }

    static func isBundleRunning(_ bundle: URL) -> Bool {
        guard let executable = Bundle(url: bundle)?.executableURL else { return false }
        let desired = executable.resolvingSymlinksInPath().path
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
               URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == desired { return true }
        }
        return false
    }

    static func runningApps(bundleID: String) -> [(NSRunningApplication, URL)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        var matches: [(NSRunningApplication, URL)] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard let range = executable.range(of: ".app/Contents/MacOS/") else { continue }
            let bundle = URL(fileURLWithPath: String(executable[..<range.lowerBound]) + ".app")
            guard Bundle(url: bundle)?.bundleIdentifier == bundleID,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            matches.append((app, bundle))
        }
        return matches
    }

    func close() async throws -> Bool {
        let discovered = Self.runningApps(bundleID: bundleID)
        let apps = discovered.map(\.0)
        if let bundle = discovered.first?.1 { remembered.set(bundle) }
        if apps.isEmpty { return false }
        let pids = apps.map(\.processIdentifier)
        let originals = pids.compactMap(ProcessIdentity.init(pid:))
        guard originals.count == pids.count else { throw AccountError.message("Codex-Prozessidentität vor dem Beenden nicht lesbar. Anmeldung bleibt unverändert.") }
        let accepted = await MainActor.run { apps.allSatisfy { $0.terminate() } }
        guard accepted else { throw AccountError.message("Codex hat das Beenden abgelehnt. Bitte laufende Aufgaben beenden und erneut versuchen.") }
        let exited = await Task.detached {
            await Self.waitForExit(processes: originals, attempts: 120) { duration in
                try? await Task.sleep(for: duration)
            }
        }.value
        if exited { return true }
        throw AccountError.message("Codex ist nach 30 Sekunden noch geöffnet (Prozess \(pids.map(String.init).joined(separator: ", "))). Die Anmeldung wurde nicht verändert. Bitte laufende Aufgaben oder den Beenden-Dialog in Codex abschließen und erneut wechseln. Falls Codex danach geschlossen ist, mit 'Codex öffnen' starten.")
    }

    func open() async throws {
        guard let bundle = DesktopLaunchPlan.choose(
            captured: remembered.get(),
            registered: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            bundleID: bundleID,
            installed: installed
        ) else { throw AccountError.message("Codex Desktop wurde nicht an einem gültigen Installationsort gefunden.") }
        let relauncher = DesktopRelauncher(
            launch: { url in
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                var environment = ProcessInfo.processInfo.environment
                for key in ["CODEX_HOME", "CODEX_CLI_PATH", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] { environment[key] = nil }
                config.environment = environment
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            },
            fallback: { url in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", url.path]
                var environment = ProcessInfo.processInfo.environment
                for key in ["CODEX_HOME", "CODEX_CLI_PATH", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] { environment[key] = nil }
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                for _ in 0..<100 { if !process.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
                if process.isRunning { process.terminate(); for _ in 0..<10 { if !process.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }; if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AccountError.message("LaunchServices konnte Codex nicht öffnen.") }
            },
            isRunning: { url in
                Self.isBundleRunning(url)
            },
            wait: { interval in
                await Task.detached { try? await Task.sleep(for: interval) }.value
            }
        )
        try await relauncher.open(bundle)
    }
}
