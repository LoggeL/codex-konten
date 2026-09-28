import AppKit
import SwiftUI

@main
struct CodexAccountsApp: App {
    @StateObject private var model = AccountModel(
        preview: ProcessInfo.processInfo.arguments.contains("--preview"),
        demo: Self.isDemoMode
    )
    @StateObject private var updates = UpdateController(
        preview: ProcessInfo.processInfo.arguments.contains("--preview") ||
            (ProcessInfo.processInfo.arguments.contains("--demo") && !ProcessInfo.processInfo.arguments.contains("--updater-demo"))
    )

    private static var isDemoMode: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--demo") || arguments.contains("--updater-demo") ||
            (Bundle.main.object(forInfoDictionaryKey: "CodexAccountsDemoMode") as? Bool == true)
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            PreviewRenderer.renderAndExit()
        }
        if Self.isDemoMode, ProcessInfo.processInfo.arguments.contains("--dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var body: some Scene {
        MenuBarExtra("Codex Konten", systemImage: "person.2", isInserted: .constant(
            Bundle.main.object(forInfoDictionaryKey: "CodexAccountsHeadlessTestMode") as? Bool != true
        )) {
            AccountsPanel(model: model, updates: updates)
        }.menuBarExtraStyle(.window)
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
