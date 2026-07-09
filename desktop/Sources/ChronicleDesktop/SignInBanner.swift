import SwiftUI
import ChronicleDesktopCore

/// A thin nudge shown on capture surfaces when the server session has lapsed, so
/// captures don't pile up in the local queue unnoticed — the desktop once sat
/// signed out for weeks with captures silently queued. Renders nothing while the
/// session is live; signing in (which clears `signedOut`) removes it.
struct SignInBanner: View {
    let status: SessionStatus
    let onSignIn: () -> Void

    var body: some View {
        if status.signedOut {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
        }
    }

    private var message: String {
        let n = status.pending
        if n > 0 {
            return "\(n) capture\(n == 1 ? "" : "s") waiting to sync — you're signed out"
        }
        return "You're signed out — new captures will queue until you sign in"
    }
}
