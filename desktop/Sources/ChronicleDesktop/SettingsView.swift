import AppKit
import AuthenticationServices
import ServiceManagement
import SwiftUI
import ChronicleDesktopCore

// Settings surface (replaces the old single NSAlert). Sections, top to bottom:
// Account (with a focused sign-in sheet), Connection (API URL), Shortcut, Reminders, Retry
// Queue (offline captures awaiting sync), and Webhooks (the capture-webhook CRUD,
// ported from rag3's settings). Visual language matches the rest of the app:
// Divider rows, hover-only icon buttons, caption/secondary hierarchy.

@MainActor
final class SettingsModel: ObservableObject {
    @Published var apiURLString: String
    @Published var email = ""
    @Published var password = ""
    @Published var isSignedIn: Bool
    @Published var status: String?
    @Published var authError: String?
    @Published var isAuthenticating = false
    @Published var isSignInPresented = false
    @Published var pendingCount = 0

    let clients: CaptureClients
    private let settings: SettingsStore
    private let localStore: LocalCaptureStore
    private let onSaveShortcut: (ShortcutSpec) -> Void
    private let onSignInChanged: () -> Void
    private let retry: () async -> (sent: Int, remaining: Int)
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
        retry: @escaping () async -> (sent: Int, remaining: Int)
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
                    self.authError = L("MFA accounts can't sign in from the desktop yet.")
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
                    self.authError = L("MFA accounts can't sign in from the desktop yet.")
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
        authError = nil
        isSignInPresented = false
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
                let token = try await client.exchangeDesktopOAuthCode(
                    code,
                    codeVerifier: codeVerifier,
                )
                guard !Task.isCancelled, self.authenticationGate.accepts(attemptID) else { return }
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

    private func completeSignIn(token: String, apiURL: URL) {
        settings.save(ChronicleConfig(apiURL: apiURL, token: token))
        isSignedIn = true
        password = ""
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
        pendingCount = (try? localStore.pendingSync(limit: 1000).count) ?? 0
    }

    func retryNow() {
        Task { @MainActor in
            let result = await retry()
            status = DesktopLocalization.shared.format(
                "Synced %d; %d still waiting.", result.sent, result.remaining
            )
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var localization = DesktopLocalization.shared
    @AppStorage(ReminderNotifier.enabledKey) private var notifyOnDue = true
    @State private var showingSignIn = false
    @State private var launchAtLogin = Self.launchAtLoginRequested(for: SMAppService.mainApp.status)
    @State private var launchAtLoginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                generalSection
                Divider()
                accountSection
                Divider()
                connectionSection
                Divider()
                shortcutSection
                Divider()
                remindersSection
                Divider()
                retryQueueSection
                Divider()
                WebhooksSection(clients: model.clients)

                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(model: model)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("General")).font(.headline)
            Picker(L("Language"), selection: Binding(
                get: { localization.language },
                set: { localization.set($0) }
            )) {
                Text(L("System")).tag(InterfaceLanguage.system)
                Text("English").tag(InterfaceLanguage.english)
                Text("简体中文").tag(InterfaceLanguage.chinese)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in updateLaunchAtLogin(enabled) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Launch at Login"))
                    Text(L("Open Chronicle automatically when you sign in to your Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = Self.launchAtLoginRequested(for: SMAppService.mainApp.status)
            launchAtLoginError = Bundle.main.bundleIdentifier == nil
                ? L("Launch at Login is available only from the packaged app.")
                : error.localizedDescription
        }
    }

    static func launchAtLoginRequested(for status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notFound, .notRegistered:
            false
        @unknown default:
            false
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Account")).font(.headline)
            if model.isSignedIn {
                HStack {
                    Label(L("Signed in"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.chronicleAccent)
                    Spacer()
                    Button(L("Sign Out")) { model.signOut() }
                }
            } else {
                HStack {
                    Label(L("Not signed in"), systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Sign In…")) {
                        model.authError = nil
                        showingSignIn = true
                    }
                }
                Text(L("Sign in to sync captures and use server-backed recall."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Server")).font(.headline)
            HStack {
                WorkspaceField(prompt: "https://api.example.com", text: $model.apiURLString,
                               compact: true)
                Button(L("Save")) { model.saveAPIURL() }
            }
            Text(L("The Chronicle API the desktop app talks to."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Quick Capture Shortcut")).font(.headline)
            ShortcutRecorder(initial: model.currentShortcut) { model.saveShortcut($0) }
                .frame(height: 20)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1),
                )
            Text(L("Click the field, then press a shortcut (or double-tap Control)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Reminders")).font(.headline)
            Toggle(isOn: $notifyOnDue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Show a system notification when a reminder is due"))
                    Text(L("Reminders are scheduled locally and fire even when the app is closed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var retryQueueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Retry Queue")).font(.headline)
                Spacer()
                Button { model.refreshPending() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Refresh"))
            }
            HStack {
                Text(model.pendingCount == 0
                     ? L("All captures are synced.")
                     : DesktopLocalization.shared.format(
                        model.pendingCount == 1
                            ? "%d capture waiting to sync."
                            : "%d captures waiting to sync.",
                        model.pendingCount
                     ))
                    .foregroundStyle(model.pendingCount == 0 ? .secondary : .primary)
                Spacer()
                Button(L("Retry Now")) { model.retryNow() }.disabled(model.pendingCount == 0)
            }
            Text(L("Captures made offline (or before signing in) sync here once you're online."))
                .font(.caption).foregroundStyle(.secondary)
        }
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

// MARK: - Webhooks

struct WebhooksSection: View {
    let clients: CaptureClients

    @ObservedObject private var localization = DesktopLocalization.shared

    @State private var rules: [WebhookRule] = []
    @State private var error = ""
    @State private var editing: EditTarget?
    @State private var hoverID: String?
    @State private var loaded = false

    struct EditTarget: Identifiable {
        let rule: WebhookRule?
        var id: String { rule?.id ?? "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Webhooks")).font(.headline)
                    Text(L("POST a templated payload to an external service when a capture matches."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if clients.webhook() != nil {
                    Button { editing = EditTarget(rule: nil) } label: {
                        Label(L("Add Rule"), systemImage: "plus")
                    }
                }
            }

            if clients.webhook() == nil {
                Text(L("Sign in to manage webhooks.")).font(.callout).foregroundStyle(.secondary)
            } else if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if rules.isEmpty && clients.webhook() != nil && loaded {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app").font(.title2).foregroundStyle(.tertiary)
                    Text(L("No rules yet")).foregroundStyle(.secondary)
                    Text(L("e.g. captures mentioning an amount go to a ledger service."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(rules) { ruleRow($0) }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { target in
            WebhookEditor(clients: clients, rule: target.rule) { await reload() }
        }
    }

    @ViewBuilder private func ruleRow(_ rule: WebhookRule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in setEnabled(rule, on) },
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { editing = EditTarget(rule: rule) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Edit"))
                .opacity(hoverID == rule.id ? 1 : 0)
            Button { delete(rule) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Delete"))
                .opacity(hoverID == rule.id ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = EditTarget(rule: rule) }
        .onHover { hoverID = $0 ? rule.id : (hoverID == rule.id ? nil : hoverID) }
        .padding(.vertical, 8)
        Divider()
    }

    private func summary(_ rule: WebhookRule) -> String {
        var conds: [String] = []
        if !rule.keywords.isEmpty {
            conds.append(L("keywords") + " " + rule.keywords.joined(separator: ", "))
        }
        if let q = rule.semanticQuery, !q.isEmpty {
            conds.append(L("semantic") + " “\(q)” ≥ \(String(format: "%.2f", rule.semanticThreshold))")
        }
        let cond = conds.isEmpty ? L("every capture") : conds.joined(separator: " | ")
        let host = URL(string: rule.targetUrl)?.host ?? rule.targetUrl
        return "\(cond) → \(host)"
    }

    private func reload() async {
        guard let client = clients.webhook() else { loaded = true; return }
        do { rules = try await client.list(); error = "" }
        catch let err { error = "\(err)" }
        loaded = true
    }

    private func setEnabled(_ rule: WebhookRule, _ on: Bool) {
        guard let client = clients.webhook() else { return }
        var draft = WebhookDraft(rule)
        draft.enabled = on
        Task { @MainActor in
            do {
                let updated = try await client.update(id: rule.id, draft)
                if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = updated }
            } catch let err { error = "\(err)" }
        }
    }

    private func delete(_ rule: WebhookRule) {
        guard let client = clients.webhook() else { return }
        Task { @MainActor in
            do { try await client.delete(id: rule.id); rules.removeAll { $0.id == rule.id } }
            catch let err { error = "\(err)" }
        }
    }
}

private struct WebhookEditor: View {
    let clients: CaptureClients
    let rule: WebhookRule?
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = DesktopLocalization.shared
    @State private var draft: WebhookDraft
    @State private var keywordsText: String
    @State private var busy = false
    @State private var error = ""
    @State private var testResult: String?

    init(clients: CaptureClients, rule: WebhookRule?, onDone: @escaping () async -> Void) {
        self.clients = clients
        self.rule = rule
        self.onDone = onDone
        let d = rule.map(WebhookDraft.init) ?? WebhookDraft()
        _draft = State(initialValue: d)
        _keywordsText = State(initialValue: d.keywords.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule == nil ? L("New Webhook") : L("Edit Webhook")).font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label(L("Name"))
                    WorkspaceField(prompt: L("Ledger"), text: $draft.name, compact: true)
                }
                GridRow {
                    label("URL")
                    WorkspaceField(prompt: "https://ledger.example/api",
                                   text: $draft.targetUrl, compact: true)
                }
                GridRow {
                    label(L("Keywords"))
                    WorkspaceField(prompt: L("comma-separated, any match fires; optional"),
                                   text: $keywordsText, compact: true)
                }
                GridRow {
                    label(L("Semantic"))
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceField(
                            prompt: L("describe what to match; empty = no semantic match"),
                            text: Binding(
                                get: { draft.semanticQuery ?? "" },
                                set: { draft.semanticQuery = $0 }),
                            compact: true)
                        if !(draft.semanticQuery ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 8) {
                                Slider(value: $draft.semanticThreshold, in: 0.3...0.9, step: 0.05)
                                    .controlSize(.small)
                                Text(String(format: "≥ %.2f", draft.semanticThreshold))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
                GridRow {
                    label(L("Payload"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $draft.payloadTemplate)
                            .font(.callout.monospaced()).frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        Text(L("Placeholders: [capture.text] [capture.id] [capture.created_at]"))
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
            }

            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button(L("Save & Test")) { Task { await save(thenTest: true) } }
                    .disabled(!valid || busy)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { Task { await save(thenTest: false); if error.isEmpty { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(!valid || busy)
            }
        }
        .padding(16).frame(width: 540)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.targetUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.payloadTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save(thenTest: Bool) async {
        guard let client = clients.webhook() else { error = L("Sign in to save webhooks."); return }
        busy = true; error = ""; testResult = nil
        draft.keywords = keywordsText
            .split(whereSeparator: { ",，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            let saved: WebhookRule
            if let id = rule?.id {
                saved = try await client.update(id: id, draft)
            } else {
                saved = try await client.create(draft)
            }
            await onDone()
            if thenTest {
                testResult = await runTest(client: client, ruleID: saved.id)
            }
        } catch let err { self.error = "\(err)" }
        busy = false
    }

    // Score the saved rule against the user's most recent capture (no delivery).
    private func runTest(client: WebhookAPIClient, ruleID: String) async -> String {
        guard let recall = clients.recall() else { return L("Sign in to test.") }
        do {
            let page = try await recall.recent(limit: 1)
            guard let latest = page.items.first else { return L("No captures yet to test against.") }
            let result = try await client.test(id: ruleID, captureId: latest.id)
            let score = result.score.map { String(format: "%.3f", $0) } ?? "n/a"
            return DesktopLocalization.shared.format(
                "Against your latest capture: %@ (score %@).",
                result.matched ? L("matched") : L("no match"), score
            )
        } catch {
            return DesktopLocalization.shared.format("Test failed: %@", error.localizedDescription)
        }
    }
}
