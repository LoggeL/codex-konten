import AccountCore
import AppKit
import SwiftUI

@MainActor
private final class AccountForm: ObservableObject {
    @Published var name = ""
    @Published var switchCandidate: SavedAccountView?
    @Published var removeCandidate: SavedAccountView?
    @Published var showingAdd = false
    @Published var expandedErrorID: String?
    @Published var contentHeight: CGFloat = 80
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AccountsPanel: View {
    @ObservedObject var model: AccountModel
    @ObservedObject var updates: UpdateController
    var manage = false
    var openManage: (() -> Void)? = nil
    @StateObject private var form = AccountForm()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    if let notice = model.snapshot?.notice, !notice.isEmpty {
                        noticeView(notice)
                    }
                    if model.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { Divider() }
                            accountRow(account)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                })
            }
            .frame(height: manage ? nil : min(form.contentHeight, 440))
            .frame(maxHeight: manage ? .infinity : 440)
            .onPreferenceChange(ContentHeightKey.self) { height in
                if abs(form.contentHeight - height) > 0.5 { form.contentHeight = height }
            }
            if model.busy { operationView }
            if let error = model.error { errorView(error) }
            Divider().padding(.horizontal, 18)
            footer
        }
        .frame(width: manage ? 446 : 390)
        .task {
            updates.bindAccountBusy { model.busy }
            model.bindUpdateInstall { updates.isInstalling }
            model.load()
        }
        .sheet(isPresented: $form.showingAdd) { addSheet }
        .alert("Zu \(form.switchCandidate?.displayName ?? "diesem Konto") wechseln?", isPresented: Binding(get: { form.switchCandidate != nil }, set: { if !$0 { form.switchCandidate = nil } })) {
            Button("Abbrechen", role: .cancel) { form.switchCandidate = nil }
            Button(model.demoMode ? "Wechseln" : "Codex schließen und wechseln", role: model.demoMode ? nil : .destructive) {
                if let account = form.switchCandidate { model.switchAccount(account) }
                form.switchCandidate = nil
            }
        } message: {
            Text(model.demoMode ? "Im Demomodus ändert sich nur das angezeigte Beispielkonto." : "Codex wird geschlossen und neu geöffnet. Laufende Aufgaben werden unterbrochen. Speichere offene Arbeit vor dem Wechsel.")
        }
        .alert("Gespeichertes Konto entfernen?", isPresented: Binding(get: { form.removeCandidate != nil }, set: { if !$0 { form.removeCandidate = nil } })) {
            Button("Abbrechen", role: .cancel) { form.removeCandidate = nil }
            Button("Entfernen", role: .destructive) {
                if let account = form.removeCandidate { model.remove(account) }
                form.removeCandidate = nil
            }
        } message: {
            Text("\(form.removeCandidate?.displayName ?? "Das Konto") verschwindet aus der Liste. Die aktive Codex-Anmeldung bleibt bestehen.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(manage ? "Konten verwalten" : "Codex Konten")
                    .font(.system(size: 20, weight: .semibold))
                if let active = model.accounts.first(where: \.isActive) {
                    Text("Aktiv · \(active.displayName)").lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else {
                    Text(model.snapshot == nil ? "Konto wird geprüft …" : (model.snapshot?.currentAccountLabel.map { "Aktiv: \($0)" } ?? "Kein aktives Konto erkannt"))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .medium)) }
                .buttonStyle(.borderless).disabled(model.busy || updates.isInstalling)
                .help("Limits aktualisieren").accessibilityLabel("Limits aktualisieren")
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func accountRow(_ account: SavedAccountView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(account.email.isEmpty ? "Keine E-Mail-Adresse" : account.email)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if account.isActive {
                    Text("Aktiv")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Aktives Codex-Konto")
                } else {
                    Button { form.switchCandidate = account } label: {
                        Text("Wechseln")
                    }
                        .modifier(SecondaryActionStyle())
                        .foregroundColor(.blue)
                        .controlSize(.regular)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(model.busy || updates.isInstalling)
                        .accessibilityLabel("Zu \(account.displayName) wechseln")
                }
                if manage {
                    Menu {
                        if let error = account.error {
                            Button("Erneut anmelden …") { beginReauth(account) }
                            Button("Fehler anzeigen") { form.expandedErrorID = account.id }
                            Text(error)
                        }
                        Button("Entfernen", role: .destructive) { form.removeCandidate = account }
                            .disabled(model.busy || updates.isInstalling || account.isActive)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.busy || updates.isInstalling)
                    .help("Weitere Aktionen für \(account.displayName)")
                }
            }
            let available = visibleLimits(account)
            if !available.isEmpty {
                VStack(spacing: 12) {
                    ForEach(available) { limit in
                        quotaLine(limit)
                    }
                }
                .padding(.top, 17)
            } else if account.error == nil {
                Text("Limits noch nicht verfügbar")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
            if let usage = account.usage, Date().timeIntervalSince(usage.fetchedAt) > 900 {
                Text("Veraltet · Stand \(germanDate(usage.fetchedAt))")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            if let error = account.error {
                errorLine(error, account: account)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }

    private struct VisibleLimit: Identifiable {
        let id: String
        let title: String
        let remaining: Double
        let reset: Date?
        let fetchedAt: Date
    }

    private func visibleLimits(_ account: SavedAccountView) -> [VisibleLimit] {
        guard let usage = account.usage else { return [] }
        var limits: [VisibleLimit] = []
        if let value = usage.fiveHourRemaining, value.isFinite {
            limits.append(VisibleLimit(id: "5h", title: "5 Stunden", remaining: value, reset: usage.fiveHourReset, fetchedAt: usage.fetchedAt))
        }
        if let value = usage.weeklyRemaining, value.isFinite {
            limits.append(VisibleLimit(id: "week", title: "Woche", remaining: value, reset: usage.weeklyReset, fetchedAt: usage.fetchedAt))
        }
        return limits
    }

    private func quotaLine(_ limit: VisibleLimit) -> some View {
        let value = min(100, max(0, limit.remaining))
        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(limit.title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(Int(value.rounded())) % frei")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            ProgressView(value: value, total: 100)
                .tint(.blue)
                .accessibilityLabel("\(limit.title): \(Int(value.rounded())) Prozent übrig")
            if let reset = limit.reset {
                Text("Reset " + relativeReset(reset))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Rücksetzung: \(germanDate(reset))")
            }
        }
        .help("Stand: \(germanDate(limit.fetchedAt))" + (Date().timeIntervalSince(limit.fetchedAt) > 900 ? ", veraltet" : ""))
    }

    private func errorLine(_ error: String, account: SavedAccountView) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Abruf fehlgeschlagen").lineLimit(1)
                if let usage = account.usage {
                    Text("· Stand \(usage.fetchedAt, style: .relative)")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { form.expandedErrorID = form.expandedErrorID == account.id ? nil : account.id } label: {
                    Image(systemName: form.expandedErrorID == account.id ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Fehlerdetails \(form.expandedErrorID == account.id ? "schließen" : "anzeigen")")
                .accessibilityLabel("Fehlerdetails für \(account.displayName)")
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            if form.expandedErrorID == account.id {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Erneut anmelden …") { beginReauth(account) }
                    .font(.caption).disabled(model.busy || updates.isInstalling)
            }
        }
    }

    private func beginReauth(_ account: SavedAccountView) {
        form.name = account.displayName
        if manage { form.showingAdd = true }
        else {
            openManage?()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Keine gespeicherten Konten").font(.subheadline.weight(.medium))
            Text("Füge ein Konto hinzu, um seine Limits zu sehen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
    }

    private func noticeView(_ notice: String) -> some View {
        Label(notice, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private var operationView: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.operation ?? "").font(.caption.weight(.medium))
                Text(model.progress).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.operation == "Konto anmelden" {
                Button("Abbrechen") { model.cancel() }.disabled(model.cancelling)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if model.showOpenCodexAction {
                Button("Codex öffnen") { model.openCodex() }
                    .disabled(model.busy || updates.isInstalling)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if manage {
                Button { form.showingAdd = true } label: {
                    Label("Konto hinzufügen", systemImage: "plus")
                }
                .disabled(model.busy || updates.isInstalling)
                .modifier(PrimaryActionStyle())
            } else {
                Button {
                    openManage?()
                } label: { Label("Konten verwalten", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Codex öffnen") { model.openCodex() }.disabled(model.busy || updates.isInstalling || model.demoMode)
                if !manage {
                    Button("Konto hinzufügen …") {
                        openManage?()
                    }
                }
                Divider()
                Button("Nach Updates suchen …") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates || model.busy)
                Toggle("Automatisch nach Updates suchen", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.automaticallyChecksForUpdates = $0 }
                ))
                if let status = updates.statusText {
                    Text(status)
                }
                Divider()
                Button("Beenden") { NSApp.terminate(nil) }.disabled(model.busy)
            } label: { Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium)) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Weitere Aktionen")
        }
        .padding(.horizontal, 22).padding(.vertical, 15)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Konto hinzufügen").font(.title3.weight(.semibold))
                Text("Die Anmeldung öffnet sich im Browser.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TextField("Name, z. B. Arbeit", text: $form.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name für neues Konto")
            HStack {
                Button("Abbrechen") { form.showingAdd = false }
                Spacer()
                Button("Im Browser anmelden") {
                    model.add(name: form.name)
                    form.showingAdd = false
                }
                .disabled(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || updates.isInstalling)
                .modifier(PrimaryActionStyle())
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

private struct PrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct SecondaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private func germanDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "de_DE")))
}

private func relativeReset(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}
