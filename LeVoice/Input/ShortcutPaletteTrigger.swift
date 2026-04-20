import AppKit
import Carbon.HIToolbox

/// Listens for a global hotkey and fires a callback when it's pressed.
///
/// Used exclusively for opening the shortcut palette. Kept separate from
/// `HotkeyMonitor` / `ChordEngine` because the palette trigger is a simple
/// fire-once action with no recording state — pulling it through the full
/// chord engine state machine would be overkill.
///
/// The trigger uses `NSEvent.addGlobalMonitorForEvents` (read-only, can't
/// suppress events) plus a local monitor so it works whether or not LeVoice
/// itself is focused.
///
/// Default binding: **⌃⌥⌘/** — Hyper+/. Uncovered in macOS defaults, Raycast,
/// BetterTouchTool, Xcode, Chrome, Safari, VSCode. Users can rebind later
/// via Settings.
final class ShortcutPaletteTrigger {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onTrigger: (() -> Void)?

    /// KeyCode of the trigger key. Default 44 = forward slash (/).
    var keyCode: UInt16 = UInt16(kVK_ANSI_Slash)
    /// Required modifiers. Default ⌃⌥⌘. Shift is ignored (works with or without).
    var requiredModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor  { NSEvent.removeMonitor(localMonitor);  self.localMonitor  = nil }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        // Mask down to the modifiers we actually care about. `.deviceIndependentFlagsMask`
        // ignores capsLock/function/numericPad bits that NSEvent sometimes carries.
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command]
        let have = event.modifierFlags.intersection(relevant)
        guard have == requiredModifiers.intersection(relevant) else { return }
        onTrigger?()
    }
}
