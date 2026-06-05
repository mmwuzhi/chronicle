import ChronicleDesktopCore
import Foundation

final class SettingsStore {
    private static let defaultAPIURL = URL(string: "http://localhost:8080")!

    private enum Key {
        static let apiURL = "apiURL"
        static let token = "token"
        static let hotKey = "hotKey"
        static let shortcut = "shortcut"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ChronicleConfig {
        let apiURL = Self.configuredAPIURL()
        let token = defaults.string(forKey: Key.token) ?? ""
        return ChronicleConfig(apiURL: apiURL, token: token)
    }

    func save(_ config: ChronicleConfig) {
        defaults.set(config.token, forKey: Key.token)
    }

    private static func configuredAPIURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CHRONICLE_API_URL"],
           let url = URL(string: raw)
        {
            return url
        }
        return defaultAPIURL
    }

    func loadShortcut() -> ShortcutSpec {
        if let raw = defaults.string(forKey: Key.shortcut),
           let spec = ShortcutParser.parse(raw)
        {
            return spec
        }

        if let raw = defaults.string(forKey: Key.hotKey),
           let spec = ShortcutParser.parse(raw)
        {
            return spec
        }

        return ShortcutParser.defaultSpec
    }

    func saveShortcut(_ spec: ShortcutSpec) {
        defaults.set(ShortcutParser.displayString(for: spec), forKey: Key.shortcut)
    }
}
