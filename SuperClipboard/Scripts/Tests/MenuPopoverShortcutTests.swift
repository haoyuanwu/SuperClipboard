import AppKit
import Carbon

@main
struct MenuPopoverShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "SuperClipboard.PopoverShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "popoverShortcut.enabled")
        let shortcut = MenuPopoverShortcut(defaults: defaults)
        precondition(shortcut.label == "⌥⌘C" && !shortcut.enabled)
        precondition(!shortcut.update(key: 8, modifiers: 0, label: "C"))
        precondition(shortcut.label == "⌥⌘C")
        precondition(shortcut.update(key: 40, modifiers: UInt32(controlKey | cmdKey), label: "⌃⌘K"))
        let restored = MenuPopoverShortcut(defaults: defaults)
        precondition(restored.label == "⌃⌘K" && !restored.enabled)
        shortcut.restoreDefault()
        precondition(shortcut.label == "⌥⌘C")
        shortcut.startRecording()
        precondition(shortcut.recording)
        shortcut.cancelRecording()
        precondition(!shortcut.recording)
        var opened = 0
        restored.onTrigger = { opened += 1 }
        func dispatch(_ signature: OSType) -> OSStatus {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
            var identity = EventHotKeyID(signature: signature, id: 1)
            precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
            let status = SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
            return status
        }
        precondition(dispatch(0x53435050) == noErr && opened == 1)
        restored.startRecording()
        precondition(dispatch(0x53435050) == noErr && opened == 1, "Recording must not open a popover")
        restored.cancelRecording()
        precondition(dispatch(0x53435050) == noErr && opened == 2)
        _ = dispatch(0x53435452)
        precondition(opened == 2, "Transfer hotkeys must not dispatch the popover action")
        print("PASS: popover shortcut defaults, validation, persistence, restore, recording cancellation and native Carbon dispatch isolation")
    }
}
