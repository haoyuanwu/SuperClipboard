import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class MenuPopoverShortcut: ObservableObject {
    static let shared = MenuPopoverShortcut()
    @Published private(set) var enabled: Bool
    @Published private(set) var label: String
    @Published private(set) var recording = false
    @Published private(set) var error: String?
    var onTrigger: (() -> Void)?
    private let defaults: UserDefaults
    private var key: UInt32
    private var modifiers: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var monitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "popoverShortcut.enabled") as? Bool ?? true
        key = UInt32(defaults.object(forKey: "popoverShortcut.key") as? Int ?? 8)
        modifiers = UInt32(defaults.object(forKey: "popoverShortcut.modifiers") as? Int ?? Int(cmdKey | optionKey))
        label = defaults.string(forKey: "popoverShortcut.label") ?? "⌥⌘C"
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == 0x53435050 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<MenuPopoverShortcut>.fromOpaque(context).takeUnretainedValue()
                if !owner.recording && !TransferShortcut.shared.recording { owner.onTrigger?() }
            }
            return noErr
        }, 1, &type, context, &handler)
        if status != noErr { error = "无法启用弹窗全局快捷键。" }
        if enabled { register() }
    }

    private func register() {
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x53435050, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        error = status == noErr ? nil : "快捷键已被占用，请选择其他组合。"
    }

    func setEnabled(_ value: Bool) {
        cancelRecording()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        enabled = value
        defaults.set(value, forKey: "popoverShortcut.enabled")
        error = nil
        if value { register() }
    }

    @discardableResult
    func update(key: UInt32, modifiers: UInt32, label: String) -> Bool {
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            error = "请搭配 Command、Option 或 Control 键。"
            return false
        }
        let previous = (self.key, self.modifiers, self.label)
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        self.key = key; self.modifiers = modifiers
        if enabled { register() }
        if let failure = error, enabled {
            self.key = previous.0; self.modifiers = previous.1
            register()
            error = failure
            return false
        }
        self.label = label
        defaults.set(Int(key), forKey: "popoverShortcut.key")
        defaults.set(Int(modifiers), forKey: "popoverShortcut.modifiers")
        defaults.set(label, forKey: "popoverShortcut.label")
        error = nil
        cancelRecording()
        return true
    }

    func restoreDefault() {
        cancelRecording()
        _ = update(key: 8, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘C")
    }

    func startRecording() {
        TransferShortcut.shared.cancelRecording()
        cancelRecording()
        recording = true
        error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.keyCode == 53 { self.cancelRecording(); return true }
                guard let label = TransferShortcut.keyLabel(event) else {
                    self.error = "请使用修饰键搭配字母、数字、方向键或空格。"
                    return true
                }
                var modifiers: UInt32 = 0
                if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
                if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
                if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
                if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
                _ = self.update(key: UInt32(event.keyCode), modifiers: modifiers, label: (event.modifierFlags.contains(.control) ? "⌃" : "")
                    + (event.modifierFlags.contains(.option) ? "⌥" : "")
                    + (event.modifierFlags.contains(.shift) ? "⇧" : "")
                    + (event.modifierFlags.contains(.command) ? "⌘" : "") + label)
                return true
            }
            return handled ? nil : event
        }
    }

    func cancelRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Own the native status item so keyboard and mouse open the same anchored popover.
@MainActor
final class MenuStatusController: NSObject {
    static let shared = MenuStatusController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func configure(store: ClipboardStore, launchAtLogin: LaunchAtLoginManager, openWindow: OpenWindowAction) {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarLogo")?.copy() as? NSImage
            image?.size = NSSize(width: 22, height: 22)
            image?.accessibilityDescription = "口袋Cube"
            image?.isTemplate = true
            button.image = image
            button.toolTip = "口袋Cube"
            button.target = self
            button.action = #selector(togglePopover)
        }
        self.statusItem = statusItem
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 520)
        popover.contentViewController = NSHostingController(rootView:
            MenuStatusContent()
                .environmentObject(store)
                .environmentObject(launchAtLogin)
                .environment(\.clipboardOpenWindow, openWindow))
        let shortcut = MenuPopoverShortcut.shared
        shortcut.onTrigger = { [weak self] in self?.showPopover() }
        TransferShortcut.shared.onStartRecording = { [weak shortcut] in shortcut?.cancelRecording() }
        TransferShortcut.shared.permitsTrigger = { [weak shortcut] in shortcut?.recording != true }
    }

    @objc private func togglePopover() {
        if popover.isShown && AppWindowCoordinator.isPopoverVisible { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown && AppWindowCoordinator.isPopoverVisible { return }
        if popover.isShown { popover.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

private struct MenuStatusContent: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    var body: some View {
        MenuPopoverView()
            .task { launchAtLogin.configureDefaultIfNeeded() }
            .preferredColorScheme(appearanceMode.colorScheme)
    }
}

struct MenuStatusInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let store: ClipboardStore
    let launchAtLogin: LaunchAtLoginManager
    func body(content: Content) -> some View {
        content.onAppear {
            MenuStatusController.shared.configure(store: store, launchAtLogin: launchAtLogin, openWindow: openWindow)
        }
    }
}

struct MenuPopoverShortcutSettings: View {
    @ObservedObject private var shortcut = MenuPopoverShortcut.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("使用弹窗全局快捷键", isOn: Binding(get: { shortcut.enabled }, set: shortcut.setEnabled))
                .toggleStyle(.switch)
            HStack {
                Text("打开状态栏弹窗")
                Spacer()
                Button(shortcut.recording ? "请按新组合…" : shortcut.label) {
                    if shortcut.recording { shortcut.cancelRecording() } else { shortcut.startRecording() }
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shortcut.recording ? ClipboardTheme.focusRing : ClipboardTheme.border))
                .buttonStyle(ClipboardControlStyle())
                .disabled(!shortcut.enabled)
                .accessibilityLabel("修改打开状态栏弹窗快捷键，当前为 \(shortcut.label)")
            }
            HStack {
                Text(shortcut.recording ? "按 Esc 取消录制" : "在其他软件中也可直接打开")
                    .foregroundStyle(ClipboardTheme.secondary)
                Spacer()
                Button("恢复默认", action: shortcut.restoreDefault).disabled(shortcut.recording)
            }.font(.system(size: 11))
            if let error = shortcut.error { Text(error).font(.system(size: 11)).foregroundStyle(ClipboardTheme.dangerText) }
            Label("弹窗内按 ⌘1–⌘9，复制当前列表第 1–9 条；搜索和记事本同样适用。", systemImage: "command")
                .font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { shortcut.cancelRecording() }
    }
}

private struct ClipboardOpenWindowKey: EnvironmentKey {
    static let defaultValue: OpenWindowAction? = nil
}

extension EnvironmentValues {
    var clipboardOpenWindow: OpenWindowAction? {
        get { self[ClipboardOpenWindowKey.self] }
        set { self[ClipboardOpenWindowKey.self] = newValue }
    }
}
