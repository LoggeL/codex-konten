import AccountCore
import Foundation
import SwiftUI

@MainActor
final class AccountModel: ObservableObject {
    @Published var snapshot: AccountSnapshot?
    @Published var operation: String?
    @Published var progress = ""
    @Published var error: String?
    @Published var cancelling = false
    @Published var showOpenCodexAction = false
    private var task: Task<Void, Never>?
    private let service: AccountService?
    let demoMode: Bool
    private var updateIsInstalling: (@MainActor () -> Bool)?
    private var lastRefreshAttempt: Date?

    var busy: Bool { operation != nil }
    var accounts: [SavedAccountView] { snapshot?.accounts ?? [] }

    func bindUpdateInstall(_ isInstalling: @escaping @MainActor () -> Bool) {
        updateIsInstalling = isInstalling
    }

    private var canStartOperation: Bool { !busy && updateIsInstalling?() != true }

    init(preview: Bool = false, previewStress: Bool = false, demo: Bool = false) {
        demoMode = demo
        service = (preview || demo) ? nil : AccountService()
        if preview || demo { snapshot = Self.previewSnapshot(stress: previewStress) }
    }

    func load() {
        guard service != nil else { return }
        guard canStartOperation else { return }
        if snapshot == nil {
            perform("Konten laden", refreshAfter: true) { service in try await service.snapshot() }
        } else if lastRefreshAttempt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            refresh()
        }
    }

    func refresh() {
        guard service != nil else { return }
        guard canStartOperation else { return }
        lastRefreshAttempt = Date()
        perform("Limits aktualisieren") { service in try await service.refresh() }
    }

    func add(name: String) {
        guard canStartOperation else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if demoMode {
            guard !cleanName.isEmpty, let snapshot else { return }
            let account = SavedAccountView(id: UUID().uuidString, displayName: cleanName, email: "demo@example.com", isActive: false, usage: nil, error: nil)
            self.snapshot = AccountSnapshot(accounts: snapshot.accounts + [account], cliPath: nil, currentAccountLabel: snapshot.currentAccountLabel, notice: snapshot.notice)
            return
        }
        let callback = progressCallback
        perform("Konto anmelden", refreshAfter: true) { service in
            try await service.addAccount(displayName: cleanName, progress: callback)
        }
    }

    func switchAccount(_ account: SavedAccountView) {
        guard canStartOperation else { return }
        if demoMode, let snapshot {
            self.snapshot = AccountSnapshot(accounts: snapshot.accounts.map {
                SavedAccountView(id: $0.id, displayName: $0.displayName, email: $0.email, isActive: $0.id == account.id, usage: $0.usage, error: $0.error)
            }, cliPath: nil, currentAccountLabel: account.email, notice: snapshot.notice)
            return
        }
        let callback = progressCallback
        perform("Konto wechseln") { service in
            try await service.switchAccount(id: account.id, progress: callback)
        }
    }

    func remove(_ account: SavedAccountView) {
        guard canStartOperation else { return }
        if demoMode, let snapshot {
            self.snapshot = AccountSnapshot(accounts: snapshot.accounts.filter { $0.id != account.id }, cliPath: nil, currentAccountLabel: snapshot.currentAccountLabel, notice: snapshot.notice)
            return
        }
        perform("Konto entfernen") { service in try await service.removeAccount(id: account.id) }
    }

    func openCodex() {
        guard canStartOperation else { return }
        if demoMode { return }
        perform("Codex öffnen") { service in try await service.openCodex() }
    }

    func cancel() {
        guard busy, operation == "Konto anmelden", !cancelling else { return }
        cancelling = true
        progress = "Anmeldung wird abgebrochen …"
        task?.cancel()
    }

    private func perform(_ title: String, refreshAfter: Bool = false, body: @escaping @Sendable (AccountService) async throws -> AccountSnapshot) {
        guard canStartOperation, let service else { return }
        operation = title
        progress = title == "Konto anmelden" ? "Browser-Anmeldung wird vorbereitet …" : "Bitte warten …"
        error = nil
        showOpenCodexAction = false
        cancelling = false
        task = Task { [weak self] in
            var succeeded = false
            do {
                let result = try await body(service)
                self?.snapshot = result
                self?.showOpenCodexAction = false
                succeeded = true
            } catch {
                let message: String
                if Task.isCancelled || error is CancellationError {
                    message = "Anmeldung abgebrochen."
                } else {
                    message = error.localizedDescription
                }
                if let actual = try? await service.snapshot() { self?.snapshot = actual }
                self?.error = message
                self?.showOpenCodexAction = title == "Konto wechseln" || title == "Codex öffnen"
            }
            self?.operation = nil
            self?.progress = ""
            self?.cancelling = false
            self?.task = nil
            if refreshAfter, succeeded { self?.refresh() }
        }
    }

    private var progressCallback: AccountProgress {
        { [weak self] message in await self?.setProgress(message) }
    }

    private func setProgress(_ message: String) {
        if !cancelling { progress = message }
    }

    static func previewSnapshot(stress: Bool) -> AccountSnapshot {
        let now = Date()
        var rows = [
            SavedAccountView(id: "sample-a", displayName: "Privat", email: "privat@example.com", isActive: true,
                usage: AccountUsage(fiveHourRemaining: nil, weeklyRemaining: 63, fiveHourReset: nil, weeklyReset: now.addingTimeInterval(180000), fetchedAt: now), error: nil),
            SavedAccountView(id: "sample-b", displayName: "Arbeit", email: "arbeit@example.com", isActive: false,
                usage: AccountUsage(fiveHourRemaining: nil, weeklyRemaining: 28, fiveHourReset: nil, weeklyReset: now.addingTimeInterval(260000), fetchedAt: now), error: nil)
        ]
        if stress {
            rows[1] = SavedAccountView(id: "sample-b", displayName: "Arbeit", email: "arbeit@example.com", isActive: false,
                usage: AccountUsage(fiveHourRemaining: 12, weeklyRemaining: 28, fiveHourReset: now.addingTimeInterval(1500), weeklyReset: now.addingTimeInterval(260000), fetchedAt: now.addingTimeInterval(-3600)), error: "Die Anmeldung ist abgelaufen. Bitte das Konto erneut im Browser anmelden.")
            rows.append(SavedAccountView(id: "sample-c", displayName: "Projekt", email: "projekt@example.com", isActive: false, usage: nil, error: "Limits konnten nicht gelesen werden."))
        }
        return AccountSnapshot(accounts: rows, cliPath: nil, currentAccountLabel: "privat@example.com", notice: nil)
    }
}
