import AppKit
import SwiftUI

@MainActor
private enum AppServices {
    static let arguments = ProcessInfo.processInfo.arguments
    static let demoMode = arguments.contains("--demo") || arguments.contains("--updater-demo") ||
        (Bundle.main.object(forInfoDictionaryKey: "CodexAccountsDemoMode") as? Bool == true)
    static let model = AccountModel(preview: arguments.contains("--preview"), demo: demoMode)
    static let updates = UpdateController(preview: arguments.contains("--preview") ||
        (arguments.contains("--demo") && !arguments.contains("--updater-demo")))

    static func start() { model.startBackgroundRefresh(updates: updates) }
}

@main
struct CodexAccountsApp: App {
    @StateObject private var model = AppServices.model
    @StateObject private var updates = AppServices.updates

    init() {
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            PreviewRenderer.renderAndExit()
        }
        if AppServices.demoMode, ProcessInfo.processInfo.arguments.contains("--dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        AppServices.start()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(
            Bundle.main.object(forInfoDictionaryKey: "CodexAccountsHeadlessTestMode") as? Bool != true
        )) {
            AccountsPanel(model: model, updates: updates)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                if let remaining = model.menuBarRemaining {
                    Text("\(remaining.percent)%").monospacedDigit()
                }
            }
            .help(model.menuBarDescription)
            .accessibilityLabel(model.menuBarDescription)
        }
        .menuBarExtraStyle(.window)
        Window("Konten verwalten", id: "accounts") {
            AccountsPanel(model: model, updates: updates, manage: true).frame(minHeight: 380)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 446, height: 480)
        .defaultPosition(.center)
    }
}

@MainActor
enum PreviewRenderer {
    static func renderAndExit() {
        let arguments = ProcessInfo.processInfo.arguments
        let destination = arguments.firstIndex(of: "--preview").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        } ?? "/tmp/codex-konten-preview.png"
        _ = NSApplication.shared
        let model = AccountModel(preview: true, previewStress: arguments.contains("--preview-error"))
        let updates = UpdateController(preview: true)
        if arguments.contains("--preview-login") {
            model.operation = "Konto anmelden"
            model.progress = "Browser geöffnet. Warte auf erfolgreiche Anmeldung …"
        }
        let dark = arguments.contains("--dark")
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let manage = arguments.contains("--manage")
        let view = NSHostingView(rootView:
            // The offscreen renderer has no system popover backdrop. This opaque
            // preview background is only for fixture screenshots, never live UI.
            AccountsPanel(model: model, updates: updates, manage: manage)
            .frame(height: manage ? 430 : nil)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: "de_DE"))
            .environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: NSSize(width: manage ? 446 : 390, height: 700))
        // Let content measurements settle, then capture the same intrinsic size
        // used by MenuBarExtra rather than cropping into a fixed preview height.
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            view.setFrameSize(view.fittingSize)
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: destination)); exit(0) }
        catch { fputs("Preview konnte nicht gespeichert werden: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
