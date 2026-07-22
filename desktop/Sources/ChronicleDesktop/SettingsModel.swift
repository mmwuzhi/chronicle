import AppKit
import AuthenticationServices
import SwiftUI
import ChronicleDesktopCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var apiURLString: String
    @Published var email = ""
    @Published var password = ""
    @Published var mfaCode = ""
    @Published var isSignedIn: Bool
    @Published var status: String?
    @Published var authError: String?
    @Published var isAuthenticating = false
    @Published var isSignInPresented = false
    @Published var pendingCount = 0

    private struct PendingMFA {
        let token: String
        let apiURL: URL
    }

    @Published private var pendingMFA: PendingMFA?

    let clients: CaptureClients
    private let settings: SettingsStore
    private let localStore: LocalCaptureStore
    private let onSaveShortcut: (ShortcutSpec) -> Void
    private let onSignInChanged: () -> Void
    private let retry: () async -> CaptureSyncSummary
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var authenticationTask: Task<Void, Never>?
    private var authenticationGate = AuthenticationAttemptGate()
    private let oauthPresentationContext = OAuthPresentationContext()

    init(
        settings: SettingsStore,
        localStore: LocalCaptureStore,
        clients: CaptureClients,
        onSaveShortcut: @escaping (ShortcutSpec) -> Void,
        onSignInChanged: @escaping () -> Void,
        retry: @escaping () async -> CaptureSyncSummary
    ) {
        self.settings = settings
        self.localStore = localStore
        self.clients = clients
        self.onSaveShortcut = onSaveShortcut
        self.onSignInChanged = onSignInChanged
        self.retry = retry
        let config = settings.load()
        apiURLString = config.apiURL.absoluteString
        isSignedIn = config.isUsable
        refreshPending()
    }

    var currentShortcut: ShortcutSpec { settings.loadShortcut() }
    var needsMFA: Bool { pendingMFA != nil }

    private var currentURL: URL? { ChronicleAPIEndpoint.validated(apiURLString) }

    func saveAPIURL() {
        guard let url = currentURL else {
            status = L("Use HTTPS for remote servers (HTTP is allowed only on localhost).")
            return
        }
        let wasSignedIn = isSignedIn
        settings.saveAPIURL(url)
        isSignedIn = settings.load().isUsable
        status = isSignedIn ? L("Server URL saved.") : L("Server URL saved. Sign in to this server.")
        if wasSignedIn != isSignedIn {
            onSignInChanged()
        }
    }

    func saveShortcut(_ spec: ShortcutSpec) {
        settings.saveShortcut(spec)
        onSaveShortcut(spec)
    }

    func signIn() {
        guard !isAuthenticating else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            authError = L("Email and password are required.")
            return
        }
        guard email.range(
            of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
            options: .regularExpression,
        ) != nil else {
            authError = L("Enter a valid email address.")
            return
        }
        guard let url = currentURL else {
            authError = L("Use HTTPS for remote servers (HTTP is allowed only on localhost).")
            return
        }
        let client = AuthAPIClient(apiURL: url)
        let pw = password
        guard let attemptID = beginAuthentication() else { return }
        authError = nil
        authenticationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAuthentication(attemptID) }
            do {
                let response = try await client.login(email: email, password: pw)
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                if response.mfaRequired == true {
                    self.prepareMFA(response, apiURL: url)
                    return
                }
                guard let token = response.accessToken, !token.isEmpty else {
                    self.authError = L("Sign in failed: no token returned.")
                    return
                }
                self.completeSignIn(token: token, apiURL: url)
            } catch {
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                self.authError = L("Sign in failed. Check your email and password.")
            }
        }
    }

    func signIn(provider: OAuthProvider) {
        guard !isAuthenticating else { return }
        guard let url = currentURL else {
            authError = L("Use HTTPS for remote servers (HTTP is allowed only on localhost).")
            return
        }
        let client = AuthAPIClient(apiURL: url)
        let pkce = DesktopOAuthPKCE.generate()
        let startURL: URL
        do {
            startURL = try client.desktopOAuthStartURL(
                provider: provider,
                codeChallenge: pkce.challenge,
            )
        } catch {
            authError = DesktopLocalization.shared.format(
                "Couldn't start %@ sign in.", provider.displayName
            )
            return
        }

        authError = nil
        guard let attemptID = beginAuthentication() else { return }
        let session = ASWebAuthenticationSession(
            url: startURL,
            callbackURLScheme: "chronicle",
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.authenticationGate.accepts(attemptID) else { return }
                self.webAuthenticationSession = nil
                guard error == nil else {
                    self.finishAuthentication(attemptID)
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                else {
                    self.authError = DesktopLocalization.shared.format(
                        "%@ returned an invalid response.", provider.displayName
                    )
                    self.finishAuthentication(attemptID)
                    return
                }
                if components.queryItems?.first(where: { $0.name == "error" })?.value == "mfa_required" {
                    self.authError = L("MFA sign-in requires a newer Chronicle server.")
                    self.finishAuthentication(attemptID)
                    return
                }
                guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty
                else {
                    self.authError = DesktopLocalization.shared.format(
                        "%@ returned no sign-in code.", provider.displayName
                    )
                    self.finishAuthentication(attemptID)
                    return
                }
                self.exchangeOAuthCode(
                    code,
                    codeVerifier: pkce.verifier,
                    provider: provider,
                    client: client,
                    apiURL: url,
                    attemptID: attemptID,
                )
            }
        }
        session.presentationContextProvider = oauthPresentationContext
        session.prefersEphemeralWebBrowserSession = false
        webAuthenticationSession = session
        guard session.start() else {
            webAuthenticationSession = nil
            authError = DesktopLocalization.shared.format(
                "Couldn't open %@ sign in.", provider.displayName
            )
            finishAuthentication(attemptID)
            return
        }
    }

    func presentSignIn() {
        authError = nil
        isSignInPresented = true
    }

    func cancelSignIn() {
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationGate.cancel()
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        isAuthenticating = false
        pendingMFA = nil
        mfaCode = ""
        authError = nil
        isSignInPresented = false
    }

    func backFromMFA() {
        guard !isAuthenticating else { return }
        pendingMFA = nil
        mfaCode = ""
        authError = nil
    }

    func verifyMFA() {
        guard !isAuthenticating, let pendingMFA else { return }
        let code = mfaCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            authError = L("Enter your authenticator code or a recovery code.")
            return
        }
        let client = AuthAPIClient(apiURL: pendingMFA.apiURL)
        guard let attemptID = beginAuthentication() else { return }
        authError = nil
        authenticationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAuthentication(attemptID) }
            do {
                let token = try await client.verifyMFA(
                    mfaToken: pendingMFA.token,
                    code: code,
                )
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                self.completeSignIn(token: token, apiURL: pendingMFA.apiURL)
            } catch AuthAPIError.httpStatus(429) {
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                self.authError = L("Too many attempts. Try again later.")
            } catch {
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                self.authError = L("Invalid or expired code. Try again.")
            }
        }
    }

    private func exchangeOAuthCode(
        _ code: String,
        codeVerifier: String,
        provider: OAuthProvider,
        client: AuthAPIClient,
        apiURL: URL,
        attemptID: UUID
    ) {
        authenticationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAuthentication(attemptID) }
            do {
                let response = try await client.exchangeDesktopOAuthCode(
                    code,
                    codeVerifier: codeVerifier,
                )
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                if response.mfaRequired == true {
                    self.prepareMFA(response, apiURL: apiURL)
                    return
                }
                guard let token = response.accessToken, !token.isEmpty else {
                    self.authError = L("Sign in failed: no token returned.")
                    return
                }
                self.completeSignIn(token: token, apiURL: apiURL)
            } catch {
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
                self.authError = DesktopLocalization.shared.format(
                    "Couldn't finish %@ sign in. Try again.", provider.displayName
                )
            }
        }
    }

    private func beginAuthentication() -> UUID? {
        guard let attemptID = authenticationGate.begin() else { return nil }
        isAuthenticating = true
        return attemptID
    }

    private func finishAuthentication(_ attemptID: UUID) {
        guard authenticationGate.finish(attemptID) else { return }
        authenticationTask = nil
        isAuthenticating = false
    }

    func prepareMFA(_ response: LoginResponse, apiURL: URL) {
        guard let token = response.mfaToken, !token.isEmpty else {
            authError = L("Sign in failed: no MFA token returned.")
            return
        }
        pendingMFA = PendingMFA(token: token, apiURL: apiURL)
        password = ""
        mfaCode = ""
        authError = nil
    }

    private func completeSignIn(token: String, apiURL: URL) {
        settings.save(ChronicleConfig(apiURL: apiURL, token: token))
        isSignedIn = true
        password = ""
        pendingMFA = nil
        mfaCode = ""
        authError = nil
        isSignInPresented = false
        status = L("Signed in.")
        onSignInChanged()
    }

    func signOut() {
        let url = currentURL ?? settings.load().apiURL
        // Snapshot the refresh cookie, then clear ALL local credentials up front.
        // onSignInChanged() (and the upload/reminder sync it triggers) must not run
        // while a usable token still points at the account being signed out, and a
        // crash mid-logout must not leave a cookie that silently re-authenticates on
        // the next launch. The snapshot keeps the best-effort server-side revoke
        // working even though the local cookie store is already cleared.
        let cookies = settings.apiCookies()
        settings.signOut()
        isSignedIn = false
        status = L("Signed out.")
        onSignInChanged()
        Task {
            try? await AuthAPIClient(apiURL: url).logout(cookies: cookies)
        }
    }

    func refreshPending() {
        do {
            pendingCount = try localStore.syncBacklog().total
        } catch {
            pendingCount = 0
            status = L("Couldn't read the sync queue.")
        }
    }

    func retryNow() {
        Task { @MainActor in
            let result = await retry()
            switch result.status {
            case .completed:
                status = DesktopLocalization.shared.format(
                    "Synced %d; %d still waiting.", result.syncedCount, result.remaining
                )
            case .inProgress:
                status = L("Sync is already in progress.")
            case .failed:
                status = L("Sync couldn't finish. Try again.")
            }
            refreshPending()
        }
    }
}

struct AuthenticationAttemptGate {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func cancel() {
        activeID = nil
    }
}

extension OAuthProvider {
    var displayName: String {
        switch self {
        case .google: "Google"
        case .github: "GitHub"
        }
    }
}

@MainActor
private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
