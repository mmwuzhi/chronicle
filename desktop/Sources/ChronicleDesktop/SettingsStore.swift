import ChronicleDesktopCore
import Foundation

final class SettingsStore {
    private static let defaultAPIURL = URL(string: "http://localhost:8080")!

    private enum Key {
        static let apiURL = "apiURL"
        static let token = "token"
        static let hotKey = "hotKey"
        static let shortcut = "shortcut"
        static let signedInOnce = "hasSignedInOnce"
        static let localScopeOrigin = "localCaptureScopeOrigin"
        static let localScopeUserID = "localCaptureScopeUserID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ChronicleConfig {
        let apiURL = configuredAPIURL()
        // A URL saved by an older build may be remote plaintext HTTP. Do not
        // silently move its bearer token onto the localhost fallback; require a
        // fresh sign-in after the endpoint is corrected.
        let token = configuredURLIsRejected ? "" : (defaults.string(forKey: Key.token) ?? "")
        return ChronicleConfig(apiURL: apiURL, token: token)
    }

    func save(_ config: ChronicleConfig) {
        guard ChronicleAPIEndpoint.isAllowed(config.apiURL) else { return }
        defaults.set(config.token, forKey: Key.token)
        defaults.set(config.apiURL.absoluteString, forKey: Key.apiURL)
        // Remembered forever: gates the first-run onboarding window. A returning
        // user who lost their session must not get popped windows at launch.
        if config.isUsable { defaults.set(true, forKey: Key.signedInOnce) }
    }

    /// True once any sign-in has succeeded on this machine. Distinguishes a
    /// virgin install (pop the onboarding window) from a signed-out returning
    /// user (stay quiet; Settings and the panel surface the state).
    var hasSignedInOnce: Bool { defaults.bool(forKey: Key.signedInOnce) }

    /// Last identity that this installation verified for its API origin. This
    /// binding intentionally survives sign-out so that account's captures remain
    /// available offline, but is returned only when the configured origin matches.
    func loadLocalCaptureScope() -> LocalCaptureScope? {
        guard let savedOrigin = defaults.string(forKey: Key.localScopeOrigin),
              let userID = defaults.string(forKey: Key.localScopeUserID),
              let candidate = LocalCaptureScope(apiURL: configuredAPIURL(), userID: userID),
              candidate.apiOrigin == savedOrigin
        else { return nil }
        return candidate
    }

    func saveVerifiedLocalCaptureScope(_ scope: LocalCaptureScope) {
        defaults.set(scope.apiOrigin, forKey: Key.localScopeOrigin)
        defaults.set(scope.userID, forKey: Key.localScopeUserID)
    }

    func saveAPIURL(_ url: URL) {
        guard ChronicleAPIEndpoint.isAllowed(url) else { return }
        if Self.credentialOrigin(of: configuredAPIURL()) != Self.credentialOrigin(of: url) {
            // A bearer token is scoped to the server that issued it. Changing
            // origin must not forward that credential (or its refresh cookie) to
            // a different host; sign in again after saving the new endpoint.
            signOut()
        }
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
        if let raw = defaults.string(forKey: Key.apiURL),
           let url = ChronicleAPIEndpoint.validated(raw)
        {
            return url
        }
        if let raw = ProcessInfo.processInfo.environment["CHRONICLE_API_URL"],
           let url = ChronicleAPIEndpoint.validated(raw)
        {
            return url
        }
        return Self.defaultAPIURL
    }

    private var configuredURLIsRejected: Bool {
        if let raw = defaults.string(forKey: Key.apiURL) {
            return ChronicleAPIEndpoint.validated(raw) == nil
        }
        if let raw = ProcessInfo.processInfo.environment["CHRONICLE_API_URL"] {
            return ChronicleAPIEndpoint.validated(raw) == nil
        }
        return false
    }

    private static func credentialOrigin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
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
