import AppKit

@main struct AppStartupTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StartupTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PocketCube.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: root, defaults: defaults, pasteboard: board, observesPasteboard: false)
        let startup = AppStartup(store: store, launchAtLogin: LaunchAtLoginManager(defaults: defaults))
        startup.startServices(configureLogin: false)
        precondition(TransferDragReceiver.shared.isMonitoring, "Cold startup must install drag polling and local events without a view appearing")
        precondition(!TransferDragReceiver.shared.isHintVisible)
        precondition(TransferShortcut.shared.onTrigger != nil)
        precondition(MenuPopoverShortcut.shared.onTrigger != nil)
        precondition(!app.windows.contains(where: { $0.isVisible && $0.level == .normal }), "Cold startup must not show main, transfer, or drop windows")
        startup.startServices(configureLogin: false)
        precondition(TransferDragReceiver.shared.isMonitoring)
        precondition(!app.windows.contains(where: { $0.isVisible && $0.level == .normal }))
        precondition(!startup.applicationShouldTerminateAfterLastWindowClosed(app))
        print("PASS: cold startup installs status shortcut and drag services without showing any window; repeated initialization stays safe")
    }
}
