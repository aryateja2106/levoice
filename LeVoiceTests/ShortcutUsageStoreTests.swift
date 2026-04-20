import XCTest
@testable import LeVoice

final class ShortcutUsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ShortcutUsageStoreTests"

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testRecordIncrementsCount() {
        let store = ShortcutUsageStore(defaults: defaults)
        store.record(bundleId: "com.apple.Notes", menuPath: ["File", "New Note"])
        store.record(bundleId: "com.apple.Notes", menuPath: ["File", "New Note"])
        let recent = store.recent(
            bundleId: "com.apple.Notes",
            entries: [Self.entry(title: "New Note", path: ["File", "New Note"])],
            limit: 5
        )
        XCTAssertEqual(recent.count, 1)
    }

    func testRecentOrdersByLastUsed() throws {
        let store = ShortcutUsageStore(defaults: defaults)
        let a = Self.entry(title: "A", path: ["File", "A"])
        let b = Self.entry(title: "B", path: ["File", "B"])
        let c = Self.entry(title: "C", path: ["File", "C"])
        store.record(bundleId: "app", menuPath: a.menuPath)
        store.record(bundleId: "app", menuPath: b.menuPath)
        store.record(bundleId: "app", menuPath: c.menuPath)

        let recent = store.recent(bundleId: "app", entries: [a, b, c], limit: 3)
        XCTAssertEqual(recent.map(\.title), ["C", "B", "A"])
    }

    func testRecentSkipsEntriesNotInCurrentGraph() {
        let store = ShortcutUsageStore(defaults: defaults)
        store.record(bundleId: "app", menuPath: ["Old", "Gone"])
        store.record(bundleId: "app", menuPath: ["New", "Still Here"])

        let still = Self.entry(title: "Still Here", path: ["New", "Still Here"])
        let recent = store.recent(bundleId: "app", entries: [still], limit: 5)
        XCTAssertEqual(recent.map(\.title), ["Still Here"])
    }

    func testRecentRespectsLimit() {
        let store = ShortcutUsageStore(defaults: defaults)
        for i in 0..<10 {
            store.record(bundleId: "app", menuPath: ["F", "\(i)"])
        }
        let entries = (0..<10).map { Self.entry(title: "\($0)", path: ["F", "\($0)"]) }
        let recent = store.recent(bundleId: "app", entries: entries, limit: 3)
        XCTAssertEqual(recent.count, 3)
    }

    func testEmptyBundleIdIsIgnored() {
        let store = ShortcutUsageStore(defaults: defaults)
        store.record(bundleId: "", menuPath: ["File", "Save"])
        let recent = store.recent(bundleId: "",
                                  entries: [Self.entry(title: "Save", path: ["File", "Save"])],
                                  limit: 5)
        XCTAssertTrue(recent.isEmpty)
    }

    func testRankedFallsBackToTitleWhenNoUsage() {
        let store = ShortcutUsageStore(defaults: defaults)
        let a = Self.entry(title: "Apple", path: ["X", "Apple"])
        let b = Self.entry(title: "Banana", path: ["X", "Banana"])
        let ranked = store.ranked(bundleId: "fresh-app", entries: [b, a])
        XCTAssertEqual(ranked.map(\.title), ["Apple", "Banana"])
    }

    func testRankedPutsFrequentFirst() {
        let store = ShortcutUsageStore(defaults: defaults)
        let a = Self.entry(title: "Apple", path: ["X", "Apple"])
        let b = Self.entry(title: "Banana", path: ["X", "Banana"])
        // Apple used 5x, Banana 1x.
        for _ in 0..<5 { store.record(bundleId: "app", menuPath: a.menuPath) }
        store.record(bundleId: "app", menuPath: b.menuPath)
        let ranked = store.ranked(bundleId: "app", entries: [b, a])
        XCTAssertEqual(ranked.first?.title, "Apple")
    }

    func testCountsPersistAcrossStoreInstances() {
        let first = ShortcutUsageStore(defaults: defaults)
        first.record(bundleId: "app", menuPath: ["F", "Save"])
        first.record(bundleId: "app", menuPath: ["F", "Save"])

        let second = ShortcutUsageStore(defaults: defaults)
        let entry = Self.entry(title: "Save", path: ["F", "Save"])
        let recent = second.recent(bundleId: "app", entries: [entry], limit: 5)
        XCTAssertEqual(recent.map(\.title), ["Save"])
    }

    // MARK: - Helpers

    private static func entry(title: String, path: [String]) -> ShortcutEntry {
        ShortcutEntry(
            id: UUID(),
            menuPath: path,
            title: title,
            keyCharacter: "a",
            virtualKeyCode: nil,
            modifiers: [.command],
            enabled: true,
            displayString: "⌘A"
        )
    }
}
