import AppKit
import SwiftUI
import ChronicleDesktopCore

// Settings window (replaces the old single NSAlert). Sections, top to bottom:
// Account (sign in / out), Connection (API URL), Shortcut, Reminders, Retry
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
    @Published var pendingCount = 0

    let clients: CaptureClients
    private let settings: SettingsStore
    private let localStore: LocalCaptureStore
    private let onSaveShortcut: (ShortcutSpec) -> Void
    private let onSignInChanged: () -> Void
    private let retry: () async -> (sent: Int, remaining: Int)

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

    private var currentURL: URL { URL(string: apiURLString) ?? settings.load().apiURL }

    func saveAPIURL() {
        guard let url = URL(string: apiURLString.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil
        else {
            status = "Enter a valid URL (e.g. https://api.example.com)"
            return
        }
        settings.saveAPIURL(url)
        status = "Server URL saved."
    }

    func saveShortcut(_ spec: ShortcutSpec) {
        settings.saveShortcut(spec)
        onSaveShortcut(spec)
    }

    func signIn() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            status = "Email and password are required."
            return
        }
        let url = currentURL
        let client = AuthAPIClient(apiURL: url)
        let pw = password
        Task { @MainActor in
            do {
                let response = try await client.login(email: email, password: pw)
                if response.mfaRequired == true {
                    status = "MFA accounts can't sign in from the desktop yet."
                    return
                }
                guard let token = response.accessToken, !token.isEmpty else {
                    status = "Sign in failed: no token returned."
                    return
                }
                settings.save(ChronicleConfig(apiURL: url, token: token))
                isSignedIn = true
                password = ""
                status = "Signed in."
                onSignInChanged()
            } catch {
                status = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    func signOut() {
        let url = currentURL
        // Snapshot the refresh cookie, then clear ALL local credentials up front.
        // onSignInChanged() (and the upload/reminder sync it triggers) must not run
        // while a usable token still points at the account being signed out, and a
        // crash mid-logout must not leave a cookie that silently re-authenticates on
        // the next launch. The snapshot keeps the best-effort server-side revoke
        // working even though the local cookie store is already cleared.
        let cookies = settings.apiCookies()
        settings.signOut()
        isSignedIn = false
        status = "Signed out."
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
            status = "Synced \(result.sent); \(result.remaining) still waiting."
            refreshPending()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(ReminderNotifier.enabledKey) private var notifyOnDue = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
        .frame(minWidth: 520, minHeight: 600)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account").font(.headline)
            if model.isSignedIn {
                HStack {
                    Label("Signed in", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") { model.signOut() }
                }
            } else {
                WorkspaceField(prompt: "Email", text: $model.email, compact: true)
                WorkspaceField(prompt: "Password", text: $model.password,
                               secure: true, compact: true, onSubmit: { model.signIn() })
                HStack {
                    Spacer()
                    Button("Sign In") { model.signIn() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.headline)
            HStack {
                WorkspaceField(prompt: "https://api.example.com", text: $model.apiURLString,
                               compact: true)
                Button("Save") { model.saveAPIURL() }
            }
            Text("The Chronicle API the desktop app talks to.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Capture Shortcut").font(.headline)
            ShortcutRecorder(initial: model.currentShortcut) { model.saveShortcut($0) }
                .frame(height: 20)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1),
                )
            Text("Click the field, then press a shortcut (or double-tap Control).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders").font(.headline)
            Toggle(isOn: $notifyOnDue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show a system notification when a reminder is due")
                    Text("Reminders are scheduled locally and fire even when the app is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var retryQueueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Retry Queue").font(.headline)
                Spacer()
                Button { model.refreshPending() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Refresh")
            }
            HStack {
                Text(model.pendingCount == 0
                     ? "All captures are synced."
                     : "\(model.pendingCount) capture\(model.pendingCount == 1 ? "" : "s") waiting to sync.")
                    .foregroundStyle(model.pendingCount == 0 ? .secondary : .primary)
                Spacer()
                Button("Retry Now") { model.retryNow() }.disabled(model.pendingCount == 0)
            }
            Text("Captures made offline (or before signing in) sync here once you're online.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shortcut recorder bridge

struct ShortcutRecorder: NSViewRepresentable {
    let initial: ShortcutSpec
    let onChange: (ShortcutSpec) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField(shortcut: initial)
        field.onChange = onChange
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {}
}

// MARK: - Webhooks

struct WebhooksSection: View {
    let clients: CaptureClients

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
                    Text("Webhooks").font(.headline)
                    Text("POST a templated payload to an external service when a capture matches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if clients.webhook() != nil {
                    Button { editing = EditTarget(rule: nil) } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                }
            }

            if clients.webhook() == nil {
                Text("Sign in to manage webhooks.").font(.callout).foregroundStyle(.secondary)
            } else if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if rules.isEmpty && clients.webhook() != nil && loaded {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app").font(.title2).foregroundStyle(.tertiary)
                    Text("No rules yet").foregroundStyle(.secondary)
                    Text("e.g. captures mentioning an amount go to a ledger service.")
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
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit")
                .opacity(hoverID == rule.id ? 1 : 0)
            Button { delete(rule) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
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
        if !rule.keywords.isEmpty { conds.append("keywords " + rule.keywords.joined(separator: ", ")) }
        if let q = rule.semanticQuery, !q.isEmpty {
            conds.append("semantic “\(q)” ≥ \(String(format: "%.2f", rule.semanticThreshold))")
        }
        let cond = conds.isEmpty ? "every capture" : conds.joined(separator: " | ")
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
            Text(rule == nil ? "New Webhook" : "Edit Webhook").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Name")
                    WorkspaceField(prompt: "Ledger", text: $draft.name, compact: true)
                }
                GridRow {
                    label("URL")
                    WorkspaceField(prompt: "https://ledger.example/api",
                                   text: $draft.targetUrl, compact: true)
                }
                GridRow {
                    label("Keywords")
                    WorkspaceField(prompt: "comma-separated, any match fires; optional",
                                   text: $keywordsText, compact: true)
                }
                GridRow {
                    label("Semantic")
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceField(
                            prompt: "describe what to match; empty = no semantic match",
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
                    label("Payload")
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $draft.payloadTemplate)
                            .font(.callout.monospaced()).frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        Text("Placeholders: [capture.text] [capture.id] [capture.created_at]")
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
                Button("Save & Test") { Task { await save(thenTest: true) } }
                    .disabled(!valid || busy)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save(thenTest: false); if error.isEmpty { dismiss() } } }
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
        guard let client = clients.webhook() else { error = "Sign in to save webhooks."; return }
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
        guard let recall = clients.recall() else { return "Sign in to test." }
        do {
            let page = try await recall.recent(limit: 1)
            guard let latest = page.items.first else { return "No captures yet to test against." }
            let result = try await client.test(id: ruleID, captureId: latest.id)
            let score = result.score.map { String(format: "%.3f", $0) } ?? "n/a"
            return "Against your latest capture: \(result.matched ? "matched" : "no match") (score \(score))."
        } catch { return "Test failed: \(error.localizedDescription)" }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.refreshPending()
        let w = window ?? makeWindow()
        window = w
        ScreenPlacement.centerOnActiveScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        w.title = "Chronicle Settings"
        w.center()
        w.isReleasedWhenClosed = false
        // Open on the active Space, not the one it was last shown on (see MainView).
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(rootView: SettingsView(model: model).tint(.chronicleAccent))
        return w
    }
}
