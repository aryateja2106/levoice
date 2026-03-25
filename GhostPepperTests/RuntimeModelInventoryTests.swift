import XCTest
@testable import GhostPepper

@MainActor
final class RuntimeModelInventoryTests: XCTestCase {
    func testRuntimeModelRowsIncludeAllSpeechAndCleanupModels() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .loading,
            cachedSpeechModelNames: ["openai_whisper-tiny.en"],
            cleanupState: .downloading(kind: .full, progress: 0.4),
            loadedCleanupKinds: [.fast]
        )

        XCTAssertEqual(rows.map(\.name), [
            "Whisper tiny.en (speed)",
            "Whisper small.en (accuracy)",
            "Whisper small (multilingual)",
            TextCleanupManager.fastModel.displayName,
            TextCleanupManager.fullModel.displayName,
        ])

        XCTAssertEqual(rows[0].status, .loaded)
        XCTAssertFalse(rows[0].isSelected)

        XCTAssertEqual(rows[1].status, .downloading(progress: nil))
        XCTAssertTrue(rows[1].isSelected)

        XCTAssertEqual(rows[2].status, .notLoaded)
        XCTAssertFalse(rows[2].isSelected)

        XCTAssertEqual(rows[3].status, .loaded)
        XCTAssertFalse(rows[3].isSelected)

        XCTAssertEqual(rows[4].status, .downloading(progress: 0.4))
        XCTAssertFalse(rows[4].isSelected)
    }

    func testRuntimeModelRowsSeparateSelectedSpeechModelFromActiveDownload() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-tiny.en",
            speechModelState: .loading,
            cachedSpeechModelNames: [],
            cleanupState: .idle,
            loadedCleanupKinds: []
        )

        XCTAssertEqual(rows[0].status, .downloading(progress: nil))
        XCTAssertFalse(rows[0].isSelected)

        XCTAssertEqual(rows[1].status, .notLoaded)
        XCTAssertTrue(rows[1].isSelected)
    }
}
