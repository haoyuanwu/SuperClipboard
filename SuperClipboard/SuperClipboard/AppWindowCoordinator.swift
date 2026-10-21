import AppKit
import Combine
import SwiftUI

enum AppWindowRole {
    case main, popover
}

@MainActor
enum AppWindowCoordinator {
    private static weak var mainWindow: NSWindow?
    private static weak var popoverWindow: NSWindow?
    private static var needsMainWindowFocus = false

    static func register(_ window: NSWindow, role: AppWindowRole, appearance: AppAppearanceMode) {
        switch role {
        case .main:
            mainWindow = window
        case .popover:
            popoverWindow = window
        }
        // Registration can happen during SwiftUI layout. Defer native window
        // changes so they cannot trigger a nested layout pass.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            let desiredAppearance = appearance.windowAppearance
            if window.appearance?.name != desiredAppearance?.name {
                window.appearance = desiredAppearance
            }
            if case .main = role {
                if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
                focusMainWindowIfNeeded()
            }
        }
    }

    static func showMainWindow(open: () -> Void) {
        popoverWindow?.orderOut(nil)
        needsMainWindowFocus = true
        open()
        // SwiftUI may create or restore the scene on the next run loop.
        DispatchQueue.main.async { focusMainWindowIfNeeded() }
    }

    private static func focusMainWindowIfNeeded() {
        guard needsMainWindowFocus, let window = mainWindow else { return }
        needsMainWindowFocus = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(role: role, appearanceMode: appearanceMode, onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.onVisibilityChange = onVisibilityChange
        view.appearanceMode = appearanceMode
        view.registerWindowIfNeeded()
    }

    final class WindowProbe: NSView {
        let role: AppWindowRole
        var appearanceMode: AppAppearanceMode
        var onVisibilityChange: ((Bool) -> Void)?
        private var visibilityObservation: NSKeyValueObservation?
        private var occlusionObservation: AnyCancellable?
        private var lastVisibility: Bool?
        private weak var registeredWindow: NSWindow?
        private var registeredAppearance: AppAppearanceMode?

        init(role: AppWindowRole, appearanceMode: AppAppearanceMode, onVisibilityChange: ((Bool) -> Void)?) {
            self.role = role
            self.appearanceMode = appearanceMode
            self.onVisibilityChange = onVisibilityChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibilityObservation = nil
            occlusionObservation = nil
            lastVisibility = nil
            guard let window else { return }
            registerWindowIfNeeded()
            guard onVisibilityChange != nil else { return }
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
            onVisibilityChange?(visible)
        }
    }
}
