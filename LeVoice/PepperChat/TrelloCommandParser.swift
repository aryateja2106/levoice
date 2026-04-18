import Foundation

/// Parsed Trello command extracted from a spoken voice command.
struct ParsedTrelloCommand {
    let cardTitle: String
    let boardName: String?
    let listName: String?
    let description: String?
}

/// Parses natural speech into structured Trello commands.
/// Uses simple pattern matching — no LLM needed for this.
enum TrelloCommandParser {

    /// Parse a spoken command into a structured Trello action.
    /// Examples:
    ///   "Create a Trello task called test123 and put it in Factorial under Inbox"
    ///   → title: "test123", board: "Factorial", list: "Inbox"
    ///
    ///   "Add this to Trello"
    ///   → title: (from screen context), board: nil, list: nil
    ///
    ///   "Put buy groceries in my personal board"
    ///   → title: "buy groceries", board: "personal", list: nil
    static func parse(_ command: String) -> ParsedTrelloCommand {
        let lower = command.lowercased()

        // Remove Trello-related filler words
        let cleaned = lower
            .replacingOccurrences(of: "can you ", with: "")
            .replacingOccurrences(of: "please ", with: "")
            .replacingOccurrences(of: "could you ", with: "")
            .replacingOccurrences(of: "a trello task", with: "")
            .replacingOccurrences(of: "a trello card", with: "")
            .replacingOccurrences(of: "to trello", with: "")
            .replacingOccurrences(of: "in trello", with: "")
            .replacingOccurrences(of: "on trello", with: "")
            .replacingOccurrences(of: "trello", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var title: String?
        var boardName: String?
        var listName: String?

        // Extract "called X" or "call it X"
        if let calledRange = cleaned.range(of: "called ") ?? cleaned.range(of: "call it ") {
            let afterCalled = String(cleaned[calledRange.upperBound...])
            // Title is everything until "and", "in", "under", "on"
            let stopWords = [" and ", " in my ", " in the ", " in ", " under ", " on my ", " on the ", " on "]
            var titleEnd = afterCalled.endIndex
            for stop in stopWords {
                if let range = afterCalled.range(of: stop) {
                    if range.lowerBound < titleEnd {
                        titleEnd = range.lowerBound
                    }
                }
            }
            title = String(afterCalled[..<titleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract "in/under [board] under/in [list]" or "in [list]"
        // Pattern: "in {board} under {list}" or "under {list}" or "in {board}"
        if let underRange = cleaned.range(of: " under ") {
            listName = String(cleaned[underRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ".", with: "")

            // Board is between "in" and "under"
            if let inRange = cleaned.range(of: " in my ") ?? cleaned.range(of: " in the ") ?? cleaned.range(of: " in ") {
                let betweenInAndUnder = String(cleaned[inRange.upperBound..<underRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "my ", with: "")
                    .replacingOccurrences(of: "the ", with: "")
                if !betweenInAndUnder.isEmpty {
                    boardName = betweenInAndUnder
                }
            }
        } else if let inRange = cleaned.range(of: " in my ") ?? cleaned.range(of: " in the ") ?? cleaned.range(of: " in ") {
            // No "under" — what comes after "in" could be a board or list
            let afterIn = String(cleaned[inRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "my ", with: "")
                .replacingOccurrences(of: "the ", with: "")
                .replacingOccurrences(of: ".", with: "")
            if !afterIn.isEmpty {
                // Could be either — we'll try to match against known boards/lists later
                boardName = afterIn
            }
        }

        // If no "called" pattern, try to extract title from common patterns
        if title == nil {
            let patterns = ["create ", "add ", "put ", "make "]
            for pattern in patterns {
                if let range = cleaned.range(of: pattern) {
                    let afterPattern = String(cleaned[range.upperBound...])
                    let stopWords = [" in my ", " in the ", " in ", " under ", " on my ", " on "]
                    var titleEnd = afterPattern.endIndex
                    for stop in stopWords {
                        if let stopRange = afterPattern.range(of: stop) {
                            if stopRange.lowerBound < titleEnd {
                                titleEnd = stopRange.lowerBound
                            }
                        }
                    }
                    let extracted = String(afterPattern[..<titleEnd])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "a task ", with: "")
                        .replacingOccurrences(of: "a card ", with: "")
                        .replacingOccurrences(of: "task ", with: "")
                        .replacingOccurrences(of: "card ", with: "")
                    if !extracted.isEmpty {
                        title = extracted
                    }
                    break
                }
            }
        }

        // Use the original command (cleaned of Trello words) as title if nothing else found
        let finalTitle = title ?? cleaned
            .replacingOccurrences(of: "create ", with: "")
            .replacingOccurrences(of: "add ", with: "")
            .replacingOccurrences(of: "put ", with: "")
            .replacingOccurrences(of: "make ", with: "")
            .replacingOccurrences(of: "a task ", with: "")
            .replacingOccurrences(of: "a card ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize the title
        let capitalizedTitle = finalTitle.isEmpty ? "New Task" : finalTitle.prefix(1).uppercased() + finalTitle.dropFirst()

        return ParsedTrelloCommand(
            cardTitle: capitalizedTitle,
            boardName: boardName?.capitalized,
            listName: listName?.capitalized,
            description: nil
        )
    }
}
