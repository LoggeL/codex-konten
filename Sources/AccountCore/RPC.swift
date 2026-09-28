import Foundation
import AppKit
final class RPC: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let stopLock = NSLock()
    private var bytes = Data()
    private var pending: [J] = []
    private var stopped = false
    private var launched = false
    private let stream: AsyncStream<J>
    private let continuation: AsyncStream<J>.Continuation
    init(cli:URL, home:URL) throws {
        let pair = AsyncStream<J>.makeStream(); stream = pair.stream; continuation = pair.continuation
        process.executableURL = cli
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] { env[key] = nil }
        env["CODEX_HOME"] = home.path
        process.environment = env; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }; let incoming = handle.availableData
            if incoming.isEmpty { self.continuation.finish(); return }
            self.lock.lock(); self.bytes.append(incoming)
            while let end = self.bytes.firstIndex(of:10) { let line = self.bytes.prefix(upTo:end); self.bytes.removeSubrange(...end); if let j = try? JSONDecoder().decode(J.self,from:line) { self.continuation.yield(j) } }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.continuation.finish() }
        try process.run()
        launched = true
    }
    func stop() {
        stopLock.lock(); defer { stopLock.unlock() }
        if stopped { return }; stopped = true
        continuation.finish(); try? input.fileHandleForWriting.close()
        guard launched else { output.fileHandleForReading.readabilityHandler = nil; return }
        if process.isRunning { process.terminate() }
        for _ in 0..<100 { if !process.isRunning { break }; usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
    }
    deinit { stop() }
    private func send(_ message:J) throws { var data = try JSONEncoder().encode(message); data.append(10); try input.fileHandleForWriting.write(contentsOf:data) }
    func wait(id:Double? = nil, notification:String? = nil, seconds:Double = 20) async throws -> J {
        func matches(_ message:J) -> Bool { (id != nil && message["id"]?.number == id) || (notification != nil && message["method"]?.string == notification) }
        if let message = takePending(id:id, notification:notification) { return try result(message,notification:notification) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of:J.self) { group in
                group.addTask { [stream] in
                    for await message in stream {
                        try Task.checkCancellation()
                        if matches(message) { return try self.result(message,notification:notification) }
                        self.keepPending(message)
                    }
                    try Task.checkCancellation(); throw AccountError.message("Codex-CLI hat die Verbindung geschlossen.")
                }
                group.addTask { try await Task.sleep(for:.seconds(seconds)); throw AccountError.message("Zeitüberschreitung bei der Codex-Anfrage.") }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { self.stop() }
    }
    private func takePending(id:Double?,notification:String?) -> J? { lock.lock(); defer { lock.unlock() }; guard let index = pending.firstIndex(where:{ (id != nil && $0["id"]?.number == id) || (notification != nil && $0["method"]?.string == notification) }) else { return nil }; return pending.remove(at:index) }
    private func keepPending(_ value:J) { lock.lock(); defer { lock.unlock() }; pending.append(value); if pending.count > 100 { pending.removeFirst() } }
    private func result(_ value:J, notification:String?) throws -> J { if let e = value["error"] { throw AccountError.message(safeMessage(AccountError.message(e["message"]?.string ?? "Codex meldet einen Fehler."))) }; return notification != nil ? (value["params"] ?? .null) : (value["result"] ?? .null) }
    func request(_ method:String, id:Double, params:[String:J] = [:]) async throws -> J {
        try Task.checkCancellation(); try send(.object(["method":.string(method),"id":.number(id),"params":.object(params)])); return try await wait(id:id)
    }
    func initialize() async throws { _ = try await request("initialize",id:0,params:["clientInfo":.object(["name":.string("codex_konten"),"title":.string("Codex Konten"),"version":.string("1.0.0")])]); try send(.object(["method":.string("initialized"),"params":.object([:])])) }
}
protocol AccountClient: Sendable {
    func read(home:URL, usage:Bool) async throws -> (Identity, AccountUsage?)
    func login(home:URL, progress:@escaping AccountProgress) async throws -> Identity
}
struct LiveClient: AccountClient {
    let cli:URL
    func read(home:URL, usage:Bool) async throws -> (Identity,AccountUsage?) {
        let rpc = try RPC(cli:cli,home:home); defer { rpc.stop() }
        try await rpc.initialize()
        let response = try await rpc.request("account/read",id:1,params:["refreshToken":.bool(false)])
        guard let account = response["account"], account["type"]?.string == "chatgpt" else { throw AccountError.message("Dieses Konto ist nicht mit ChatGPT angemeldet. Bitte erneut hinzufügen.") }
        let local = try Identity.credential(Data(contentsOf:home.appendingPathComponent("auth.json")))
        let identity = Identity(accountID:account["accountId"]?.string ?? account["accountID"]?.string ?? account["chatgptAccountId"]?.string ?? account["id"]?.string ?? local.accountID,email:account["email"]?.string ?? local.email)
        guard identity.matches(local) else { throw AccountError.message("Codex liefert eine andere Kontoidentität als die gespeicherte Anmeldung.") }
        if !usage { return (identity,nil) }
        let result = try await rpc.request("account/rateLimits/read",id:2)
        let bucket = result["rateLimitsByLimitId"]?["codex"] ?? result["rateLimits"]
        var value = AccountUsage(fiveHourRemaining:nil,weeklyRemaining:nil,fiveHourReset:nil,weeklyReset:nil,fetchedAt:Date())
        for key in ["primary","secondary"] { guard let window = bucket?[key], let mins = window["windowDurationMins"]?.number ?? window["durationMinutes"]?.number, let used = window["usedPercent"]?.number, let reset = window["resetsAt"]?.number, used.isFinite,reset.isFinite else { continue }; let left = max(0,min(100,100-used)); if mins == 300 { value.fiveHourRemaining = left; value.fiveHourReset = Date(timeIntervalSince1970:reset) }; if mins >= 8640 && mins <= 11520 { value.weeklyRemaining = left; value.weeklyReset = Date(timeIntervalSince1970:reset) } }
        guard value.weeklyRemaining != nil || value.fiveHourRemaining != nil else { throw AccountError.message("Codex liefert keine nutzbaren Kontingentfenster für dieses Konto.") }
        return (identity,value)
    }
    func login(home:URL, progress:@escaping AccountProgress) async throws -> Identity {
        let rpc = try RPC(cli:cli,home:home); defer { rpc.stop() }
        try await rpc.initialize()
        let start = try await rpc.request("account/login/start",id:1,params:["type":.string("chatgpt"),"useHostedLoginSuccessPage":.bool(true),"appBrand":.string("codex")])
        guard let raw = start["authUrl"]?.string, let url = URL(string:raw), ["https","http"].contains(url.scheme ?? "") else { throw AccountError.message("Codex liefert keine gültige Anmeldeadresse.") }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw AccountError.message("Der Browser konnte nicht geöffnet werden.") }
        await progress("Im Browser anmelden. Abbrechen beendet nur diesen Anmeldevorgang.")
        let done = try await rpc.wait(notification:"account/login/completed",seconds:600)
        guard case .bool(true) = done["success"] else { throw AccountError.message(safeMessage(AccountError.message(done["error"]?.string ?? "Die Anmeldung wurde nicht abgeschlossen."))) }
        return try Identity.credential(Data(contentsOf:home.appendingPathComponent("auth.json")))
    }
}
