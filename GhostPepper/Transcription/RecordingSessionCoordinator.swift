import Foundation

final class RecordingSessionCoordinator {
    typealias FinalizationResult = (filteredTranscript: String?, summary: DiarizationSummary)

    private let appendAudioChunkHandler: ([Float]) -> Void
    private let finishHandler: (() async -> FinalizationResult)?
    private let finishWithSpansHandler: (([DiarizationSummary.Span]) async -> FinalizationResult)?

    private(set) var filteredTranscript: String?

    init(session: FluidAudioSpeechSession) {
        appendAudioChunkHandler = session.appendAudioChunk
        finishHandler = nil
        finishWithSpansHandler = { spans in
            let result = await session.finalize(spans: spans)
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
    }

    init(
        session: FluidAudioSpeechSession,
        processAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () -> [DiarizationSummary.Span],
        cleanup: @escaping () -> Void = {}
    ) {
        appendAudioChunkHandler = { samples in
            session.appendAudioChunk(samples)
            processAudioChunk(samples)
        }
        finishHandler = {
            let result = await session.finalize(spans: finish())
            cleanup()
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
        finishWithSpansHandler = nil
    }

    init(
        appendAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () async -> FinalizationResult
    ) {
        appendAudioChunkHandler = appendAudioChunk
        finishHandler = finish
        finishWithSpansHandler = nil
    }

    func appendAudioChunk(_ samples: [Float]) {
        appendAudioChunkHandler(samples)
    }

    func finish() async -> DiarizationSummary {
        guard let finishHandler else {
            return DiarizationSummary(
                spans: [],
                mergedKeptSpans: [],
                targetSpeakerID: nil,
                targetSpeakerDuration: 0,
                keptAudioDuration: 0,
                usedFallback: true,
                fallbackReason: .noUsableSpeakerSpans
            )
        }

        let result = await finishHandler()
        filteredTranscript = result.filteredTranscript
        return result.summary
    }

    func finish(spans: [DiarizationSummary.Span]) async -> DiarizationSummary {
        guard let finishWithSpansHandler else {
            return await finish()
        }

        let result = await finishWithSpansHandler(spans)
        filteredTranscript = result.filteredTranscript
        return result.summary
    }
}
