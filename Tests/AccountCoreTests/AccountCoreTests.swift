import Testing
@testable import AccountCore
import Foundation
import AppKit
private let testTemporaryDirectory = URL(fileURLWithPath:NSTemporaryDirectory().hasPrefix("/var/") ? "/private"+NSTemporaryDirectory() : NSTemporaryDirectory())

actor FakeClient: AccountClient {
    let store:Store
    var wrongVerification = false
    var slow = false
    var loginAccount:String?
    init(_ store:Store) { self.store = store }
    func setWrong() { wrongVerification = true }
    func setSlow() { slow = true }
    func setLogin(_ account:String) { loginAccount = account }
    func read(home:URL,usage:Bool) async throws -> (Identity,AccountUsage?) {
        if slow { try await Task.sleep(for:.seconds(10)) }
        if !usage && wrongVerification { return (Identity(accountID:"wrong",email:"same@example.test"),nil) }
        let identity = try Identity.credential(Data(contentsOf:home.appendingPathComponent("auth.json")))
        return (identity,usage ? AccountUsage(fiveHourRemaining:60,weeklyRemaining:80,fiveHourReset:Date(),weeklyReset:Date(),fetchedAt:Date()) : nil)
    }
    func login(home:URL,progress:@escaping AccountProgress) async throws -> Identity { guard let loginAccount else { throw CancellationError() }; let data = Fixture.auth(id:loginAccount); try data.write(to:home.appendingPathComponent("auth.json")); return try Identity.credential(data) }
}
actor FakeDesktop: Desktop {
    var closes = 0
    var opens = 0
    var fail = false
    var slowClose = false
    var failOpen = false
    var wasRunning = true
    func close() async throws -> Bool { closes += 1; if fail { throw AccountError.message("close refused") }; if slowClose { await Task.detached { try? await Task.sleep(for:.milliseconds(150)) }.value }; return wasRunning }
    func open() async throws { opens += 1; if failOpen { throw AccountError.message("launch refused") } }
    func counts() -> (Int,Int) { (closes,opens) }
    func setFail() { fail = true }
    func setSlowClose() { slowClose = true }
    func setFailOpen() { failOpen = true }
    func setClosed() { wasRunning = false }
}
struct Fixture {
    let store:Store
    let a = UUID().uuidString
    let b = UUID().uuidString
    let root:URL
    init() throws {
        root = testTemporaryDirectory.appendingPathComponent("codex-konten-test-"+UUID().uuidString)
        store = Store(base:root.appendingPathComponent("profiles"),activeHome:root.appendingPathComponent("active"))
        try store.write(Self.auth(id:"workspace-a"),to:store.activeAuth)
        try store.write(Self.auth(id:"workspace-a"),to:store.profile(a).appendingPathComponent("auth.json"))
        try store.write(Self.auth(id:"workspace-b"),to:store.profile(b).appendingPathComponent("auth.json"))
        try store.writeRegistry(["unknown":.string("preserve"),"activeAccountID":.string(b),"accounts":.array([row(a,"A","workspace-a"),row(b,"B","workspace-b")])])
    }
    func row(_ id:String,_ name:String,_ account:String) -> J { .object(["id":.string(id),"displayName":.string(name),"email":.string("same@example.test"),"accountID":.string(account),"custom":.number(7)]) }
    static func auth(id:String) -> Data { let claims = Data("{\"email\":\"same@example.test\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"\(id)\"}}".utf8).base64EncodedString().replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_"); return Data("{\"tokens\":{\"account_id\":\"\(id)\",\"id_token\":\"fixture.\(claims).fixture\"}}".utf8) }
    func clean() { try? FileManager.default.removeItem(at:root) }
}
struct AccountCoreTests {
    @Test func testSameEmailDifferentWorkspaceDoesNotMatch() { XCTAssertFalse(Identity(accountID:"a",email:"same@example.test").matches(Identity(accountID:"b",email:"same@example.test"))) }
    @Test func testSnapshotUsesActualAuthInsteadOfStaleRegistry() async throws {
        let f = try Fixture(); defer { f.clean() }; let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:FakeDesktop())
        let before = try Data(contentsOf:f.store.registryURL)
        let snap = try await s.snapshot()
        XCTAssertEqual(snap.accounts.first(where:{$0.isActive})?.id,f.a)
        XCTAssertEqual(snap.currentAccountLabel,"A")
        XCTAssertEqual(try Data(contentsOf:f.store.registryURL),before)
    }
    @Test func testVerificationFailureRollsBackAndReopens() async throws {
        let f = try Fixture(); defer { f.clean() }; let client = FakeClient(f.store); await client.setWrong(); let desktop = FakeDesktop(); let s = AccountService(store:f.store,client:client,desktop:desktop)
        let auth = try Data(contentsOf:f.store.activeAuth); let registry = try Data(contentsOf:f.store.registryURL)
        do { _ = try await s.switchAccount(id:f.b,progress:{_ in}); XCTFail("expected mismatch") } catch {}
        XCTAssertEqual(try Data(contentsOf:f.store.activeAuth),auth)
        XCTAssertEqual(try Data(contentsOf:f.store.registryURL),registry)
        let counts = await desktop.counts(); XCTAssertEqual(counts.0,1); XCTAssertEqual(counts.1,1)
    }
    @Test func testSuccessPreservesUnknownRegistryFields() async throws {
        let f = try Fixture(); defer { f.clean() }; let desktop = FakeDesktop(); let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:desktop)
        let snap = try await s.switchAccount(id:f.b,progress:{_ in})
        XCTAssertEqual(snap.accounts.first(where:{$0.isActive})?.id,f.b)
        XCTAssertEqual(try f.store.registry()["unknown"]?.string,"preserve")
        XCTAssertEqual(try f.store.registry()["accounts"]?.array?.first?["custom"]?.number,7)
        let attrs = try FileManager.default.attributesOfItem(atPath:f.store.activeAuth.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int,0o600)
    }
    @Test func testCloseFailureNeverChangesAuth() async throws {
        let f = try Fixture(); defer { f.clean() }; let desktop = FakeDesktop(); await desktop.setFail(); let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:desktop)
        let before = try Data(contentsOf:f.store.activeAuth)
        do { _ = try await s.switchAccount(id:f.b,progress:{_ in}); XCTFail("expected close error") } catch {}
        XCTAssertEqual(try Data(contentsOf:f.store.activeAuth),before)
    }
    @Test func testOldInvalidCredentialDoesNotBlockValidTarget() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.store.write(Data("invalid-old-auth".utf8),to:f.store.activeAuth)
        let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:FakeDesktop())
        let snapshot = try await s.switchAccount(id:f.b,progress:{_ in})
        XCTAssertEqual(snapshot.accounts.first(where:{$0.isActive})?.id,f.b)
    }
    @Test func testPostcommitLaunchFailureLeavesTargetActiveAndExplainsIt() async throws {
        let f = try Fixture(); defer { f.clean() }; let desktop = FakeDesktop(); await desktop.setFailOpen(); let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:desktop)
        do { _ = try await s.switchAccount(id:f.b,progress:{_ in}); XCTFail("launch failure") } catch { XCTAssertTrue(error.localizedDescription.contains("Anmeldung wurde auf B umgestellt")) }
        XCTAssertEqual(try f.store.registry()["activeAccountID"]?.string,f.b)
        XCTAssertEqual(f.store.activeIdentity()?.accountID,"workspace-b")
        let counts = await desktop.counts(); XCTAssertEqual(counts.1,1)
    }
    @Test func testSwitchOpensInitiallyClosedDesktop() async throws {
        let f = try Fixture(); defer { f.clean() }; let desktop = FakeDesktop(); await desktop.setClosed(); let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:desktop)
        _ = try await s.switchAccount(id:f.b,progress:{_ in}); let counts = await desktop.counts(); XCTAssertEqual(counts.1,1)
    }
    @Test func testCancellationAfterQuitReopensWithoutMutation() async throws {
        let f = try Fixture(); defer { f.clean() }; let desktop = FakeDesktop(); await desktop.setSlowClose(); let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:desktop)
        let before = try Data(contentsOf:f.store.activeAuth)
        let task = Task { try await s.switchAccount(id:f.b,progress:{_ in}) }
        for _ in 0..<100 { if await desktop.counts().0 > 0 { break }; try await Task.sleep(for:.milliseconds(5)) }
        task.cancel(); do { _ = try await task.value; XCTFail("cancel expected") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf:f.store.activeAuth),before)
        let counts = await desktop.counts(); XCTAssertEqual(counts.1,1)
    }
    @Test func testCancellationBeforeCloseLeavesCredentialAndReleasesBusy() async throws {
        let f = try Fixture(); defer { f.clean() }; let client = FakeClient(f.store); await client.setSlow(); let desktop = FakeDesktop(); let s = AccountService(store:f.store,client:client,desktop:desktop)
        let before = try Data(contentsOf:f.store.activeAuth)
        let task = Task { try await s.switchAccount(id:f.b,progress:{_ in}) }; try await Task.sleep(for:.milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf:f.store.activeAuth),before)
        let counts = await desktop.counts(); XCTAssertEqual(counts.0,0)
        _ = try await s.snapshot()
        _ = try await s.removeAccount(id:f.b)
    }
    @Test func testRemovalKeepsProtectedProfileAndMetadata() async throws {
        let f = try Fixture(); defer { f.clean() }; let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:FakeDesktop())
        _ = try await s.removeAccount(id:f.b)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try f.store.profile(f.b).appendingPathComponent("auth.json").path))
        XCTAssertEqual(try f.store.registry()["codexKontenRemovedAccounts"]?.array?.first?["id"]?.string,f.b)
        do { _ = try await s.removeAccount(id:f.a); XCTFail("active removal") } catch {}
    }
    @Test func testActiveReauthenticationRefusesWithoutOverwriting() async throws {
        let f = try Fixture(); defer { f.clean() }; let client = FakeClient(f.store); await client.setLogin("workspace-a"); let s = AccountService(store:f.store,client:client,desktop:FakeDesktop())
        let before = try Data(contentsOf:f.store.profile(f.a).appendingPathComponent("auth.json"))
        do { _ = try await s.addAccount(displayName:"A",progress:{_ in}); XCTFail("active reauth refused") } catch {}
        XCTAssertEqual(try Data(contentsOf:f.store.profile(f.a).appendingPathComponent("auth.json")),before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.store.base.appendingPathComponent("accounts").path).count,2)
    }
    @Test func testCancelledLoginRemovesOnlyPendingProfile() async throws {
        let f = try Fixture(); defer { f.clean() }; let s = AccountService(store:f.store,client:FakeClient(f.store),desktop:FakeDesktop())
        do { _ = try await s.addAccount(displayName:"new",progress:{_ in}); XCTFail("cancelled login") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.store.base.appendingPathComponent("accounts").path).count,2)
    }
    @Test func testStaleOverrideFallsBackToVerifiedBundle() throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let executable = root.appendingPathComponent(CLIDiscovery.candidates[0]); try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true); try Data("#!/bin/sh\nexit 0\n".utf8).write(to:executable); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let resolved = try CLIDiscovery.locate(environment:["CODEX_CLI_PATH":"/missing/old/codex"],desktop:root)
        XCTAssertEqual(resolved,executable)
    }
    @Test func testSanitizesSecrets() { let message = safeMessage(AccountError.message("Bearer token-value sk-secret rt_secret eyJabc.def.xyz")); XCTAssertFalse(message.contains("token-value")); XCTAssertFalse(message.contains("sk-secret")); XCTAssertFalse(message.contains("rt_secret")); XCTAssertFalse(message.contains("eyJabc")) }
    @Test func testRPCBuffersEarlyLoginNotificationAndDrainsChild() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable = root.appendingPathComponent("fixture.py")
        let script = "#!/usr/bin/python3\nimport json,sys,time\nfor line in sys.stdin:\n m=json.loads(line)\n if m.get('method')=='initialize':\n  print(json.dumps({'method':'account/login/completed','params':{'success':True}}),flush=True)\n  print(json.dumps({'id':0,'result':{}}),flush=True)\n"
        try Data(script.utf8).write(to:executable); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let rpc = try RPC(cli:executable,home:root); try await rpc.initialize(); let done = try await rpc.wait(notification:"account/login/completed",seconds:2)
        if case .bool(true) = done["success"] {} else { XCTFail("missing notification") }
        rpc.stop(); XCTAssertFalse(rpc.process.isRunning)
    }
    @Test func testRPCTimeoutAndCancellationDrain() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable = root.appendingPathComponent("fixture.py"); try Data("#!/usr/bin/python3\nimport time,signal\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nprint('{\"id\":0,\"result\":{}}',flush=True)\nwhile True: time.sleep(1)\n".utf8).write(to:executable); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let rpc = try RPC(cli:executable,home:root)
        try await rpc.initialize()
        do { _ = try await rpc.wait(id:99,seconds:0.05); XCTFail("timeout") } catch {}
        rpc.stop(); XCTAssertFalse(rpc.process.isRunning)
        let second = try RPC(cli:executable,home:root); try await second.initialize(); let task = Task { try await second.wait(id:99,seconds:5) }; try await Task.sleep(for:.milliseconds(30)); task.cancel(); do { _ = try await task.value; XCTFail("cancel") } catch {}
        XCTAssertFalse(second.process.isRunning)
    }
    @Test func testMissingExecutableFailsWithoutUnlaunchedWait() throws { XCTAssertThrowsError(try RPC(cli:URL(fileURLWithPath:"/missing/test-codex"),home:FileManager.default.temporaryDirectory)) }

    @Test func testRelauncherFallbackAndProcessPostcondition() async throws {
        actor State { var launches = 0; var fallbacks = 0; var running = false; func launch() { launches += 1 }; func fallback() { fallbacks += 1; running = true }; func status() -> (Int,Int,Bool) { (launches,fallbacks,running) } }
        let state = State()
        let relauncher = DesktopRelauncher(
            launch: { _ in await state.launch() },
            fallback: { _ in await state.fallback() },
            isRunning: { _ in await state.status().2 },
            wait: { _ in }
        )
        try await relauncher.open(URL(fileURLWithPath:"/tmp/fixture.app"))
        let status = await state.status(); XCTAssertEqual(status.0,1); XCTAssertEqual(status.1,1)
    }

    @Test func testRelauncherReportsFailureWhenNoProcessAppears() async throws {
        let relauncher = DesktopRelauncher(launch:{ _ in },fallback:{ _ in },isRunning:{ _ in false },wait:{ _ in })
        do { try await relauncher.open(URL(fileURLWithPath:"/tmp/fixture.app")); XCTFail("expected missing postcondition") }
        catch { XCTAssertTrue(error.localizedDescription.contains("nicht als laufender Prozess bestätigt")) }
    }
    @Test func testNonCooperativeLaunchTimesOutAndUsesFallback() async throws {
        actor State { var running = false; func set() { running = true }; func get() -> Bool { running } }
        let state = State(); let start = Date()
        let relauncher = DesktopRelauncher(
            launch: { _ in await Task.detached { try? await Task.sleep(for:.seconds(2)) }.value },
            fallback: { _ in await state.set() },
            isRunning: { _ in await state.get() },
            wait: { _ in },
            launchTimeout: .milliseconds(30)
        )
        try await relauncher.open(URL(fileURLWithPath:"/tmp/fixture.app"))
        XCTAssertTrue(Date().timeIntervalSince(start) < 1)
    }

    @Test func testProcessIdentityDetectsOriginalExit() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/sleep"); process.arguments = ["2"]; try process.run()
        guard let identity = LiveDesktop.ProcessIdentity(pid:process.processIdentifier) else { XCTFail("process not identified"); return }
        XCTAssertTrue(identity.isAlive)
        process.terminate(); process.waitUntilExit()
        let exited = await LiveDesktop.waitForExit(processes:[identity],attempts:1,wait:{ _ in })
        XCTAssertTrue(exited)
    }

    @Test func testNativeDelayedQuitAndExactBundleRelaunch() async throws {
        let root = testTemporaryDirectory.appendingPathComponent("codex-konten-native-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = root.appendingPathComponent("Launch Fixture.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at:macos,withIntermediateDirectories:true)
        let source = root.appendingPathComponent("Fixture.swift")
        let program = """
        import AppKit
        final class Delegate: NSObject, NSApplicationDelegate {
            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sender.reply(toApplicationShouldTerminate: true) }
                return .terminateLater
            }
        }
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        """
        try Data(program.utf8).write(to:source)
        let binary = macos.appendingPathComponent("LaunchFixture")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath:"/usr/bin/swiftc"); compiler.arguments = [source.path,"-o",binary.path]; compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice; try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus,0)
        let identifier = "de.logge.codex-konten.fixture."+UUID().uuidString.lowercased()
        let plist:[String:Any] = ["CFBundleIdentifier":identifier,"CFBundleExecutable":"LaunchFixture","CFBundlePackageType":"APPL","CFBundleName":"Launch Fixture","LSUIElement":true]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let desktop = LiveDesktop(bundleID:identifier,installed:[app])
        try await desktop.open()
        let first = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first
        XCTAssertTrue(first != nil)
        let started = Date()
        XCTAssertTrue(try await desktop.close())
        XCTAssertTrue(Date().timeIntervalSince(started) >= 0.8)
        XCTAssertFalse(LiveDesktop.ProcessIdentity(pid:first!.processIdentifier)?.isAlive ?? false)
        try await desktop.open()
        let second = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first(where:{ !$0.isTerminated })
        XCTAssertTrue(second != nil)
        XCTAssertFalse(second?.processIdentifier == first?.processIdentifier)
        second?.forceTerminate()
    }
}

private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertFalse(_ value: Bool) { #expect(!value) }
private func XCTAssertEqual<T: Equatable>(_ a:T,_ b:T) { #expect(a == b) }
private func XCTFail(_ message:String) { Issue.record(Comment(rawValue:message)) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) { do { _ = try expression(); Issue.record("Expected an error") } catch {} }
