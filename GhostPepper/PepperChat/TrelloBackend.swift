import Foundation

/// A Trello board with its lists.
struct TrelloBoard: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var lists: [TrelloList]
}

struct TrelloList: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

/// Creates Trello cards via the Trello REST API.
struct TrelloBackend {
    let apiKey: String
    let token: String

    var isConfigured: Bool {
        !apiKey.isEmpty && !token.isEmpty
    }

    /// Fetch all boards and their lists for the authenticated user.
    func fetchBoardsAndLists() async throws -> [TrelloBoard] {
        guard isConfigured else { throw TrelloError.notConfigured }

        let url = URL(string: "https://api.trello.com/1/members/me/boards?key=\(apiKey)&token=\(token)&fields=name&lists=open&list_fields=name")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TrelloError.apiError(String(data: data, encoding: .utf8) ?? "Failed to fetch boards")
        }

        guard let boardsJSON = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TrelloError.invalidResponse
        }

        return boardsJSON.compactMap { boardDict -> TrelloBoard? in
            guard let id = boardDict["id"] as? String,
                  let name = boardDict["name"] as? String else { return nil }

            let listsJSON = boardDict["lists"] as? [[String: Any]] ?? []
            let lists = listsJSON.compactMap { listDict -> TrelloList? in
                guard let listId = listDict["id"] as? String,
                      let listName = listDict["name"] as? String else { return nil }
                return TrelloList(id: listId, name: listName)
            }

            return TrelloBoard(id: id, name: name, lists: lists)
        }
    }

    /// Find the best matching list for a spoken command.
    /// Checks board names and list names for fuzzy matches.
    static func findList(matching command: String, in boards: [TrelloBoard], defaultListId: String?) -> String? {
        let lower = command.lowercased()

        // Check for explicit list/board name mentions
        for board in boards {
            for list in board.lists {
                if lower.contains(list.name.lowercased()) {
                    return list.id
                }
            }
            if lower.contains(board.name.lowercased()) {
                // Matched a board — use its first list
                return board.lists.first?.id
            }
        }

        // Fall back to configured default
        if let defaultId = defaultListId, !defaultId.isEmpty { return defaultId }

        // Fall back to first list of first board
        return boards.first?.lists.first?.id
    }

    /// Create a card on a Trello list.
    func createCard(name: String, description: String, listId: String, attachmentURL: URL? = nil) async throws -> String? {
        guard isConfigured else { throw TrelloError.notConfigured }

        var urlComponents = URLComponents(string: "https://api.trello.com/1/cards")!
        urlComponents.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "idList", value: listId),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "desc", value: description),
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TrelloError.apiError(errorBody)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cardId = parsed["id"] as? String,
              let cardURL = parsed["shortUrl"] as? String else {
            throw TrelloError.invalidResponse
        }

        // Attach file if provided
        if let attachmentURL = attachmentURL {
            try await attachFile(to: cardId, fileURL: attachmentURL)
        }

        return cardURL
    }

    /// Attach a file to an existing Trello card.
    private func attachFile(to cardId: String, fileURL: URL) async throws {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.trello.com/1/cards/\(cardId)/attachments?key=\(apiKey)&token=\(token)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let fileName = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Attachment failed but card was created — don't throw
            return
        }
    }
}

enum TrelloError: Error, LocalizedError {
    case notConfigured
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Trello is not configured. Add your API key, token, and list ID in Settings > Context Bundler."
        case .apiError(let message):
            return "Trello API error: \(message)"
        case .invalidResponse:
            return "Invalid response from Trello API."
        }
    }
}
