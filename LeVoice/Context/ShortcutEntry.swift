import Foundation

/// One keyboard shortcut extracted from a running app's menu bar.
///
/// The `axElementID` is opaque — it's the identity marker the introspecter uses
/// to press the menu item later via `AXUIElementPerformAction`. It's not part of
/// the Codable export because `AXUIElement` can't round-trip across processes.
struct ShortcutEntry: Codable, Equatable, Identifiable {
    /// Stable per-capture id. Regenerated each time an app's menu is walked.
    let id: UUID
    /// The hierarchical menu path: ["File", "Export", "Save as PDF…"].
    let menuPath: [String]
    /// Leaf menu item title (last element of menuPath, repeated for convenience).
    let title: String
    /// Single printable character for the shortcut, e.g. "s" for ⌘S.
    /// `nil` when the shortcut is a virtual key (F1-F12, arrows, Escape…).
    let keyCharacter: String?
    /// Virtual key code for non-printable shortcuts. Mutually exclusive with `keyCharacter`.
    let virtualKeyCode: Int?
    /// Parsed modifiers from the raw AX bitmask.
    let modifiers: Modifiers
    /// Whether the menu item is currently enabled. Disabled items still export
    /// but agents should skip them.
    let enabled: Bool
    /// Pre-rendered display string — "⌘⇧S", "⌥F12", "fn↑". Useful for UI.
    let displayString: String

    struct Modifiers: OptionSet, Codable, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift   = Modifiers(rawValue: 1 << 1)
        static let option  = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
        /// Rare but real — used by items like the dictation shortcut.
        static let function = Modifiers(rawValue: 1 << 4)
    }
}

/// A full snapshot of one running app's menu shortcuts at a point in time.
///
/// Designed for agent consumption — encode to JSON, ship to an LLM, let the
/// model pick a `menuPath`, then the Mac side re-resolves the path to a live
/// `AXUIElement` and presses it.
struct AppShortcutGraph: Codable, Equatable {
    let bundleId: String
    let appName: String
    let capturedAt: Date
    let entries: [ShortcutEntry]
}

// MARK: - AX modifier bitmask decoding

extension ShortcutEntry.Modifiers {
    /// Decodes the raw `AXMenuItemCmdModifiers` bitmask emitted by Accessibility.
    ///
    /// Apple's constants (from `AXAttributeConstants.h`):
    /// - Bit 0 (0x01): Shift
    /// - Bit 1 (0x02): Option
    /// - Bit 2 (0x04): Control
    /// - Bit 3 (0x08): **No Command** — when set, ⌘ is NOT implied
    /// - Bit 4 (0x10): Fn
    ///
    /// A bitmask of 0 means "⌘ only". A bitmask of 8 means "no ⌘ modifier".
    static func decode(axBitmask: Int) -> ShortcutEntry.Modifiers {
        var result: ShortcutEntry.Modifiers = []
        if axBitmask & 0x01 != 0 { result.insert(.shift) }
        if axBitmask & 0x02 != 0 { result.insert(.option) }
        if axBitmask & 0x04 != 0 { result.insert(.control) }
        if axBitmask & 0x10 != 0 { result.insert(.function) }
        // Command is implicit unless the "no command" bit is set.
        if axBitmask & 0x08 == 0 { result.insert(.command) }
        return result
    }

    /// Renders the modifier set as its conventional glyph string.
    /// Order follows Apple's convention: ⌃⌥⇧⌘ (control, option, shift, command).
    var displayGlyphs: String {
        var out = ""
        if contains(.function) { out.append("fn") }
        if contains(.control)  { out.append("⌃") }
        if contains(.option)   { out.append("⌥") }
        if contains(.shift)    { out.append("⇧") }
        if contains(.command)  { out.append("⌘") }
        return out
    }
}
