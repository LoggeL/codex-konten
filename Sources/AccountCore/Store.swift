import Foundation
import Darwin
struct Saved: Sendable { let id:String; let name:String; let email:String; let identity:Identity }
struct Store: Sendable {
    let base:URL
    let activeHome:URL
    init(base:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Account Switcher"), activeHome:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.base = base; self.activeHome = activeHome }
    var registryURL:URL { base.appendingPathComponent("accounts.json") }
    var activeAuth:URL { activeHome.appendingPathComponent("auth.json") }
    func profile(_ id:String) throws -> URL { guard UUID(uuidString:id) != nil else { throw AccountError.message("Ungültige Konto-ID.") }; return base.appendingPathComponent("accounts").appendingPathComponent(id) }
    func check(_ url:URL) throws { var part = url; while part.path != "/" { if let v = try? part.resourceValues(forKeys:[.isSymbolicLinkKey]), v.isSymbolicLink == true { throw AccountError.message("Verknüpfte Konto- oder Anmeldedateien werden nicht verändert.") }; part.deleteLastPathComponent() } }
    func registry() throws -> [String:J] { try check(registryURL); guard FileManager.default.fileExists(atPath:registryURL.path) else { return ["accounts":.array([]),"activeAccountID":.null] }; guard let value = try JSONDecoder().decode(J.self,from:Data(contentsOf:registryURL)).object else { throw AccountError.message("Die gespeicherte Kontoliste ist beschädigt.") }; return value }
    func accounts() throws -> [Saved] {
        try (registry()["accounts"]?.array ?? []).map { value in
            guard let id = value["id"]?.string else { throw AccountError.message("Gespeichertes Konto ohne ID.") }
            let home = try profile(id); try check(home.appendingPathComponent("auth.json"))
            let credential = try? Identity.credential(Data(contentsOf:home.appendingPathComponent("auth.json")))
            return Saved(id:id,name:value["displayName"]?.string ?? "Konto",email:value["email"]?.string ?? credential?.email ?? "",identity:Identity(accountID:value["accountID"]?.string ?? credential?.accountID,email:value["email"]?.string ?? credential?.email))
        }
    }
    func activeIdentity() -> Identity? { try? Identity.credential(Data(contentsOf:activeAuth)) }
    func matching(_ identity:Identity?, accounts:[Saved]) -> Saved? {
        guard let identity else { return nil }; let matches = accounts.filter { $0.identity.matches(identity) }; return matches.count == 1 ? matches[0] : nil
    }
    func write(_ data:Data,to url:URL) throws {
        try check(url); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".codex-konten-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try data.write(to:temp,options:.withoutOverwriting); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temp.path)
        guard rename(temp.path,url.path) == 0 else { throw AccountError.message("Die Kontodatei konnte nicht atomar ersetzt werden.") }
    }
    func writeRegistry(_ object:[String:J]) throws { try write(JSONEncoder().encode(J.object(object)),to:registryURL) }
    func syncActive(_ account:Saved) throws { guard let actual = activeIdentity(), account.identity.matches(actual) else { throw AccountError.message("Die laufende Anmeldung gehört zu einem anderen Konto.") }; try write(Data(contentsOf:activeAuth),to:try profile(account.id).appendingPathComponent("auth.json")) }
    func setActive(_ id:String) throws { var r = try registry(); r["activeAccountID"] = .string(id); if let values = r["accounts"]?.array { r["accounts"] = .array(values.map { var o = $0.object ?? [:]; if o["id"]?.string == id { o["lastUsedAt"] = .string(ISO8601DateFormatter().string(from:Date())) }; return .object(o) }) }; try writeRegistry(r) }
    func ensureFileStore() throws {
        try check(activeAuth)
        let configURL = activeHome.appendingPathComponent("config.toml"); try check(configURL)
        let config = FileManager.default.fileExists(atPath:configURL.path) ? try String(contentsOf:configURL,encoding:.utf8) : ""
        if config.range(of:#"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](?:keyring|auto)["']"#,options:.regularExpression) != nil { throw AccountError.message("Die aktuelle Codex-Konfiguration nutzt Schlüsselbund oder automatische Speicherung. Sicheres Umschalten von auth.json ist hierfür nicht unterstützt.") }
        guard FileManager.default.fileExists(atPath:activeAuth.path) else { throw AccountError.message("Keine aktive Dateianmeldung gefunden. In Codex anmelden, bevor ein Konto umgeschaltet wird.") }
    }
    func cache() -> [String:AccountUsage] {
        let url = base.appendingPathComponent("codex-konten-usage.json")
        if let data = try? Data(contentsOf:url), let values = try? JSONDecoder().decode([String:AccountUsage].self,from:data) { return values }
        guard let data = try? Data(contentsOf:base.appendingPathComponent("usage-cache.json")),let root = try? JSONDecoder().decode(J.self,from:data) else { return [:] }
        var out:[String:AccountUsage] = [:]; let formatter = ISO8601DateFormatter()
        for e in root["entries"]?.array ?? [] { guard let id = e["profileID"]?.string, let fetched = e["fetchedAt"]?.string.flatMap(formatter.date(from:)) else { continue }; let u = e["usage"]; out[id] = AccountUsage(fiveHourRemaining:u?["fiveHourRemainingPercent"]?.number,weeklyRemaining:u?["remainingPercent"]?.number,fiveHourReset:u?["fiveHourResetsAt"]?.string.flatMap(formatter.date(from:)),weeklyReset:u?["resetsAt"]?.string.flatMap(formatter.date(from:)),fetchedAt:fetched) }
        return out
    }
    func saveCache(_ values:[String:AccountUsage]) throws { try write(JSONEncoder().encode(values),to:base.appendingPathComponent("codex-konten-usage.json")) }
}
