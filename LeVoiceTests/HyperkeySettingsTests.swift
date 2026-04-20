import XCTest
@testable import LeVoice

final class HyperkeySettingsTests: XCTestCase {
    func testDefaultValuesMatchSpec() {
        let defaults = HyperkeySettings.default
        XCTAssertFalse(defaults.enabled)
        XCTAssertEqual(defaults.remappedKeyCode, 57)   // Caps Lock
        // Quick-tap passes through to Caps Lock (matches Knollsoft Hyperkey default).
        // Synthesised via CGEvent so the OS still toggles caps state / LED.
        XCTAssertEqual(defaults.quickPressKeyCode, 57)
        XCTAssertTrue(defaults.includeShift)
    }

    func testQuickPressThresholdIsUnder150ms() {
        // Users expect near-instant feedback on a tap. 150 ms is a common ceiling
        // before the OS treats it as "held". Guardrail against future regressions.
        XCTAssertLessThanOrEqual(HyperkeySettings.quickPressThresholdSeconds, 0.15)
        XCTAssertGreaterThan(HyperkeySettings.quickPressThresholdSeconds, 0)
    }

    func testJSONRoundTripViaUserDefaults() throws {
        let suiteName = "HyperkeySettingsTests.roundTrip"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HyperkeySettingsStore(defaults: defaults)
        let saved = HyperkeySettings(
            enabled: true,
            remappedKeyCode: 105, // F13
            quickPressKeyCode: 53,
            includeShift: false
        )
        store.save(saved)

        let loaded = store.load()
        XCTAssertEqual(loaded, saved)
    }

    func testMissingDataLoadsDefault() {
        let suiteName = "HyperkeySettingsTests.missing"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HyperkeySettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), HyperkeySettings.default)
    }

    func testCorruptDataLoadsDefault() throws {
        let suiteName = "HyperkeySettingsTests.corrupt"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([0xFF, 0xFE, 0xFD]), forKey: HyperkeySettingsStore.defaultsKey)
        let store = HyperkeySettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), HyperkeySettings.default)
    }

    func testSentinelIsStableAcrossBuilds() {
        // The sentinel is also checked in HotkeyMonitor's C callback. Changing it
        // would silently disable the recursion guard. If you need to change it,
        // update HotkeyMonitor.swift too.
        XCTAssertEqual(HyperkeyManager.eventSourceUserDataSentinel, 0x1EC0DE)
    }
}
