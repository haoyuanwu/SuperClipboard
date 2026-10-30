import SwiftUI

@main
struct SuperClipboardApp: App {
    @NSApplicationDelegateAdaptor private var startup: AppStartup

    // Settings does not create a window on launch. Native status-item and drag
    // services start in applicationDidFinishLaunching, before any window exists.
    var body: some Scene {
        Settings {
            ClipboardSettingsView()
                .environmentObject(startup.store)
                .environmentObject(startup.launchAtLogin)
        }
    }
}
