import AppKit
import ApplicationServices
import Foundation

/// Walks the Accessibility menu tree of a running macOS app and extracts every
/// keyboard shortcut exposed through the app's menu bar.
///
/// Uses only public Apple APIs. Requires Accessibility permission (same one
/// HotkeyMonitor already needs — no new prompts for the user).
///
/// This is the ground-truth source for shortcuts. Items not in the menu bar
/// (toolbar buttons, hidden chord sequences, third-party plugins) are not
/// visible — that's a known limitation of this approach.
struct AppMenuIntrospecter {
    /// Upper bound on submenu recursion depth. Stops runaway cycles if an app
    /// somehow produces a circular AX tree. Real apps max out around 6.
    static let maxDepth = 12

    /// Result of a menu walk — the serializable `graph` plus a side-table of
    /// live `AXUIElement` references so the caller can later press a specific
    /// menu item via `AXUIElementPerformAction`. The side-table is keyed by
    /// `ShortcutEntry.id` and is only valid for the lifetime of the target app
    /// process (AX references are opaque pointers into the target app's
    /// accessibility tree).
    struct Capture {
        let graph: AppShortcutGraph
        let elements: [UUID: AXUIElement]
        let pid: pid_t
    }

    /// Walks the frontmost app's menu bar. Returns `nil` if no app is frontmost
    /// or if Accessibility is denied.
    static func captureFrontmostApp() -> AppShortcutGraph? {
        captureFrontmostAppWithElements()?.graph
    }

    /// Walks the frontmost app and returns both the serializable graph and
    /// the live AX element handles needed for `AXUIElementPerformAction`.
    static func captureFrontmostAppWithElements() -> Capture? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return captureWithElements(app: app)
    }

    /// Walks the menu bar of a specific `NSRunningApplication`.
    static func capture(app: NSRunningApplication) -> AppShortcutGraph? {
        captureWithElements(app: app)?.graph
    }

    static func captureWithElements(app: NSRunningApplication) -> Capture? {
        let pid = app.processIdentifier
        guard pid > 0 else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        guard let menuBar = copyAttribute(axApp, kAXMenuBarAttribute) else { return nil }

        var entries: [ShortcutEntry] = []
        var elements: [UUID: AXUIElement] = [:]
        let topChildren = copyChildren(menuBar)
        for child in topChildren {
            walk(element: child, path: [], depth: 0, entries: &entries, elements: &elements)
        }

        return Capture(
            graph: AppShortcutGraph(
                bundleId: app.bundleIdentifier ?? "",
                appName: app.localizedName ?? "",
                capturedAt: Date(),
                entries: entries
            ),
            elements: elements,
            pid: pid
        )
    }

    // MARK: - Recursion

    private static func walk(
        element: AXUIElement,
        path: [String],
        depth: Int,
        entries: inout [ShortcutEntry],
        elements: inout [UUID: AXUIElement]
    ) {
        guard depth < maxDepth else { return }

        let title = copyString(element, kAXTitleAttribute) ?? ""
        let newPath = title.isEmpty ? path : path + [title]

        // If this element has children, recurse. Menu → MenuItem → (optional) submenu Menu.
        let children = copyChildren(element)
        if !children.isEmpty {
            for child in children {
                walk(element: child, path: newPath, depth: depth + 1, entries: &entries, elements: &elements)
            }
            return
        }

        // Leaf — try to extract a shortcut from it.
        if let entry = extractShortcut(element: element, path: newPath) {
            entries.append(entry)
            elements[entry.id] = element
        }
    }

    /// Presses a menu item identified by its live AX reference. Returns true on success.
    /// This is the preferred execution path — it triggers the menu item directly
    /// without having to synthesize the keystroke the user would have pressed,
    /// which sidesteps issues with hyper modifiers, dead keys, and target-app focus.
    static func press(element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: - Shortcut extraction

    private static func extractShortcut(element: AXUIElement, path: [String]) -> ShortcutEntry? {
        let title = copyString(element, kAXTitleAttribute) ?? path.last ?? ""
        guard !title.isEmpty else { return nil }

        let cmdChar = copyString(element, "AXMenuItemCmdChar" as CFString)
        let cmdVirtKey = copyInt(element, "AXMenuItemCmdVirtualKey" as CFString)
        let cmdGlyph = copyInt(element, "AXMenuItemCmdGlyph" as CFString)

        // If the item has no shortcut at all, skip it.
        let hasChar = cmdChar?.isEmpty == false
        let hasVirt = cmdVirtKey != nil && cmdVirtKey != 0
        let hasGlyph = cmdGlyph != nil && cmdGlyph != 0
        guard hasChar || hasVirt || hasGlyph else { return nil }

        let bitmask = copyInt(element, "AXMenuItemCmdModifiers" as CFString) ?? 0
        let modifiers = ShortcutEntry.Modifiers.decode(axBitmask: bitmask)
        let enabled = copyBool(element, kAXEnabledAttribute) ?? true

        let keyCharacter: String?
        let virtualKeyCode: Int?
        let keyGlyph: String
        if hasChar, let c = cmdChar {
            keyCharacter = c
            virtualKeyCode = nil
            keyGlyph = c.uppercased()
        } else if hasVirt, let v = cmdVirtKey {
            keyCharacter = nil
            virtualKeyCode = v
            keyGlyph = virtualKeyDisplayName(keyCode: v)
        } else if hasGlyph, let g = cmdGlyph {
            keyCharacter = nil
            virtualKeyCode = nil
            keyGlyph = glyphDisplayName(glyph: g)
        } else {
            return nil
        }

        let displayString = modifiers.displayGlyphs + keyGlyph

        return ShortcutEntry(
            id: UUID(),
            menuPath: path,
            title: title,
            keyCharacter: keyCharacter,
            virtualKeyCode: virtualKeyCode,
            modifiers: modifiers,
            enabled: enabled,
            displayString: displayString
        )
    }

    // MARK: - AX helpers

    private static func copyAttribute(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func copyString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyString(_ element: AXUIElement, _ attr: String) -> String? {
        copyString(element, attr as CFString)
    }

    private static func copyInt(_ element: AXUIElement, _ attr: CFString) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func copyBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    // MARK: - Display name lookups for non-printable keys

    /// Maps a small subset of the common virtual key codes (from
    /// `HIToolbox/Events.h`) to display glyphs. Unknown codes fall back to "Key\(code)".
    private static func virtualKeyDisplayName(keyCode: Int) -> String {
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36:  return "↩"   // Return
        case 48:  return "⇥"   // Tab
        case 49:  return "␣"   // Space
        case 51:  return "⌫"   // Delete (back)
        case 53:  return "⎋"   // Escape
        case 115: return "↖"   // Home
        case 119: return "↘"   // End
        case 116: return "⇞"   // Page Up
        case 121: return "⇟"   // Page Down
        case 117: return "⌦"   // Forward Delete
        default:  return "Key\(keyCode)"
        }
    }

    /// Apple's `AXMenuItemCmdGlyph` constants — matches the subset we care about.
    /// Source: `Menus.h` in Carbon / `NSAccessibilityConstants.h`.
    private static func glyphDisplayName(glyph: Int) -> String {
        switch glyph {
        case 2:   return "⇥"    // tab right
        case 3:   return "⇤"    // tab left
        case 4:   return "↵"    // enter
        case 5:   return "⇧"    // shift (rare as a key glyph)
        case 6:   return "⌃"    // control
        case 7:   return "⌥"    // option
        case 9:   return "␣"    // space
        case 11:  return "↩"    // return
        case 23:  return "⌫"    // backspace
        case 24:  return "⎋"    // clear
        case 26:  return "⎋"    // escape
        case 28:  return "⌘"    // command
        case 100: return "←"
        case 101: return "↑"
        case 102: return "→"
        case 103: return "↓"
        case 104: return "⇞"
        case 105: return "⇟"
        case 106: return "↖"
        case 107: return "↘"
        case 0x6F: return "⌦"   // forward delete
        default:  return "Gly\(glyph)"
        }
    }
}
