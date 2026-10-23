import AppKit
import Carbon

@main
struct TransferShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "SuperClipboard.ShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "transferShortcut.enabled")
        let shortcut = TransferShortcut(defaults: defaults)
        precondition(shortcut.label == "⌥⌘V" && !shortcut.enabled)
        precondition(!shortcut.update(key: 9, modifiers: 0, label: "V"))
        precondition(shortcut.label == "⌥⌘V")
        precondition(shortcut.update(key: 40, modifiers: UInt32(controlKey | cmdKey), label: "⌃⌘K"))
        let restored = TransferShortcut(defaults: defaults)
        precondition(restored.label == "⌃⌘K" && !restored.enabled)
        shortcut.restoreDefault()
        precondition(shortcut.label == "⌥⌘V")
        shortcut.startRecording()
        precondition(shortcut.recording)
        shortcut.cancelRecording()
        precondition(!shortcut.recording)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutTrigger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: root, defaults: defaults,
                                   pasteboard: pasteboard, observesPasteboard: false)
        var opened = 0
        shortcut.configure(store: store) { opened += 1 }
        // Invoke later, without any SwiftUI environment object installed.
        shortcut.onTrigger?()
        precondition(opened == 1 && store.transferWindowVisible)
        store.transferWindowDidClose()
        shortcut.onTrigger?()
        precondition(opened == 2 && store.transferWindowVisible,
                     "Repeated shortcut triggers must reopen with retained dependencies")
        restored.configure(store: store) { opened += 1 }
        var event: EventRef?
        precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                 0, 0, &event) == noErr)
        var identity = EventHotKeyID(signature: 0x53435452, id: 1)
        precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
        precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        ReleaseEvent(event)
        precondition(opened == 3 && store.transferWindowVisible,
                     "The native Carbon callback must reach the retained window action without an environment lookup")
        print("PASS: shortcut defaults, modifier validation, persistence, reset and recording cancellation, retained dependencies and native hotkey event dispatch")
    }
}
