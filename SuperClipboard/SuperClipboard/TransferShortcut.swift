import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class TransferShortcut: ObservableObject {
    static let shared = TransferShortcut()
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
        enabled = defaults.object(forKey: "transferShortcut.enabled") as? Bool ?? true
        key = UInt32(defaults.object(forKey: "transferShortcut.key") as? Int ?? 9)
        modifiers = UInt32(defaults.object(forKey: "transferShortcut.modifiers") as? Int ?? Int(cmdKey | optionKey))
        label = defaults.string(forKey: "transferShortcut.label") ?? "⌥⌘V"
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == 0x53435452 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<TransferShortcut>.fromOpaque(context).takeUnretainedValue()
                if !owner.recording { owner.onTrigger?() }
            }
            return noErr
        }, 1, &type, context, &handler)
        if status != noErr { error = "无法启用全局快捷键。" }
        if enabled { register() }
    }

    func configure(store: ClipboardStore, open: @escaping () -> Void) {
        // Retain resolved dependencies, not a SwiftUI environment wrapper.
        onTrigger = {
            store.transferWindowDidOpen()
            AppWindowCoordinator.showTransferWindow(open: open)
        }
    }

    private func register() {
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x53435452, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        error = status == noErr ? nil : "快捷键已被占用，请选择其他组合。"
    }

    func setEnabled(_ value: Bool) {
        cancelRecording()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        enabled = value
        defaults.set(value, forKey: "transferShortcut.enabled")
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
        defaults.set(Int(key), forKey: "transferShortcut.key")
        defaults.set(Int(modifiers), forKey: "transferShortcut.modifiers")
        defaults.set(label, forKey: "transferShortcut.label")
        error = nil
        cancelRecording()
        return true
    }

    func restoreDefault() {
        cancelRecording()
        _ = update(key: 9, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘V")
    }

    func startRecording() {
        cancelRecording()
        recording = true
        error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.keyCode == 53 { self.cancelRecording(); return true }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var modifiers: UInt32 = 0
                var prefix = ""
                if flags.contains(.control) { modifiers |= UInt32(controlKey); prefix += "⌃" }
                if flags.contains(.option) { modifiers |= UInt32(optionKey); prefix += "⌥" }
                if flags.contains(.shift) { modifiers |= UInt32(shiftKey); prefix += "⇧" }
                if flags.contains(.command) { modifiers |= UInt32(cmdKey); prefix += "⌘" }
                guard let character = Self.keyLabel(event) else {
                    self.error = "请选择字母、数字、方向键或空格键。"; return true
                }
                _ = self.update(key: UInt32(event.keyCode), modifiers: modifiers, label: prefix + character)
                return true
            }
            return handled ? nil : event
        }
    }

    private static func keyLabel(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 49: return "空格"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let value = event.charactersIgnoringModifiers?.uppercased(), value.count == 1,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
            return value
        }
    }

    func cancelRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct TransferShortcutInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let store: ClipboardStore

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            TransferShortcut.shared.configure(store: store) { action(id: "transfer") }
        }
    }
}

struct TransferShortcutSettings: View {
    @ObservedObject private var shortcut = TransferShortcut.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("使用全局快捷键", isOn: Binding(get: { shortcut.enabled }, set: shortcut.setEnabled))
                .toggleStyle(.switch)
            HStack {
                Text("显示中转站")
                Spacer()
                Button(shortcut.recording ? "请按新组合…" : shortcut.label) {
                    if shortcut.recording { shortcut.cancelRecording() } else { shortcut.startRecording() }
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(shortcut.recording ? ClipboardTheme.selectedSurface : ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shortcut.recording ? ClipboardTheme.focusRing : ClipboardTheme.border))
                .buttonStyle(ClipboardControlStyle())
                .disabled(!shortcut.enabled)
                .accessibilityLabel("修改显示中转站快捷键，当前为 \(shortcut.label)")
            }
            HStack {
                Text(shortcut.recording ? "按 Esc 取消录制" : "在其他软件中也可使用")
                    .font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
                Spacer()
                Button("恢复默认", action: shortcut.restoreDefault).font(.system(size: 11))
                    .disabled(shortcut.recording)
            }
            if let error = shortcut.error {
                Text(error).font(.system(size: 11)).foregroundStyle(ClipboardTheme.dangerText)
            }
        }
        .onDisappear { shortcut.cancelRecording() }
    }
}
