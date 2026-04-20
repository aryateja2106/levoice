import Foundation

/// Manages the system-wide Caps Lock → F18 remap that lets `HyperkeyManager`
/// receive clean keyDown / keyUp event pairs instead of the stateful single
/// `flagsChanged` event Caps Lock normally emits.
///
/// ## Why this exists
///
/// macOS treats Caps Lock as a **toggle** key, not a momentary key. A press
/// emits exactly one `flagsChanged` event with `maskAlphaShift` toggling state.
/// There is no separate keyUp. Swallowing that event in a CGEvent tap breaks
/// the on-screen Caps Lock indicator because macOS no longer updates its
/// internal caps-lock state to match the physical key.
///
/// `hidutil` remaps Caps Lock → F18 at the **HID layer** (below CGEvent, below
/// NSEvent). After the remap, pressing the physical Caps Lock key produces a
/// normal `keyDown`/`keyUp` pair for keyCode 79 (F18), which gives the state
/// machine real edges to work with.
///
/// ## What this affects
///
/// - **All connected keyboards.** `hidutil` is system-wide. Any keyboard
///   attached now or in the future gets Caps → F18. This is fine because the
///   trigger behavior (hyper-on-hold, configurable quick-tap) is consistent
///   across keyboards.
/// - **Caps Lock as a toggle is MEDIATED by us while the remap is active.**
///   We preserve it for the user by synthesising a real Caps Lock event on
///   quick tap when `quickPressKeyCode == 57`. The indicator still lights,
///   Shift still works for capitalisation, etc. This matches how Knollsoft
///   Hyperkey behaves.
/// - **Synthesised events bypass `hidutil`.** Posting `virtualKey: 57` via
///   `CGEvent.post` still produces a real Caps Lock event because `hidutil`
///   only rewrites physical HID input — it doesn't touch CGEvent streams.
///
/// ## Cleanup guarantees
///
/// - Cleared on `HyperkeyManager.stop()`.
/// - Cleared on `AppState.prepareForTermination()` (normal quit).
/// - Cleared at launch if Hyperkey is disabled (handles SIGKILL / power loss
///   cases where the previous session didn't get a chance to clean up).
enum HyperkeyHIDRemapper {

    /// HID usage page+key for Caps Lock: page 0x07 (keyboard) usage 0x39.
    static let capsLockHIDUsage: UInt64 = 0x700000039
    /// HID usage page+key for F18: page 0x07 (keyboard) usage 0x6D.
    static let f18HIDUsage: UInt64 = 0x70000006D
    /// Virtual keyCode that an F18 press arrives as after the HID remap.
    /// (kVK_F18 from HIToolbox/Events.h.)
    static let f18VirtualKeyCode: UInt16 = 79

    /// Apply the Caps Lock → F18 remap. Idempotent. Returns true on success.
    @discardableResult
    static func enable() -> Bool {
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockHIDUsage),"HIDKeyboardModifierMappingDst":\(f18HIDUsage)}]}
        """
        return runHidutil(["property", "--set", json])
    }

    /// Clear all user key mappings, restoring Caps Lock to its default
    /// behaviour. Always safe to call.
    @discardableResult
    static func disable() -> Bool {
        return runHidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
    }

    @discardableResult
    private static func runHidutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
