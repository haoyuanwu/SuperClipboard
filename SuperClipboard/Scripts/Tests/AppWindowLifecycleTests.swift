import AppKit
import SwiftUI

@main
struct AppWindowLifecycleTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Lifecycle test")
        defer { NSStatusBar.system.removeStatusItem(status) }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = AppWindowObserver.WindowProbe(role: .main, appearanceMode: .light, onVisibilityChange: nil)
        window.orderFront(nil)
        try await settle()
        precondition(app.activationPolicy() == .regular)

        window.miniaturize(nil)
        try await settle()
        precondition(app.activationPolicy() == .regular, "Minimizing must keep the Dock icon")
        window.deminiaturize(nil)
        try await settle()
        window.close()
        try await settle()
        precondition(app.activationPolicy() == .accessory, "Closing the main window must hide the Dock icon")
        precondition(status.button != nil, "The status bar entry must remain available")

        AppWindowCoordinator.showMainWindow { window.orderFront(nil) }
        try await settle()
        precondition(window.isVisible && app.activationPolicy() == .regular, "Reopening must restore the main window and Dock icon")
        window.close()
        try await settle()
        precondition(app.activationPolicy() == .accessory, "Repeated closes must still hide the Dock icon")

        // Native scene restoration can show the window without the popover action.
        window.orderFront(nil)
        try await settle()
        precondition(app.activationPolicy() == .regular, "Native window restoration must restore Dock presence")
        window.close()
        try await settle()
        var transferClosed = false
        let transfer = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 520),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        transfer.isReleasedWhenClosed = false
        transfer.contentView = AppWindowObserver.WindowProbe(role: .transfer, appearanceMode: .light,
            onVisibilityChange: nil, onClose: { transferClosed = true })
        AppWindowCoordinator.showTransferWindow { transfer.orderFront(nil) }
        try await settle()
        precondition(transfer.level == .floating && !transfer.hidesOnDeactivate)
        precondition(transfer.collectionBehavior.contains(.canJoinAllSpaces))
        precondition(transfer.collectionBehavior.contains(.fullScreenAuxiliary))
        precondition(app.activationPolicy() == .accessory, "A floating transfer must not restore the closed main window's Dock icon")
        AppWindowCoordinator.showTransferWindow { transfer.orderFront(nil) }
        try await settle()
        precondition(transfer.isVisible && transfer.level == .floating)
        transfer.close()
        try await settle()
        precondition(transferClosed, "Native close must deliver the transfer cleanup lifecycle callback")
        print("PASS: close, status entry retention, reopen, repeated close, minimization and native restoration")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }
}
