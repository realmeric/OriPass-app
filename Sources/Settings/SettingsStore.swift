import Foundation

/// Where the settings live: one JSON value under one key of the defaults.
/// Without defaults nothing is read and nothing is kept, which is every
/// test's and every shot's.
struct SettingsStore {
    static let key = "settings"

    let defaults: UserDefaults?

    /// A value that will not read at all is the defaults: no choice in it is
    /// worth refusing to launch over.
    func load() -> Settings {
        guard let data = defaults?.data(forKey: Self.key) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.app.error("the settings could not be read: \((error as NSError).code)")
            return Settings()
        }
    }

    func save(_ settings: Settings) {
        guard let defaults else { return }
        let encoder = JSONEncoder()
        // For `defaults read` and a person: the keys in the same order each
        // time.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
