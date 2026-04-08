import Foundation

/// A past meeting found on disk.
struct MeetingHistoryEntry: Identifiable, Hashable {
    let id: URL
    let name: String
    let dateFolder: String
    let fileURL: URL

    var displayDate: String { dateFolder }
}

/// Scans the meeting save directory for past transcript markdown files.
enum MeetingHistory {
    /// Returns all meeting entries grouped by date folder, newest first.
    static func loadEntries(from baseDirectory: URL) -> [(date: String, entries: [MeetingHistoryEntry])] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var groups: [(date: String, entries: [MeetingHistoryEntry])] = []

        let sortedFolders = dateFolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest date first

        for folder in sortedFolders {
            let dateFolder = folder.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mdFiles = files
                .filter { $0.pathExtension == "md" }
                .sorted {
                    let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return d1 > d2 // newest first
                }

            let entries = mdFiles.map { file in
                let name = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                return MeetingHistoryEntry(
                    id: file,
                    name: name,
                    dateFolder: dateFolder,
                    fileURL: file
                )
            }

            if !entries.isEmpty {
                groups.append((date: dateFolder, entries: entries))
            }
        }

        return groups
    }
}
