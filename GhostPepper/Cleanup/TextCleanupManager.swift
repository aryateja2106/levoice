import Foundation
import LLM

enum CleanupModelState: Equatable {
    case idle
    case downloading(progress: Double)
    case loadingModel
    case ready
    case error
}

@MainActor
final class TextCleanupManager: ObservableObject {
    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?

    private(set) var llm: LLM?

    private static let modelFileName = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
    private static let modelURL = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    private static let modelSizeMB = "~1 GB"

    var isReady: Bool { state == .ready }

    var statusText: String {
        switch state {
        case .idle:
            return ""
        case .downloading(let progress):
            let pct = Int(progress * 100)
            return "Downloading cleanup model (\(pct)%)..."
        case .loadingModel:
            return "Loading cleanup model into memory..."
        case .ready:
            return ""
        case .error:
            return errorMessage ?? "Cleanup model error"
        }
    }

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    private var modelPath: URL {
        modelsDirectory.appendingPathComponent(Self.modelFileName)
    }

    func loadModel() async {
        guard state == .idle || state == .error else { return }

        errorMessage = nil

        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: modelPath.path) {
            state = .downloading(progress: 0)
            do {
                try await downloadModel()
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                return
            }
        }

        state = .loadingModel

        // Load on background thread to avoid blocking UI
        let path = modelPath
        let model = await Task.detached { () -> LLM? in
            return LLM(from: path, template: Template.chatML(TextCleaner.defaultPrompt), maxTokenCount: 4096)
        }.value

        guard let model = model else {
            self.errorMessage = "Failed to load cleanup model"
            self.state = .error
            return
        }

        model.temp = 0.1
        model.update = { (_: String?) in }
        model.postprocess = { (_: String) in }

        self.llm = model
        self.state = .ready
    }

    func unloadModel() {
        llm = nil
        state = .idle
        errorMessage = nil
    }

    private func downloadModel() async throws {
        guard let url = URL(string: Self.modelURL) else {
            throw URLError(.badURL)
        }

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        try FileManager.default.moveItem(at: tempURL, to: modelPath)
    }
}

// MARK: - Download Progress

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call
    }
}
