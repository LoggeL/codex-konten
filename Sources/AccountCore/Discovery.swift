import AppKit
import Foundation
struct CLIDiscovery {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock(); var bytes = Data()
        func append(_ data:Data) { lock.lock(); defer { lock.unlock() }; if bytes.count < 1024 * 1024 { bytes.append(data) } }
        func value() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    static let candidates = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
    static func locate(environment:[String:String] = ProcessInfo.processInfo.environment, desktop:URL? = nil) throws -> URL {
        let fm = FileManager.default
        if let override = environment["CODEX_CLI_PATH"], override.hasPrefix("/"), fm.isExecutableFile(atPath:override) { return URL(fileURLWithPath:override) }
        if let command = environment["CODEX_CLI_PATH"], !command.isEmpty, !command.contains("/") {
            for dir in (environment["PATH"] ?? "").split(separator:":") where dir.hasPrefix("/") { let p = URL(fileURLWithPath:String(dir)).appendingPathComponent(command); if fm.isExecutableFile(atPath:p.path) { return p } }
        }
        var bundles = [desktop, NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex"), URL(fileURLWithPath:"/Applications/ChatGPT.app"), URL(fileURLWithPath:"/Applications/Codex.app")].compactMap { $0 }
        bundles = bundles.filter { fm.fileExists(atPath:$0.path) }
        for bundle in bundles { for path in candidates { let p = bundle.appendingPathComponent(path); if fm.isExecutableFile(atPath:p.path) { return p } } }
        for dir in (environment["PATH"] ?? "").split(separator:":") where dir.hasPrefix("/") { let p = URL(fileURLWithPath:String(dir)).appendingPathComponent("codex"); if fm.isExecutableFile(atPath:p.path) { return p } }
        let shell = Process(); let output = Pipe(); let capture = Capture()
        shell.executableURL = URL(fileURLWithPath:environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-l","-c", "printf '\\0%s\\0' \"$(command -v codex)\""]
        shell.environment = environment; shell.standardOutput = output; shell.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
        if (try? shell.run()) != nil {
            for _ in 0..<200 { if !shell.isRunning { break }; usleep(10_000) }
            if shell.isRunning { shell.terminate(); for _ in 0..<20 { if !shell.isRunning { break }; usleep(10_000) }; if shell.isRunning { kill(shell.processIdentifier,SIGKILL) } }
            shell.waitUntilExit(); output.fileHandleForReading.readabilityHandler = nil
            let fields = String(decoding:capture.value(),as:UTF8.self).split(separator:"\0",omittingEmptySubsequences:false)
            if shell.terminationStatus == 0, fields.count >= 3 { let path = String(fields[fields.count-2]); if path.hasPrefix("/"),fm.isExecutableFile(atPath:path) { return URL(fileURLWithPath:path) } }
        }
        throw AccountError.message("Codex-CLI nicht gefunden. Codex Desktop installieren oder CODEX_CLI_PATH auf eine ausführbare Datei setzen.")
    }
}
