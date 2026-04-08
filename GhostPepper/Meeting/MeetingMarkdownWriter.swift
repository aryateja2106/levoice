import Foundation

/// Writes a MeetingTranscript to a markdown file in a date-organized directory.
struct MeetingMarkdownWriter {

    /// Writes the transcript to a markdown file, creating date subdirectories as needed.
    /// If `existingFileURL` is provided, overwrites that file instead of creating a new one.
    /// Returns the URL of the written file.
    @MainActor
    static func write(transcript: MeetingTranscript, to baseDirectory: URL, existingFileURL: URL? = nil) throws -> URL {
        let fileURL: URL
        if let existing = existingFileURL {
            fileURL = existing
        } else {
            let dateFolder = dateFolderName(for: transcript.startDate)
            let directory = baseDirectory.appendingPathComponent(dateFolder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileName = slugify(transcript.meetingName) + ".md"
            fileURL = deduplicatedFileURL(directory: directory, fileName: fileName)
        }

        let markdown = renderMarkdown(transcript: transcript)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    // MARK: - Rendering

    @MainActor
    static func renderMarkdown(transcript: MeetingTranscript) -> String {
        var lines: [String] = []

        // Title
        lines.append("# \(transcript.meetingName)")
        lines.append("")

        // Metadata
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let startStr = dateFormatter.string(from: transcript.startDate)
        if let endDate = transcript.endDate {
            let endTimeFormatter = DateFormatter()
            endTimeFormatter.timeStyle = .short
            let endStr = endTimeFormatter.string(from: endDate)
            lines.append("**Date:** \(startStr) — \(endStr)")
        } else {
            lines.append("**Date:** \(startStr) (in progress)")
        }
        lines.append("")

        // Notes
        lines.append("## Notes")
        lines.append("")
        if transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("*No notes.*")
        } else {
            lines.append(transcript.notes)
        }
        lines.append("")

        // Transcript
        lines.append("## Transcript")
        lines.append("")

        if transcript.segments.isEmpty {
            lines.append("*No transcript yet.*")
        } else {
            for segment in transcript.segments {
                let timestamp = segment.formattedTimestamp
                let speaker = segment.speaker.displayName
                lines.append("**[\(timestamp)] \(speaker):** \(segment.text)  ")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Formats a date as "2026-04-07" for folder names.
    private static func dateFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Converts a meeting name to a file-safe slug.
    /// "Design Review @ 10am" → "design-review-at-10am"
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let replaced = lowered.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()

        // Collapse multiple dashes, trim edges.
        let collapsed = replaced.replacingOccurrences(
            of: "-{2,}",
            with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return trimmed.isEmpty ? "meeting" : trimmed
    }

    /// If "design-review.md" already exists, returns "design-review-2.md", etc.
    private static func deduplicatedFileURL(directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }

        return candidate
    }
}
