import XCTest
@testable import LeVoice

final class HyperkeyManagerTests: XCTestCase {

    /// Regression test for the "Shift-during-hold cancels quick-tap" bug.
    ///
    /// When Caps Lock is held and the user presses only Shift (preparing a
    /// Hyper+Shift+key but releasing before firing), the manager must NOT treat
    /// Shift as "a key was pressed during the hold" — otherwise quick-tap gets
    /// silently suppressed and Caps Lock feels broken.
    ///
    /// Covers HyperkeyManager.swift:198 where `!isModifierKeyCode(eventCode)`
    /// gates the `keyPressedWhileHeld` latch.
    func testModifierKeyCodesAreExcludedFromHeldKeyLatch() {
        let manager = HyperkeyManager()

        // All recognised modifier keyCodes — must all return true.
        let modifierKeyCodes: [UInt16] = [
            54,  // Right Command
            55,  // Left Command
            56,  // Left Shift
            57,  // Caps Lock (already swallowed at trigger, belt-and-braces)
            58,  // Left Option
            59,  // Left Control
            60,  // Right Shift
            61,  // Right Option
            62,  // Right Control
            63,  // Fn / Globe
        ]

        for code in modifierKeyCodes {
            XCTAssertTrue(
                manager.isModifierKeyCode(code),
                "keyCode \(code) should be classified as a modifier and NOT cancel the quick-tap path."
            )
        }
    }

    /// Non-modifier keys must trip `keyPressedWhileHeld` so that a legitimate
    /// Hyper+Letter chord cancels quick-tap synthesis as intended.
    func testNonModifierKeyCodesAreNotTreatedAsModifiers() {
        let manager = HyperkeyManager()

        // A selection of letter, digit, and punctuation keyCodes that should
        // all be treated as "real" keys during a Hyperkey hold.
        let nonModifierKeyCodes: [UInt16] = [
            0,   // A
            4,   // H
            12,  // Q
            36,  // Return
            48,  // Tab
            49,  // Space
            51,  // Delete
            53,  // Escape
        ]

        for code in nonModifierKeyCodes {
            XCTAssertFalse(
                manager.isModifierKeyCode(code),
                "keyCode \(code) is not a modifier and must be counted as a hyper-chord key."
            )
        }
    }

    /// Manager must be safe to instantiate without Accessibility / Input
    /// Monitoring permissions — the tap is installed lazily in `start()`.
    func testInitializationDoesNotRequireSystemPermissions() {
        _ = HyperkeyManager()
        _ = HyperkeyManager(settings: .default)
    }
}
