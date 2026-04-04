import Foundation

struct PepperChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date
    var screenContext: String?

    enum Role {
        case user
        case assistant
    }
}

@MainActor
final class PepperChatSession: ObservableObject {
    @Published private(set) var messages: [PepperChatMessage] = []
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published private(set) var isProcessing = false
    @Published var pendingInput: String = ""
    @Published var pendingScreenContext: String?

    private let transcriber: SpeechTranscriber
    private let ocrService: FrontmostWindowOCRService
    private var backendProvider: () -> PepperChatBackend?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        transcriber: SpeechTranscriber,
        ocrService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        backendProvider: @escaping () -> PepperChatBackend? = { nil }
    ) {
        self.transcriber = transcriber
        self.ocrService = ocrService
        self.backendProvider = backendProvider
    }

    func updateBackendProvider(_ provider: @escaping () -> PepperChatBackend?) {
        self.backendProvider = provider
    }

    private var activeProcessingCount = 0

    func processRecording(audioBuffer: [Float], includeScreenContext: Bool) async {
        guard !audioBuffer.isEmpty else {
            debugLogger?(.model, "Pepper Chat: empty audio buffer, skipping.")
            return
        }

        isTranscribing = true
        let transcription = await transcriber.transcribe(audioBuffer: audioBuffer)
        isTranscribing = false

        guard let transcription, !transcription.isEmpty else {
            debugLogger?(.model, "Pepper Chat: no transcription detected.")
            return
        }

        // Show transcription in input field briefly, then auto-send
        pendingInput = transcription

        var screenContext: String?
        if includeScreenContext {
            let ocrResult = await ocrService.captureContext(customWords: [])
            screenContext = ocrResult?.windowContents
            pendingScreenContext = screenContext
        }

        // Auto-send — clear input immediately
        pendingInput = ""
        pendingScreenContext = nil
        await sendMessage(transcription, screenContext: screenContext)
    }

    func sendTypedMessage() async {
        let text = pendingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let screenContext = pendingScreenContext
        pendingInput = ""
        pendingScreenContext = nil

        await sendMessage(text, screenContext: screenContext)
    }

    func captureScreenContext() async {
        let ocrResult = await ocrService.captureContext(customWords: [])
        pendingScreenContext = ocrResult?.windowContents
    }

    private func sendMessage(_ text: String, screenContext: String?) async {
        activeProcessingCount += 1
        isProcessing = true

        let userMessage = PepperChatMessage(role: .user, text: text, timestamp: Date(), screenContext: screenContext)
        messages.append(userMessage)

        guard let backend = backendProvider() else {
            let errorMessage = PepperChatMessage(
                role: .assistant,
                text: "Add your Zo API key in Settings > Pepper Chat.",
                timestamp: Date()
            )
            messages.append(errorMessage)
            activeProcessingCount -= 1
            if activeProcessingCount == 0 { isProcessing = false }
            return
        }

        let assistantMessage = PepperChatMessage(role: .assistant, text: "", timestamp: Date())
        messages.append(assistantMessage)
        let messageID = assistantMessage.id

        do {
            try await backend.send(prompt: text, screenContext: screenContext) { [weak self] chunk in
                guard let self else { return }
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].text += chunk
                }
            }
            debugLogger?(.model, "Pepper Chat: response complete.")
        } catch {
            if let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].text.isEmpty {
                messages[index].text = "Error: \(error.localizedDescription)"
            }
            debugLogger?(.model, "Pepper Chat: backend error: \(error.localizedDescription)")
        }

        activeProcessingCount -= 1
        if activeProcessingCount == 0 { isProcessing = false }
    }

    func clearHistory() {
        messages.removeAll()
    }
}
