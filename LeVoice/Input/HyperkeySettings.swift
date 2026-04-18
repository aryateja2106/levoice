import Foundation

/// Configuration for the Hyperkey feature — remaps a physical key (default Caps Lock)
/// so that holding it injects ⌘⌥⌃(⇧) into subsequent keystrokes. A quick tap fires a
/// secondary key (default Escape) instead of the hyper chord.
struct HyperkeySettings: Codable, Equatable {
    /// Master toggle. When `false`, the Hyperkey tap is never installed — behavior is pure pass-through.
    var enabled: Bool
    /// Which physical key acts as the hyper trigger. Default 57 = Caps Lock.
    var remappedKeyCode: UInt16
    /// Which key fires on a quick tap (<150 ms, no other keys pressed). Default 53 = Escape.
    /// Set to the same value as `remappedKeyCode` to pass through the original key.
    var quickPressKeyCode: UInt16
    /// When `true`, the hyper chord is ⌘+⌥+⌃+⇧. When `false`, only ⌘+⌥+⌃.
    var includeShift: Bool

    static let `default` = HyperkeySettings(
        enabled: false,
        remappedKeyCode: 57,
        quickPressKeyCode: 53,
        includeShift: true
    )

    /// Duration below which a Caps Lock press+release is treated as a quick tap.
    static let quickPressThresholdSeconds: TimeInterval = 0.15
}

/// Thin UserDefaults-backed store for `HyperkeySettings`. JSON-encoded under a single key
/// to mirror the pattern used by `ChordBindingStore`.
struct HyperkeySettingsStore {
    static let defaultsKey = "hyperkeySettings"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HyperkeySettings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(HyperkeySettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save(_ settings: HyperkeySettings) {
        guard let encoded = try? JSONEncoder().encode(settings) else { return }
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
