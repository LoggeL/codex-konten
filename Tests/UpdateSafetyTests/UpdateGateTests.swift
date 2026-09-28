import Testing
@testable import UpdateSafety

@MainActor
private final class BusyState { var value = true }

@Suite("Update and account operation interlock")
@MainActor
struct UpdateGateTests {
    @Test func defersRelaunchUntilAccountFinishesExactlyOnce() {
        let gate = UpdateGate()
        let accountBusy = BusyState()
        var installCalls = 0
        gate.bindAccountBusy { accountBusy.value }

        #expect(!gate.mayCheckForUpdates)
        #expect(gate.beginRelaunch { installCalls += 1 })
        #expect(!gate.mayStartAccountOperation)
        #expect(!gate.resumeIfReady())
        #expect(installCalls == 0)

        accountBusy.value = false
        #expect(gate.resumeIfReady())
        #expect(!gate.resumeIfReady())
        #expect(installCalls == 1)
        #expect(!gate.mayStartAccountOperation)
    }

    @Test func abortDropsPendingInstallAndReleasesAccountGate() {
        let gate = UpdateGate()
        let accountBusy = BusyState()
        var installCalls = 0
        gate.bindAccountBusy { accountBusy.value }
        #expect(gate.beginRelaunch { installCalls += 1 })

        gate.abort()
        accountBusy.value = false
        #expect(!gate.resumeIfReady())
        #expect(installCalls == 0)
        #expect(gate.mayCheckForUpdates)
        #expect(gate.mayStartAccountOperation)
    }

    @Test func immediateRelaunchBlocksNewAccountOperationWithoutCallingHandler() {
        let gate = UpdateGate()
        var installCalls = 0
        #expect(gate.mayCheckForUpdates)
        #expect(!gate.beginRelaunch { installCalls += 1 })
        #expect(!gate.mayCheckForUpdates)
        #expect(!gate.mayStartAccountOperation)
        #expect(!gate.resumeIfReady())
        #expect(installCalls == 0)
        gate.abort()
        #expect(gate.mayStartAccountOperation)
    }
}
