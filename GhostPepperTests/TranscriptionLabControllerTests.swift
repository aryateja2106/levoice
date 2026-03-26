import XCTest
@testable import GhostPepper

@MainActor
final class TranscriptionLabControllerTests: XCTestCase {
    func testReloadEntriesSortsEntriesButStartsInBrowserMode() {
        let olderEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 10),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        let newerEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 20),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)"
        )

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [olderEntry, newerEntry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in
                XCTFail("should not rerun during reload")
                return ""
            },
            runCleanup: { _, _, _, _, _ in
                XCTFail("should not rerun during reload")
                return TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()

        XCTAssertEqual(controller.entries.map { $0.id }, [newerEntry.id, olderEntry.id])
        XCTAssertNil(controller.selectedEntryID)
        XCTAssertEqual(controller.selectedSpeechModelID, SpeechModelCatalog.defaultModelID)
        XCTAssertEqual(controller.selectedCleanupModelKind, LocalCleanupModelKind.full)
    }

    func testStageRerunsUpdateExperimentOutputs() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        var executedCleanupPrompt: String?
        var executedSpeechModelID: String?
        var executedCleanupModelKind: LocalCleanupModelKind?
        var executedCleanupIncludesWindowContext: Bool?
        var cleanupInputText: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: {
                [
                    entry.id: TranscriptionLabStageTimings(
                        transcriptionDuration: 0.42,
                        cleanupDuration: 0.91
                    )
                ]
            },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { rerunEntry, speechModelID in
                XCTAssertEqual(rerunEntry.id, entry.id)
                executedSpeechModelID = speechModelID
                try? await Task.sleep(nanoseconds: 20_000_000)
                return "raw rerun"
            },
            runCleanup: { rerunEntry, rawText, cleanupModelKind, prompt, includeWindowContext in
                XCTAssertEqual(rerunEntry.id, entry.id)
                cleanupInputText = rawText
                executedCleanupPrompt = prompt
                executedCleanupModelKind = cleanupModelKind
                executedCleanupIncludesWindowContext = includeWindowContext
                try? await Task.sleep(nanoseconds: 20_000_000)
                return TranscriptionLabCleanupResult(
                    correctedTranscription: "clean rerun",
                    cleanupUsedFallback: false,
                    transcript: TranscriptionLabCleanupTranscript(
                        prompt: prompt,
                        inputText: rawText,
                        rawModelOutput: "clean rerun raw"
                    )
                )
            }
        )
        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.selectedCleanupModelKind = .full
        controller.usesCapturedOCR = false

        await controller.rerunTranscription()
        await controller.rerunCleanup(prompt: "custom prompt")

        XCTAssertEqual(executedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(cleanupInputText, "raw rerun")
        XCTAssertEqual(executedCleanupPrompt, "custom prompt")
        XCTAssertEqual(executedCleanupModelKind, .full)
        XCTAssertEqual(executedCleanupIncludesWindowContext, false)
        XCTAssertEqual(controller.experimentRawTranscription, "raw rerun")
        XCTAssertEqual(controller.experimentCorrectedTranscription, "clean rerun")
        XCTAssertEqual(controller.originalTranscriptionDuration, 0.42)
        XCTAssertEqual(controller.originalCleanupDuration, 0.91)
        XCTAssertNotNil(controller.experimentTranscriptionDuration)
        XCTAssertNotNil(controller.experimentCleanupDuration)
        XCTAssertEqual(controller.latestCleanupTranscript?.prompt, "custom prompt")
        XCTAssertEqual(controller.latestCleanupTranscript?.inputText, "raw rerun")
        XCTAssertEqual(controller.latestCleanupTranscript?.rawModelOutput, "clean rerun raw")
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.runningStage)
    }

    func testDisplayedExperimentOutputsDefaultToOriginalOutputs() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.displayedExperimentRawTranscription, "raw")
        XCTAssertEqual(controller.displayedExperimentCorrectedTranscription, "corrected")
    }

    func testTranscriptionLabTextDiffMarksInsertedAndRemovedRuns() {
        let diff = TranscriptionLabTextDiff.segments(
            from: "the quick brown fox",
            to: "the slower brown fox"
        )

        XCTAssertEqual(
            diff,
            [
                .init(kind: .unchanged, text: "the"),
                .init(kind: .removed, text: "quick"),
                .init(kind: .inserted, text: "slower"),
                .init(kind: .unchanged, text: "brown fox")
            ]
        )
    }

    func testTranscriptionLabTextDiffRefinesSingleCharacterChangeWithinToken() {
        let diff = TranscriptionLabTextDiff.segments(
            from: "delegation,",
            to: "delegation."
        )

        XCTAssertEqual(
            diff,
            [
                .init(kind: .unchanged, text: "delegation"),
                .init(kind: .removed, text: ","),
                .init(kind: .inserted, text: ".")
            ]
        )
    }

    private func makeEntry(
        createdAt: Date,
        speechModelID: String,
        cleanupModelName: String
    ) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: createdAt,
            audioFileName: "sample.bin",
            audioDuration: 1.25,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: speechModelID,
            cleanupModelName: cleanupModelName,
            cleanupUsedFallback: false
        )
    }
}
