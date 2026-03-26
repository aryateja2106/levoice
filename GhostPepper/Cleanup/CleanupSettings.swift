import Foundation

enum CleanupBackendOption: String, CaseIterable, Identifiable {
    case localModels

    var id: String { rawValue }

    var title: String {
        "Local Models"
    }
}

enum LocalCleanupModelPolicy: String, CaseIterable, Identifiable {
    case fastOnly
    case fullOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastOnly:
            return "Qwen 3 1.7B (fast cleanup)"
        case .fullOnly:
            return "Qwen 3.5 4B (full cleanup)"
        }
    }
}
