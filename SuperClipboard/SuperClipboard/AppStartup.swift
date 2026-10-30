import AppKit
import SwiftUI

/// Application services and window factories do not depend on a scene appearing.
@MainActor
final class AppStartup: NSObject, NSApplicationDelegate {
    let store: ClipboardStore
    let launchAtLogin: LaunchAtLoginManager

    override convenience init() {
        self.init(store: ClipboardStore(), launchAtLogin: LaunchAtLoginManager())
    }

    init(store: ClipboardStore, launchAtLogin: LaunchAtLoginManager) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        super.init()
    }
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServices()
    }

    func startServices(configureLogin: Bool = true) {
        MenuStatusController.shared.configure(store: store, launchAtLogin: launchAtLogin, open: { [weak self] in self?.open($0) })
        TransferShortcut.shared.configure(store: store) { [weak self] in self?.open("transfer") }
        TransferDragReceiver.shared.configure(store: store) { [weak self] in self?.open("transfer") }
        if configureLogin { launchAtLogin.configureDefaultIfNeeded() }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open("main")
        return false
    }

    func open(_ id: String) {
        let window: NSWindow
        if let existing = windows[id] { window = existing }
        else {
            let transfer = id == "transfer"
            let size = NSSize(width: transfer ? 350 : 440, height: transfer ? 520 : 640)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.title = transfer ? "悬浮中转" : "口袋Cube"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            let root = StartupWindowContent(isTransfer: transfer)
                .environmentObject(store).environmentObject(launchAtLogin)
                .environment(\.clipboardOpenWindow, { [weak self] in self?.open($0) })
                .environment(\.clipboardCloseWindow, { [weak self] in self?.windows[$0]?.close() })
            window.contentViewController = NSHostingController(rootView: root)
            window.center()
            windows[id] = window
        }
        if id == "main" { NSApplication.shared.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct StartupWindowContent: View {
    let isTransfer: Bool
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    var body: some View {
        Group {
            if isTransfer { TransferShelfView() }
            else { ContentView() }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }
}

private struct ClipboardCloseWindowKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}
extension EnvironmentValues {
    var clipboardCloseWindow: ((String) -> Void)? {
        get { self[ClipboardCloseWindowKey.self] }
        set { self[ClipboardCloseWindowKey.self] = newValue }
    }
}
