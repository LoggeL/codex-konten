/// Main-actor gate shared by Sparkle's relaunch delegate and account actions.
/// A pending install handler runs only after the account operation has ended.
@MainActor
public final class UpdateGate {
    private var accountBusy: @MainActor () -> Bool = { false }
    private var pendingInstallHandler: (() -> Void)?
    public private(set) var isInstalling = false

    public init() {}

    public func bindAccountBusy(_ isBusy: @escaping @MainActor () -> Bool) {
        accountBusy = isBusy
    }

    public var mayCheckForUpdates: Bool { !isInstalling && !accountBusy() }
    public var mayStartAccountOperation: Bool { !isInstalling }

    /// Returns true when Sparkle must wait before invoking its handler.
    @discardableResult
    public func beginRelaunch(untilInvoking handler: @escaping () -> Void) -> Bool {
        isInstalling = true
        guard accountBusy() else { return false }
        pendingInstallHandler = handler
        return true
    }

    /// Returns true exactly when a postponed handler was released.
    @discardableResult
    public func resumeIfReady() -> Bool {
        guard isInstalling, !accountBusy(), let handler = pendingInstallHandler else { return false }
        pendingInstallHandler = nil
        handler()
        return true
    }

    /// Called after Sparkle aborts or fails, so account actions cannot remain locked.
    public func abort() {
        pendingInstallHandler = nil
        isInstalling = false
    }
}
