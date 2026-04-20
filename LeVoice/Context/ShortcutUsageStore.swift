import Foundation

/// Local-only usage tracking for shortcuts fired from the palette.
/// Stored in UserDefaults under a single key per bundle id. Never transmitted.
///
/// Keying strategy: menuPath joined by `›`. If an app renames a menu item
/// the count resets — acceptable. We don't attempt fuzzy matching because
/// that would create false-positive "same shortcut" merges across unrelated items.
struct ShortcutUsageStore {
    /// Max records retained per bundleId. Prevents unbounded UserDefaults growth
    /// for apps with very long menu trees (Xcode has ~200 shortcuts).
    static let maxRecordsPerApp = 200

    struct Record: Codable, Equatable {
        var count: Int
        var lastUsed: Date
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Increment usage for a shortcut. Called when the user fires a shortcut
    /// from the palette — NOT when they use the native keyboard chord directly
    /// (we don't observe external keystrokes).
    func record(bundleId: String, menuPath: [String]) {
        guard !bundleId.isEmpty, !menuPath.isEmpty else { return }
        var map = load(bundleId: bundleId)
        let key = Self.key(for: menuPath)
        var record = map[key] ?? Record(count: 0, lastUsed: Date.distantPast)
        record.count += 1
        record.lastUsed = Date()
        map[key] = record
        save(bundleId: bundleId, map: pruneIfNeeded(map))
    }

    /// Returns the top N recently-used entries for the given app, in reverse
    /// chronological order. Filters the returned set to `entries` — if a menu
    /// item disappeared (app updated), it's silently skipped.
    func recent(bundleId: String, entries: [ShortcutEntry], limit: Int) -> [ShortcutEntry] {
        guard !bundleId.isEmpty, limit > 0 else { return [] }
        let map = load(bundleId: bundleId)
        let sortedKeys = map
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(limit * 2) // oversample in case some entries disappeared
            .map(\.key)

        var result: [ShortcutEntry] = []
        for key in sortedKeys {
            if let match = entries.first(where: { Self.key(for: $0.menuPath) == key }) {
                result.append(match)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Returns all entries ranked by combined score: recency + frequency. Used
    /// for the "All shortcuts" section when no filter is active and no recent
    /// entries would be shown.
    func ranked(bundleId: String, entries: [ShortcutEntry]) -> [ShortcutEntry] {
        guard !bundleId.isEmpty else { return entries }
        let map = load(bundleId: bundleId)
        return entries.sorted { lhs, rhs in
            let lScore = score(for: map[Self.key(for: lhs.menuPath)])
            let rScore = score(for: map[Self.key(for: rhs.menuPath)])
            if lScore == rScore { return lhs.title < rhs.title }
            return lScore > rScore
        }
    }

    // MARK: - Internals

    private static func key(for menuPath: [String]) -> String {
        menuPath.joined(separator: "›")
    }

    private static func defaultsKey(bundleId: String) -> String {
        "shortcutUsage.\(bundleId)"
    }

    private func load(bundleId: String) -> [String: Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey(bundleId: bundleId)),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(bundleId: String, map: [String: Record]) {
        guard let encoded = try? JSONEncoder().encode(map) else { return }
        defaults.set(encoded, forKey: Self.defaultsKey(bundleId: bundleId))
    }

    private func pruneIfNeeded(_ map: [String: Record]) -> [String: Record] {
        guard map.count > Self.maxRecordsPerApp else { return map }
        // Keep the most recent N entries; drop the rest.
        let kept = map
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(Self.maxRecordsPerApp)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Combined score: heavy weight on frequency, light weight on recency decay.
    /// Score = count * recencyFactor, where recencyFactor decays over 7 days.
    private func score(for record: Record?) -> Double {
        guard let record else { return 0 }
        let ageDays = -record.lastUsed.timeIntervalSinceNow / 86_400
        let recencyFactor = max(0.1, 1.0 - (ageDays / 7.0)) // floor at 0.1 so old but popular still show
        return Double(record.count) * recencyFactor
    }
}
