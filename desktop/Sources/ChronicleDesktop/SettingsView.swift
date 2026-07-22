import ServiceManagement
import SwiftUI
import ChronicleDesktopCore

// Settings surface (replaces the old single NSAlert). Sections, top to bottom:
// Account (with a focused sign-in sheet), Connection (API URL), Shortcut, Reminders, Retry
// Queue (offline captures awaiting sync), and Webhooks (the capture-webhook CRUD,
// ported from rag3's settings). Visual language matches the rest of the app:
// Divider rows, hover-only icon buttons, caption/secondary hierarchy.

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
            HStack(spacing: 16) {
                Text(L("Language"))
                Spacer(minLength: 16)
                Picker("", selection: Binding(
                    get: { localization.language },
                    set: { localization.set($0) }
                )) {
                    Text(L("System")).tag(InterfaceLanguage.system)
                    Text("English").tag(InterfaceLanguage.english)
                    Text("简体中文").tag(InterfaceLanguage.chinese)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(idealWidth: 456, maxWidth: 456, alignment: .trailing)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Launch at Login"))
                    Text(L("Open Chronicle automatically when you sign in to your Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in updateLaunchAtLogin(enabled) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

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
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Show a system notification when a reminder is due"))
                    Text(L("Reminders are scheduled locally and fire even when the app is closed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $notifyOnDue)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
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
            Text(L("Offline captures and edits sync here once you're online."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
