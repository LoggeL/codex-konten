import AppKit
import Combine
import SwiftUI

@MainActor
private enum AppServices {
    static let arguments = ProcessInfo.processInfo.arguments
    static let lifecycleSelfTest = arguments.contains("--lifecycle-self-test")
    static let lifecycleResultPath = arguments.firstIndex(of: "--lifecycle-self-test").flatMap { index in
        index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") ? arguments[index + 1] : nil
    }
    static let demoMode = arguments.contains("--demo") || arguments.contains("--updater-demo") ||
        lifecycleSelfTest ||
        (Bundle.main.object(forInfoDictionaryKey: "CodexAccountsDemoMode") as? Bool == true)
    static let model = AccountModel(preview: arguments.contains("--preview"), demo: demoMode)
    static let updates = UpdateController(preview: arguments.contains("--preview") ||
        lifecycleSelfTest || (arguments.contains("--demo") && !arguments.contains("--updater-demo")))

    static func start() { model.startBackgroundRefresh(updates: updates) }
}

@main
@MainActor
private enum CodexAccountsMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        if AppServices.arguments.contains("--preview") { PreviewRenderer.renderAndExit() }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if AppServices.demoMode, AppServices.arguments.contains("--dark") {
            application.appearance = NSAppearance(named: .darkAqua)
        }
        application.mainMenu = makeMainMenu()
        application.delegate = appDelegate
        AppServices.start()
        application.run()
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Codex Konten")
        app.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        for (title, action, key) in [
            ("Rückgängig", "undo:", "z"),
            ("Wiederholen", "redo:", "Z"),
            ("Ausschneiden", "cut:", "x"),
            ("Kopieren", "copy:", "c"),
            ("Einfügen", "paste:", "v"),
            ("Alles auswählen", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var manageWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar utility must remain resident when its last window closes.
        ProcessInfo.processInfo.disableAutomaticTermination("Codex Konten menu bar item")
        guard Bundle.main.object(forInfoDictionaryKey: "CodexAccountsHeadlessTestMode") as? Bool != true else { return }
        statusItemController = StatusItemController(model: AppServices.model, updates: AppServices.updates) { [weak self] in
            self?.openManageWindow()
        }
        if AppServices.lifecycleSelfTest { runLifecycleSelfTest() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showPopup()
        return true
    }

    private func openManageWindow() {
        statusItemController?.closePopup()
        if manageWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 446, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Konten verwalten"
            window.contentViewController = NSHostingController(rootView:
                AccountsPanel(model: AppServices.model, updates: AppServices.updates, manage: true)
                    .frame(minHeight: 380))
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 446, height: 380)
            window.center()
            manageWindow = window
        }
        manageWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runLifecycleSelfTest() {
        Task { @MainActor in
            // Let AppKit finish the launch event before presenting the popup.
            await Task.yield()
            guard let statusItemController,
                  statusItemController.isVisible,
                  statusItemController.title == "63%",
                  manageWindow == nil else { Self.selfTestFailed("initial state") }

            statusItemController.togglePopup()
            let shownImmediately = statusItemController.isPopupShown
            try? await Task.sleep(for: .milliseconds(250))
            guard statusItemController.isPopupShown else {
                Self.selfTestFailed("popup open; immediate=\(shownImmediately); \(statusItemController.diagnostics)")
            }
            statusItemController.togglePopup()
            try? await Task.sleep(for: .milliseconds(250))
            guard !statusItemController.isPopupShown, statusItemController.isVisible else {
                Self.selfTestFailed("popup close")
            }
            statusItemController.togglePopup()
            try? await Task.sleep(for: .milliseconds(250))
            guard statusItemController.isPopupShown else { Self.selfTestFailed("popup reopen") }

            openManageWindow()
            guard let manageWindow, manageWindow.isVisible, !statusItemController.isPopupShown else {
                Self.selfTestFailed("management window open")
            }
            manageWindow.close()
            try? await Task.sleep(for: .milliseconds(250))
            guard !manageWindow.isVisible, statusItemController.isVisible, NSApp.isRunning else {
                Self.selfTestFailed("management window close")
            }

            guard let other = AppServices.model.accounts.first(where: { !$0.isActive }) else {
                Self.selfTestFailed("demo account")
            }
            AppServices.model.switchAccount(other)
            try? await Task.sleep(for: .milliseconds(250))
            guard statusItemController.title == "28%", statusItemController.isVisible else {
                Self.selfTestFailed("active percentage update")
            }
            Self.writeSelfTestResult("PASS")
            print("lifecycle-self-test: PASS")
            exit(0)
        }
    }

    private static func selfTestFailed(_ stage: String) -> Never {
        writeSelfTestResult("FAIL (\(stage))")
        fputs("lifecycle-self-test: FAIL (\(stage))\n", stderr)
        exit(1)
    }

    private static func writeSelfTestResult(_ result: String) {
        guard let path = AppServices.lifecycleResultPath else { return }
        try? result.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@MainActor
private final class StatusPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PopupContainerController: NSViewController {
    var contentSizeDidChange: (() -> Void)?

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        contentSizeDidChange?()
    }
}

@MainActor
private final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popupPanel: StatusPopupPanel
    private let hostingController: NSHostingController<AccountsPanel>
    private let model: AccountModel
    private var snapshotSubscription: AnyCancellable?
    private var modelChangeSubscription: AnyCancellable?
    private var resizeTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var localEscapeMonitor: Any?

    var title: String? { statusItem.button?.title }
    var isVisible: Bool { statusItem.isVisible && statusItem.button != nil }
    var isPopupShown: Bool { popupPanel.isVisible }
    var diagnostics: String {
        let button = statusItem.button
        let frame = button?.window?.frame ?? .zero
        let screen = button?.window?.screen?.visibleFrame ?? .zero
        let fitting = hostingController.view.fittingSize
        let content = popupPanel.contentView?.bounds.size ?? .zero
        return "buttonWindow=\(button?.window != nil); buttonWindowVisible=\(button?.window?.isVisible == true); " +
            "buttonWidth=\(Int(button?.bounds.width ?? 0)); " +
            "buttonFrame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)); " +
            "screenVisible=\(Int(screen.minX)),\(Int(screen.minY)),\(Int(screen.width)),\(Int(screen.height)); " +
            "panelVisible=\(popupPanel.isVisible); panelContent=\(Int(content.width))x\(Int(content.height)); " +
            "fittingSize=\(Int(fitting.width))x\(Int(fitting.height)); " +
            "appActive=\(NSApp.isActive); appRunning=\(NSApp.isRunning)"
    }

    init(model: AccountModel, updates: UpdateController, openManage: @escaping () -> Void) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hostingController = NSHostingController(rootView:
            AccountsPanel(model: model, updates: updates, openManage: openManage))
        popupPanel = StatusPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        hostingController.sizingOptions = [.preferredContentSize]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        let container = PopupContainerController()
        container.view = background
        container.addChild(hostingController)
        container.contentSizeDidChange = { [weak self] in self?.schedulePopupResize() }
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: background.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        popupPanel.contentViewController = container
        popupPanel.isReleasedWhenClosed = false
        popupPanel.isOpaque = false
        popupPanel.backgroundColor = .clear
        popupPanel.hasShadow = true
        popupPanel.level = .popUpMenu
        popupPanel.hidesOnDeactivate = false
        popupPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        sizePopupToFit()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopup)
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        statusItem.isVisible = true
        updateTitle()
        snapshotSubscription = model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            // Published values arrive before the property changes; update on the next turn.
            Task { @MainActor [weak self] in
                self?.updateTitle()
                self?.schedulePopupResize()
            }
        }
        modelChangeSubscription = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedulePopupResize() }
        }
    }

    private func schedulePopupResize() {
        guard resizeTask == nil else { return }
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.resizeTask = nil
            self.sizePopupToFit()
        }
    }

    private func sizePopupToFit() {
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let current = popupPanel.contentView?.bounds.size ?? .zero
        if abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 {
            popupPanel.setContentSize(size)
        }
        if popupPanel.isVisible { positionPopup() }
    }

    private func positionPopup() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonWindow.frame
        let width = popupPanel.frame.width
        let height = popupPanel.frame.height
        let preferredX = buttonWindow.frame.midX - width / 2
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - width - 8)
        let y = max(visible.minY + 8, buttonWindow.frame.minY - height - 4)
        popupPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.title = model.menuBarRemaining.map { "\($0.percent)%" } ?? "…"
        button.toolTip = model.menuBarDescription
        button.setAccessibilityLabel(model.menuBarDescription)
    }

    func closePopup() {
        guard popupPanel.isVisible else { return }
        popupPanel.orderOut(nil)
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor); self.localEscapeMonitor = nil }
    }

    func showPopup() {
        guard !popupPanel.isVisible, statusItem.button?.window != nil else { return }
        sizePopupToFit()
        positionPopup()
        popupPanel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popupPanel.makeKeyAndOrderFront(nil)
        installCloseMonitors()
    }

    @objc func togglePopup() {
        if popupPanel.isVisible {
            closePopup()
        } else {
            showPopup()
        }
    }

    private func installCloseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopup() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.popupPanel.isVisible,
                      event.window === self.popupPanel,
                      self.popupPanel.attachedSheet == nil else { return false }
                self.closePopup()
                return true
            }
            return closed ? nil : event
        }
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
