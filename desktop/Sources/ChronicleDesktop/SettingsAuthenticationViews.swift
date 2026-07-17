import SwiftUI
import ChronicleDesktopCore

struct SignInSheet: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var localization = DesktopLocalization.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Sign in to Chronicle"))
                    .font(.title2.weight(.semibold))
                Text(L("Use the same account you use on the web."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            providerButton(.google, icon: "g.circle.fill")
            providerButton(
                .github,
                icon: "chevron.left.forwardslash.chevron.right"
            )

            HStack(spacing: 10) {
                Divider()
                Text(L("or use email"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize()
                Divider()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Email")).font(.caption).foregroundStyle(.secondary)
                WorkspaceField(
                    prompt: "you@example.com",
                    text: $model.email,
                    compact: true
                )
                Text(L("Password")).font(.caption).foregroundStyle(.secondary)
                WorkspaceField(
                    prompt: L("Password"),
                    text: $model.password,
                    secure: true,
                    compact: true,
                    onSubmit: { model.signIn() },
                )
            }

            if let error = model.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.isAuthenticating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(L("Cancel")) {
                    model.cancelSignIn()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Sign In")) { model.signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isAuthenticating)
            }
        }
        .padding(24)
        .frame(width: 390)
        .onChange(of: model.isSignedIn) { signedIn in
            if signedIn { dismiss() }
        }
    }

    private func providerButton(
        _ provider: OAuthProvider,
        icon: String
    ) -> some View {
        Button { model.signIn(provider: provider) } label: {
            Label(
                DesktopLocalization.shared.format(
                    "Continue with %@",
                    provider.displayName
                ),
                systemImage: icon
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(model.isAuthenticating)
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
