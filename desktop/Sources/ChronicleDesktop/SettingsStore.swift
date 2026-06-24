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
        let apiURL = configuredAPIURL()
        let token = defaults.string(forKey: Key.token) ?? ""
        return ChronicleConfig(apiURL: apiURL, token: token)
    }

    func save(_ config: ChronicleConfig) {
        defaults.set(config.token, forKey: Key.token)
        defaults.set(config.apiURL.absoluteString, forKey: Key.apiURL)
    }

    func saveAPIURL(_ url: URL) {
        defaults.set(url.absoluteString, forKey: Key.apiURL)
    }

    // The refresh cookie(s) the API host would receive, captured before signOut()
    // deletes them so a server-side logout can still present them explicitly.
    func apiCookies() -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(for: configuredAPIURL()) ?? []
    }

    func signOut() {
        defaults.removeObject(forKey: Key.token)
        // Drop the refresh cookie too: it lives in URLSession.shared's cookie
        // store, and refreshSessionIfPossible() would otherwise trade it for a
        // new access token on next launch — silently re-authenticating a user
        // who chose Sign Out. cookies(for:) returns exactly the cookies that
        // would be sent to the API host, refresh_token among them.
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies(for: configuredAPIURL()) ?? [] {
            storage.deleteCookie(cookie)
        }
    }

    // Precedence: a user-saved URL wins, then the env override, then the default.
    // The env override stays useful for dev (`CHRONICLE_API_URL`) until the user
    // sets one explicitly in Settings.
    private func configuredAPIURL() -> URL {
        if let raw = defaults.string(forKey: Key.apiURL), let url = URL(string: raw) {
            return url
        }
        if let raw = ProcessInfo.processInfo.environment["CHRONICLE_API_URL"],
           let url = URL(string: raw)
        {
            return url
        }
        return Self.defaultAPIURL
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
