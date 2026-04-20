import XCTest
@testable import LeVoice

/// Tests for the pure-data parts of the shortcut palette: modifier bitmask
/// decoding, display glyph rendering, and JSON round-trips. The AX walk itself
/// needs a running app to introspect, so it's covered by integration tests.
final class ShortcutEntryTests: XCTestCase {

    // MARK: - AX modifier bitmask decoding

    func testBitmaskZeroMeansCommandOnly() {
        // An AX bitmask of 0 means "⌘ only" per Apple's constants.
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0)
        XCTAssertEqual(mods, .command)
    }

    func testBitmaskBit0IsShiftPlusCommand() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x01)
        XCTAssertEqual(mods, [.command, .shift])
    }

    func testBitmaskBit1IsOptionPlusCommand() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x02)
        XCTAssertEqual(mods, [.command, .option])
    }

    func testBitmaskBit2IsControlPlusCommand() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x04)
        XCTAssertEqual(mods, [.command, .control])
    }

    func testBitmaskBit3MeansNoCommand() {
        // Bit 3 (0x08) = "no command" — unusual, used for modifier-free
        // shortcuts like some Function-key bindings.
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x08)
        XCTAssertEqual(mods, [])
    }

    func testBitmaskCombinedShiftOptionCommand() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x03)
        XCTAssertEqual(mods, [.command, .shift, .option])
    }

    func testBitmaskFnWithCommand() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x10)
        XCTAssertEqual(mods, [.command, .function])
    }

    func testBitmaskNoCmdWithShift() {
        let mods = ShortcutEntry.Modifiers.decode(axBitmask: 0x09)
        XCTAssertEqual(mods, [.shift])
    }

    // MARK: - Display glyph rendering

    func testDisplayGlyphsForCommandOnly() {
        XCTAssertEqual((ShortcutEntry.Modifiers.command).displayGlyphs, "⌘")
    }

    func testDisplayGlyphOrderIsControlOptionShiftCommand() {
        // Apple's glyph order convention: ⌃⌥⇧⌘
        let mods: ShortcutEntry.Modifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(mods.displayGlyphs, "⌃⌥⇧⌘")
    }

    func testDisplayGlyphEmptyWhenNoModifiers() {
        let mods: ShortcutEntry.Modifiers = []
        XCTAssertEqual(mods.displayGlyphs, "")
    }

    // MARK: - JSON round-trip (agent export path)

    func testShortcutEntryEncodesToJSONAndBack() throws {
        let entry = ShortcutEntry(
            id: UUID(),
            menuPath: ["File", "Save"],
            title: "Save",
            keyCharacter: "s",
            virtualKeyCode: nil,
            modifiers: [.command],
            enabled: true,
            displayString: "⌘S"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ShortcutEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testAppShortcutGraphRoundTrips() throws {
        let entry = ShortcutEntry(
            id: UUID(),
            menuPath: ["Edit", "Find"],
            title: "Find",
            keyCharacter: "f",
            virtualKeyCode: nil,
            modifiers: [.command],
            enabled: true,
            displayString: "⌘F"
        )
        let graph = AppShortcutGraph(
            bundleId: "com.apple.Safari",
            appName: "Safari",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            entries: [entry]
        )
        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(AppShortcutGraph.self, from: data)
        XCTAssertEqual(graph, decoded)
    }

    // MARK: - Modifier OptionSet contains

    func testModifierOptionSetContainsSingles() {
        let mods: ShortcutEntry.Modifiers = [.command, .shift]
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertFalse(mods.contains(.option))
        XCTAssertFalse(mods.contains(.control))
    }
}
