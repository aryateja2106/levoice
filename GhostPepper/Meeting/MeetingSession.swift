import Foundation

/// Orchestrates a single meeting transcription session.
/// Owns DualStreamCapture + ChunkedTranscriptionPipeline + MeetingTranscript.
@MainActor
final class MeetingSession: ObservableObject {
    @Published var isActive = false
    @Published var fileURL: URL?
    @Published var noAudioDetected = false

    let transcript: MeetingTranscript

    private let capture = DualStreamCapture()
    private var pipeline: ChunkedTranscriptionPipeline?
    private let transcriber: SpeechTranscriber
    private let saveDirectory: URL

    /// How often to auto-save the markdown file (matches chunk interval).
    private var autoSaveTimer: Timer?
    private var silenceCheckTimer: Timer?
    private var hasReceivedAudio = false

    init(
        meetingName: String,
        transcriber: SpeechTranscriber,
        saveDirectory: URL
    ) {
        self.transcript = MeetingTranscript(meetingName: meetingName)
        self.transcriber = transcriber
        self.saveDirectory = saveDirectory
    }

    /// Start dual-stream capture and chunked transcription.
    func start() async throws {
        guard !isActive else { return }

        let chunkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepper")
            .appendingPathComponent("meeting-\(transcript.sessionID.uuidString)")
            .appendingPathComponent("chunks")

        let newPipeline = ChunkedTranscriptionPipeline(
            transcriber: transcriber,
            chunkDirectory: chunkDir
        )

        newPipeline.onSegmentTranscribed = { [weak self] result in
            guard let self = self else { return }
            let speaker: SpeakerLabel = result.source == .mic ? .me : .remote(name: nil)
            let segment = TranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: result.startTime,
                endTime: result.endTime,
                text: result.text
            )
            self.transcript.appendSegment(segment)
            self.autoSave()
        }

        capture.onAudioChunk = { [weak self, weak newPipeline] chunk in
            newPipeline?.appendAudio(chunk)
            if let self = self, !self.hasReceivedAudio {
                // Check if chunk has actual audio (not silence)
                let rms = sqrt(chunk.samples.map { $0 * $0 }.reduce(0, +) / max(Float(chunk.samples.count), 1))
                if rms > 0.001 {
                    Task { @MainActor in
                        self.hasReceivedAudio = true
                        self.noAudioDetected = false
                        self.silenceCheckTimer?.invalidate()
                    }
                }
            }
        }

        pipeline = newPipeline

        try await capture.start()
        newPipeline.start()
        isActive = true

        // Initial save creates the file immediately.
        autoSave()

        // Check for silence after 10 seconds — if no audio detected, warn the user.
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isActive, !self.hasReceivedAudio else { return }
                self.noAudioDetected = true
                print("MeetingSession: no audio detected after 10 seconds")
            }
        }

        print("MeetingSession: started '\(transcript.meetingName)'")
    }

    /// Stop capture, process remaining audio, finalize transcript.
    func stop() async {
        guard isActive else { return }
        isActive = false

        pipeline?.stop()
        _ = await capture.stop()

        transcript.endDate = Date()

        // Final save with end date.
        autoSave()

        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil

        print("MeetingSession: stopped '\(transcript.meetingName)' — \(transcript.segments.count) segments, \(transcript.formattedDuration)")
    }

    /// Elapsed time since meeting started.
    var elapsed: TimeInterval {
        capture.elapsed
    }

    // MARK: - Auto-save

    private func autoSave() {
        do {
            let url = try MeetingMarkdownWriter.write(
                transcript: transcript,
                to: saveDirectory,
                existingFileURL: fileURL
            )
            if fileURL == nil {
                fileURL = url
                print("MeetingSession: transcript file created at \(url.path)")
            }
        } catch {
            print("MeetingSession: failed to save transcript — \(error.localizedDescription)")
        }
    }
}
