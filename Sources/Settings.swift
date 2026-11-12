import Foundation

/// Thin UserDefaults wrapper for the handful of settings the Settings window owns.
/// Everything else stays in the JSON config (Config.swift), which is unchanged: when a
/// key here has not been set yet, the JSON value is still the effective one.
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let showMemoryPill = "showMemoryPill"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// nil until the user flips the switch in the Settings window, so the JSON config's
    /// `showMemoryReadout` keeps working for anyone who never opens it.
    private var storedShowMemoryPill: Bool? {
        defaults.object(forKey: Key.showMemoryPill) as? Bool
    }

    /// Effective value: the user's choice from the Settings window, else the JSON config.
    func showMemoryPill(jsonValue: Bool) -> Bool {
        storedShowMemoryPill ?? jsonValue
    }

    /// Writes the user's choice. Pass nil to fall back to the JSON config again.
    func setShowMemoryPill(_ value: Bool?) {
        if let value {
            defaults.set(value, forKey: Key.showMemoryPill)
        } else {
            defaults.removeObject(forKey: Key.showMemoryPill)
        }
    }
}
