import Combine
import Foundation
import Sparkle
import UpdateSafety

/// Sparkle owns update selection, signature verification, consent, and installation.
/// This adapter only connects its standard UI to the menu and interlocks relaunch
/// with account operations.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isInstalling = false
    @Published private(set) var statusText: String?
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard !syncingAutomaticPreference, oldValue != automaticallyChecksForUpdates else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticCheckObservation: NSKeyValueObservation?
    private var syncingAutomaticPreference = false
    private let gate = UpdateGate()
    private var postponeTimer: Timer?

    init(preview: Bool = false) {
        super.init()
        guard !preview,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            statusText = preview ? nil : "Updates sind nur in der installierten App verfügbar."
            return
        }
        let instance = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = instance
        syncingAutomaticPreference = true
        automaticallyChecksForUpdates = instance.updater.automaticallyChecksForUpdates
        syncingAutomaticPreference = false
        canCheckObservation = instance.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = self.controller?.updater.canCheckForUpdates ?? false
            }
        }
        automaticCheckObservation = instance.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncingAutomaticPreference = true
                self.automaticallyChecksForUpdates = self.controller?.updater.automaticallyChecksForUpdates ?? false
                self.syncingAutomaticPreference = false
            }
        }
    }

    func bindAccountBusy(_ isBusy: @escaping @MainActor () -> Bool) {
        gate.bindAccountBusy(isBusy)
    }

    func checkForUpdates() {
        guard let controller, canCheckForUpdates else { return }
        guard gate.mayCheckForUpdates else {
            statusText = "Erst den Kontovorgang abschließen."
            return
        }
        statusText = nil
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard gate.mayCheckForUpdates else {
            throw NSError(domain: "de.logge.codex-konten.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ein Kontovorgang läuft. Updates können danach geprüft werden."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Once Sparkle is ready to relaunch, block new account actions even if an
        // existing operation requires a short delay. The SwiftUI model also checks
        // isInstalling before starting any operation.
        let postpone = gate.beginRelaunch(untilInvoking: installHandler)
        isInstalling = gate.isInstalling
        guard postpone else { return false }
        postponeTimer?.invalidate()
        postponeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.gate.resumeIfReady() else { return }
                self.postponeTimer?.invalidate()
                self.postponeTimer = nil
            }
        }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isInstalling = true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusText = "Update verfügbar: \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        statusText = "Codex Konten ist aktuell."
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        clearInstallationGate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        clearInstallationGate()
        statusText = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            clearInstallationGate()
            statusText = error.localizedDescription
        }
    }

    private func clearInstallationGate() {
        postponeTimer?.invalidate()
        postponeTimer = nil
        gate.abort()
        isInstalling = gate.isInstalling
    }
}
