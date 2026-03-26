import XCTest
@testable import GhostPepper

@MainActor
final class TextCleanupManagerTests: XCTestCase {
    actor ProbeConcurrencyHarness {
        private var isRunning = false

        func run(text: String) async -> CleanupModelProbeRawResult {
            if isRunning {
                return CleanupModelProbeRawResult(
                    modelKind: .fast,
                    modelDisplayName: TextCleanupManager.fastModel.displayName,
                    rawOutput: "",
                    elapsed: 0
                )
            }

            isRunning = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            isRunning = false

            return CleanupModelProbeRawResult(
                modelKind: .fast,
                modelDisplayName: TextCleanupManager.fastModel.displayName,
                rawOutput: text,
                elapsed: 0.05
            )
        }
    }

    func testCleanupModelDescriptorsUseQwenThreeFamilyModels() {
        XCTAssertEqual(
            TextCleanupManager.fastModel.displayName,
            "Qwen 3 1.7B (fast cleanup)"
        )
        XCTAssertEqual(
            TextCleanupManager.fastModel.fileName,
            "Qwen3-1.7B.Q4_K_M.gguf"
        )
        XCTAssertEqual(
            TextCleanupManager.fullModel.displayName,
            "Qwen 3.5 4B (full cleanup)"
        )
        XCTAssertEqual(
            TextCleanupManager.fullModel.fileName,
            "Qwen3.5-4B-Q4_K_M.gguf"
        )
    }

    func testCleanupModelPoliciesListOnlyConcreteModels() {
        XCTAssertEqual(LocalCleanupModelPolicy.allCases, [.fastOnly, .fullOnly])
    }

    func testDefaultPolicyUsesFullModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let manager = TextCleanupManager(
            defaults: defaults,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .full
        )
    }

    func testFastOnlyPolicyAlwaysReturnsFastWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 40, isQuestion: true),
            .fast
        )
    }

    func testFullOnlyPolicyAlwaysReturnsFullWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .full
        )
    }

    func testQuestionSelectionStillFlowsThroughManagerPolicy() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 3, isQuestion: true),
            .fast
        )
    }

    func testFullOnlyPolicyTreatsFullModelAsUsableWhenAvailable() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: false,
            fullModelAvailabilityOverride: true
        )

        XCTAssertTrue(manager.hasUsableModelForCurrentPolicy)
    }

    func testFullOnlyPolicyRequiresFullModelToBeUsable() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: false
        )

        XCTAssertFalse(manager.hasUsableModelForCurrentPolicy)
    }

    func testCleanupSuppressesThinkingForProductionCleanupCalls() async throws {
        var capturedThinkingMode: CleanupModelProbeThinkingMode?
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true,
            probeExecutionOverride: { _, _, _, thinkingMode in
                capturedThinkingMode = thinkingMode
                return CleanupModelProbeRawResult(
                    modelKind: .full,
                    modelDisplayName: TextCleanupManager.fullModel.displayName,
                    rawOutput: "That worked really well.",
                    elapsed: 0.01
                )
            }
        )

        let result = try await manager.clean(text: "That worked really well.", prompt: "unused prompt")

        XCTAssertEqual(result, "That worked really well.")
        XCTAssertEqual(capturedThinkingMode, .suppressed)
    }

    func testShutdownBackendCallsOverride() {
        var shutdownCount = 0
        let manager = TextCleanupManager(
            backendShutdownOverride: {
                shutdownCount += 1
            }
        )

        manager.shutdownBackend()
        manager.shutdownBackend()

        XCTAssertEqual(shutdownCount, 2)
    }

    func testCleanupSerializesOverlappingRequests() async throws {
        let harness = ProbeConcurrencyHarness()
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true,
            probeExecutionOverride: { text, _, _, _ in
                await harness.run(text: text)
            }
        )

        async let first = manager.clean(text: "first", prompt: "unused")
        async let second = manager.clean(text: "second", prompt: "unused")

        let results = try await [first, second]

        XCTAssertEqual(results, ["first", "second"])
    }

    func testCleanupThrowsUnavailableWhenSelectedModelIsMissing() async {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: false,
            fullModelAvailabilityOverride: true
        )

        await XCTAssertThrowsErrorAsync(try await manager.clean(text: "hello", prompt: "unused")) { error in
            XCTAssertEqual(error as? CleanupBackendError, .unavailable)
        }
    }

    func testCleanupThrowsUnusableOutputWhenModelReturnsPlaceholder() async {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true,
            probeExecutionOverride: { _, _, _, _ in
                CleanupModelProbeRawResult(
                    modelKind: .fast,
                    modelDisplayName: TextCleanupManager.fastModel.displayName,
                    rawOutput: "...",
                    elapsed: 0.01
                )
            }
        )

        await XCTAssertThrowsErrorAsync(try await manager.clean(text: "hello", prompt: "unused")) { error in
            XCTAssertEqual(
                error as? CleanupBackendError,
                .unusableOutput(rawOutput: "...")
            )
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected error to be thrown." : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
