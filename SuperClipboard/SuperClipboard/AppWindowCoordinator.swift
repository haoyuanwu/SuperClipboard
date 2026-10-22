import AppKit
import Combine
import SwiftUI

enum AppWindowRole {
    case main, popover, transfer
}

@MainActor
enum AppWindowCoordinator {
    private static weak var mainWindow: NSWindow?
    private static weak var popoverWindow: NSWindow?
    private static var needsMainWindowFocus = false
    private static var mainWindowCloseObservation: AnyCancellable?
    private static weak var transferWindow: NSWindow?
    private static var needsTransferWindowFocus = false

    static func register(_ window: NSWindow, role: AppWindowRole, appearance: AppAppearanceMode) {
        switch role {
        case .main:
            if mainWindow !== window {
                mainWindow = window
                mainWindowCloseObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                    .sink { [weak window] _ in
                        // Let the close finish before changing the app's Dock presence.
                        DispatchQueue.main.async {
                            guard mainWindow === window, window?.isVisible != true, !needsMainWindowFocus else { return }
                            setDockVisible(false)
                        }
                    }
            }
        case .popover:
            popoverWindow = window
        case .transfer:
            transferWindow = window
        }
        // Registration can happen during SwiftUI layout. Defer native window
        // changes so they cannot trigger a nested layout pass.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            let desiredAppearance = appearance.windowAppearance
            if window.appearance?.name != desiredAppearance?.name {
                window.appearance = desiredAppearance
            }
            if role == .popover || role == .transfer {
                if window.isOpaque { window.isOpaque = false }
                if window.backgroundColor != .clear { window.backgroundColor = .clear }
            }
            if case .main = role {
                if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
                if window.isVisible || window.isMiniaturized { setDockVisible(true) }
                focusMainWindowIfNeeded()
            }
            if case .transfer = role {
                window.level = .floating
                window.hidesOnDeactivate = false
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.tabbingMode = .disallowed
                focusTransferWindowIfNeeded()
            }
        }
    }

    static func showMainWindow(open: () -> Void) {
        popoverWindow?.orderOut(nil)
        setDockVisible(true)
        needsMainWindowFocus = true
        open()
        // SwiftUI may create or restore the scene on the next run loop.
        DispatchQueue.main.async { focusMainWindowIfNeeded() }
    }

    private static func focusMainWindowIfNeeded() {
        guard needsMainWindowFocus, let window = mainWindow else { return }
        needsMainWindowFocus = false
        setDockVisible(true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func mainWindowBecameVisible() {
        setDockVisible(true)
    }

    static func showTransferWindow(open: () -> Void) {
        popoverWindow?.orderOut(nil)
        needsTransferWindowFocus = true
        open()
        DispatchQueue.main.async { focusTransferWindowIfNeeded() }
    }

    private static func focusTransferWindowIfNeeded() {
        guard needsTransferWindowFocus, let window = transferWindow else { return }
        needsTransferWindowFocus = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func setDockVisible(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != policy {
            NSApplication.shared.setActivationPolicy(policy)
        }
        if !visible, transferWindow?.isVisible == true { transferWindow?.orderFrontRegardless() }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { }

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct AppWindowObserver: NSViewRepresentable {
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    let role: AppWindowRole
    var onVisibilityChange: ((Bool) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(role: role, appearanceMode: appearanceMode, onVisibilityChange: onVisibilityChange, onClose: onClose)
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.onVisibilityChange = onVisibilityChange
        view.onClose = onClose
        view.appearanceMode = appearanceMode
        view.registerWindowIfNeeded()
    }

    final class WindowProbe: NSView {
        let role: AppWindowRole
        var appearanceMode: AppAppearanceMode
        var onVisibilityChange: ((Bool) -> Void)?
        var onClose: (() -> Void)?
        private var visibilityObservation: NSKeyValueObservation?
        private var occlusionObservation: AnyCancellable?
        private var closeObservation: AnyCancellable?
        private var lastVisibility: Bool?
        private weak var registeredWindow: NSWindow?
        private var registeredAppearance: AppAppearanceMode?

        init(role: AppWindowRole, appearanceMode: AppAppearanceMode, onVisibilityChange: ((Bool) -> Void)?, onClose: (() -> Void)? = nil) {
            self.role = role
            self.appearanceMode = appearanceMode
            self.onVisibilityChange = onVisibilityChange
            self.onClose = onClose
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibilityObservation = nil
            occlusionObservation = nil
            closeObservation = nil
            lastVisibility = nil
            guard let window else { return }
            registerWindowIfNeeded()
            if onClose != nil {
                closeObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                    .sink { [weak self] _ in self?.onClose?() }
            }
            guard role == .main || onVisibilityChange != nil else { return }
            visibilityObservation = window.observe(\.isVisible, options: [.initial, .old, .new]) { [weak self] window, change in
                guard change.oldValue != change.newValue else { return }
                DispatchQueue.main.async { self?.reportVisibility() }
            }
            // Some system panels report ordering changes through occlusion notifications.
            occlusionObservation = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.reportVisibility() }
                }
        }

        func registerWindowIfNeeded() {
            guard let window,
                  registeredWindow !== window || registeredAppearance != appearanceMode else { return }
            registeredWindow = window
            registeredAppearance = appearanceMode
            AppWindowCoordinator.register(window, role: role, appearance: appearanceMode)
        }

        private func reportVisibility() {
            guard let visible = window?.isVisible, visible != lastVisibility else { return }
            lastVisibility = visible
            if role == .main && visible { AppWindowCoordinator.mainWindowBecameVisible() }
            onVisibilityChange?(visible)
        }
    }
}
