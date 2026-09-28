import Foundation
import AppKit
import Darwin
public actor AccountService {
    private let store:Store
    private let desktop:any Desktop
    private let injectedClient:(any AccountClient)?
    private var busy = false
    private var lockFD:Int32 = -1
    private var usage:[String:AccountUsage]
    private var errors:[String:String] = [:]
    private var notice:String?
    public init() { let s = Store(); store = s; desktop = LiveDesktop(); injectedClient = nil; usage = s.cache() }
    init(store:Store,client:any AccountClient,desktop:any Desktop) { self.store = store; self.injectedClient = client; self.desktop = desktop; usage = store.cache() }
    private func begin() throws {
        guard !busy else { throw AccountError.message("Ein Kontovorgang läuft bereits. Erst abschließen oder abbrechen.") }
        if injectedClient == nil && !NSRunningApplication.runningApplications(withBundleIdentifier:"com.liuzhao.codex-account-switcher").isEmpty { throw AccountError.message("Der bisherige Codex Account Switcher läuft noch. Bitte ihn beenden, damit nur eine App die gespeicherten Anmeldungen verwendet.") }
        try store.check(store.base); try FileManager.default.createDirectory(at:store.base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = store.base.appendingPathComponent(".codex-konten.lock"); try store.check(url)
        let fd = Darwin.open(url.path,O_CREAT | O_RDWR,0o600)
        guard fd >= 0 else { throw AccountError.message("Die Kontosperre konnte nicht geöffnet werden.") }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw AccountError.message("Eine andere Codex-Konten-Instanz verwendet gerade die Anmeldungen.") }
        lockFD = fd; busy = true
    }
    private func end() { if lockFD >= 0 { flock(lockFD,LOCK_UN); Darwin.close(lockFD); lockFD = -1 }; busy = false }
    private func client() throws -> any AccountClient { if let injectedClient { return injectedClient }; return LiveClient(cli:try CLIDiscovery.locate()) }
    public func snapshot() async throws -> AccountSnapshot {
        let accounts = try store.accounts(); let identity = store.activeIdentity(); let current = store.matching(identity,accounts:accounts)
        let path = try? CLIDiscovery.locate().path
        let registry = try store.registry()["activeAccountID"]?.string
        let stateNotice = notice ?? (identity != nil && current == nil ? "Die aktuelle Codex-Anmeldung passt zu keinem eindeutig gespeicherten Konto." : (current != nil && registry != current?.id ? "Die bisherige Kontoliste markiert ein anderes Konto. Angezeigt wird die tatsächliche Codex-Anmeldung." : nil))
        return AccountSnapshot(accounts:accounts.map { SavedAccountView(id:$0.id,displayName:$0.name,email:$0.email,isActive:$0.id == current?.id,usage:usage[$0.id],error:errors[$0.id]) },cliPath:path,currentAccountLabel:current?.name ?? identity?.email,notice:stateNotice)
    }
    public func openCodex() async throws -> AccountSnapshot {
        try begin(); defer { end() }
        try await desktop.open()
        notice = "Codex wurde als laufender Prozess bestätigt."
        return try await snapshot()
    }
    public func refresh() async throws -> AccountSnapshot {
        try begin(); defer { end() }; let client = try client(); let accounts = try store.accounts(); let current = store.matching(store.activeIdentity(),accounts:accounts)
        for account in accounts {
            try Task.checkCancellation()
            do {
                if account.id == current?.id { try store.syncActive(account) }
                let home = account.id == current?.id ? store.activeHome : try store.profile(account.id)
                let (identity,limits) = try await client.read(home:home,usage:true)
                guard account.identity.matches(identity) else { throw AccountError.message("Die gespeicherte Anmeldung gehört zu einem anderen Konto. Bitte dieses Konto neu hinzufügen.") }
                if account.id == current?.id { try store.syncActive(account) }
                usage[account.id] = limits; errors[account.id] = nil
            } catch is CancellationError { throw CancellationError() } catch { errors[account.id] = safeMessage(error) }
        }
        try store.saveCache(usage)
        return try await snapshot()
    }
    public func addAccount(displayName:String,progress:@escaping AccountProgress) async throws -> AccountSnapshot {
        try begin(); defer { end() }; let id = UUID().uuidString; let home = try store.profile(id)
        try store.check(home); try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at:home) } }
        await progress("Browser-Anmeldung wird gestartet…")
        let identity = try await client().login(home:home,progress:progress); try Task.checkCancellation()
        let accounts = try store.accounts()
        if let existing = store.matching(identity,accounts:accounts) {
            guard store.matching(store.activeIdentity(),accounts:accounts)?.id != existing.id else { throw AccountError.message("Dieses Konto ist aktuell in Codex angemeldet. Bitte dort direkt neu anmelden oder zuerst zu einem anderen Konto wechseln. Die bestehende Anmeldung wurde nicht verändert.") }
            let destination = try store.profile(existing.id).appendingPathComponent("auth.json")
            try store.write(Data(contentsOf:home.appendingPathComponent("auth.json")),to:destination)
            errors[existing.id] = nil; notice = "Die Anmeldung für \(existing.name) wurde erneuert. Die aktuelle Codex-Anmeldung bleibt unverändert."
            return try await snapshot()
        }
        let credential = try Data(contentsOf:home.appendingPathComponent("auth.json")); try store.write(credential,to:home.appendingPathComponent("auth.json"))
        var r = try store.registry(); var values = r["accounts"]?.array ?? []
        values.append(.object(["id":.string(id),"displayName":.string(displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? (identity.email ?? "Konto") : displayName),"email":identity.email.map(J.string) ?? .null,"accountID":identity.accountID.map(J.string) ?? .null,"createdAt":.string(ISO8601DateFormatter().string(from:Date()))]))
        r["accounts"] = .array(values); try store.writeRegistry(r); committed = true
        return try await snapshot()
    }
    public func removeAccount(id:String) async throws -> AccountSnapshot {
        try begin(); defer { end() }; let accounts = try store.accounts()
        guard accounts.contains(where:{$0.id == id}) else { throw AccountError.message("Konto nicht gefunden.") }
        guard store.matching(store.activeIdentity(),accounts:accounts)?.id != id else { throw AccountError.message("Das aktuell angemeldete Konto kann nicht entfernt werden.") }
        var r = try store.registry(); var removed = r["codexKontenRemovedAccounts"]?.array ?? []
        let values = r["accounts"]?.array ?? []; removed += values.filter { $0["id"]?.string == id }; r["codexKontenRemovedAccounts"] = .array(removed); r["accounts"] = .array(values.filter { $0["id"]?.string != id }); if r["activeAccountID"]?.string == id { r["activeAccountID"] = .null }; try store.writeRegistry(r)
        usage[id] = nil; errors[id] = nil; notice = "Konto aus der Liste entfernt. Die geschützte Profildatei bleibt erhalten."
        return try await snapshot()
    }
    public func switchAccount(id:String,progress:@escaping AccountProgress) async throws -> AccountSnapshot {
        try begin(); defer { end() }; let accounts = try store.accounts()
        guard let target = accounts.first(where:{$0.id == id}) else { throw AccountError.message("Zielkonto nicht gefunden.") }
        let current = store.matching(store.activeIdentity(),accounts:accounts)
        if current?.id == id { return try await snapshot() }
        try store.ensureFileStore(); let client = try client()
        await progress("Zielanmeldung wird geprüft…")
        let targetHome = try store.profile(id)
        let (identity,limits) = try await client.read(home:targetHome,usage:true)
        guard target.identity.matches(identity) else { throw AccountError.message("Zielanmeldung und gespeichertes Konto stimmen nicht überein. Codex bleibt geöffnet.") }
        try Task.checkCancellation()
        // Read after preflight: the CLI may have refreshed the target credential in place.
        let targetCredential = try Data(contentsOf:targetHome.appendingPathComponent("auth.json"))
        guard target.identity.matches(try Identity.credential(targetCredential)) else { throw AccountError.message("Die Zielanmeldung wurde während der Prüfung verändert.") }
        var originalCredential = try Data(contentsOf:store.activeAuth)
        let originalRegistry = try Data(contentsOf:store.registryURL)
        await progress("Codex wird regulär beendet…")
        var closed = false; var installed = false; var committed = false
        do {
            closed = try await desktop.close()
            try Task.checkCancellation()
            // Desktop may refresh its file while quitting. Capture that final credential before replacing.
            let finalCredential = try Data(contentsOf:store.activeAuth)
            originalCredential = finalCredential
            if let current, current.identity.matches(try Identity.credential(finalCredential)) { try store.syncActive(current) }
            await progress("Anmeldung wird eingesetzt und geprüft…")
            try store.write(targetCredential,to:store.activeAuth); installed = true
            let (verified,_) = try await client.read(home:store.activeHome,usage:false)
            guard target.identity.matches(verified) else { throw AccountError.message("Identitätsprüfung nach dem Umschalten fehlgeschlagen.") }
            try Task.checkCancellation(); try store.setActive(id); committed = true
            usage[id] = limits; errors[id] = nil
            await progress("Codex wird geöffnet…"); try await desktop.open()
        } catch {
            let originalError = error
            if committed { throw AccountError.message("Die Anmeldung wurde auf \(target.name) umgestellt. Codex konnte anschließend nicht geöffnet werden: \(safeMessage(originalError)) Bitte Codex manuell öffnen.") }
            if installed && !committed {
                do { try store.write(originalCredential,to:store.activeAuth); try store.write(originalRegistry,to:store.registryURL) }
                catch { throw AccountError.message("Umschalten fehlgeschlagen: \(safeMessage(originalError)) Wiederherstellen fehlgeschlagen: \(safeMessage(error))") }
            }
            if closed { do { try await desktop.open() } catch { throw AccountError.message("\(safeMessage(originalError)) Codex konnte anschließend nicht geöffnet werden: \(safeMessage(error))") } }
            throw originalError
        }
        notice = "Anmeldung geprüft. Neue Codex-Prozesse verwenden \(target.name)."
        return try await snapshot()
    }
}
