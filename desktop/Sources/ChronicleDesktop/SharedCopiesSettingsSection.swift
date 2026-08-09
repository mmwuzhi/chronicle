import AppKit
import Combine
import SwiftUI
import ChronicleDesktopCore

@MainActor
final class SharedCopiesSettingsModel: ObservableObject {
    @Published private(set) var shares: [CaptureShare] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var error = ""
    @Published private(set) var copiedID: String?
    @Published private(set) var nextCursor: String?

    private let clients: CaptureClients
    private var requestGeneration: UInt64 = 0

    init(clients: CaptureClients) {
        self.clients = clients
    }

    func reload() async {
        await loadPage(reset: true)
    }

    func loadMore() async {
        guard nextCursor != nil else { return }
        await loadPage(reset: false)
    }

    func sessionDidChange() {
        requestGeneration &+= 1
        shares = []
        copiedID = nil
        error = ""
        nextCursor = nil
        loaded = false
        loading = false
    }

    func markCopied(_ id: String) {
        copiedID = id
        error = ""
    }

    func revoke(_ share: CaptureShare) async {
        let sessionGeneration = clients.session.snapshot()
        guard let client = clients.share() else { return }
        do {
            try await client.revoke(id: share.id)
            guard !Task.isCancelled,
                  clients.session.isCurrent(sessionGeneration)
            else { return }
            shares.removeAll { $0.id == share.id }
            copiedID = nil
            error = ""
            CaptureShareEvents.postChanged()
        } catch {
            guard !Task.isCancelled,
                  clients.session.isCurrent(sessionGeneration)
            else { return }
            self.error = describeCaptureShareError(error)
        }
    }

    private func loadPage(reset: Bool) async {
        guard !loading else { return }
        let sessionGeneration = clients.session.snapshot()
        guard let client = clients.share() else {
            sessionDidChange()
            return
        }
        requestGeneration &+= 1
        let request = requestGeneration
        let cursor = reset ? nil : nextCursor
        loading = true
        defer {
            if requestGeneration == request { loading = false }
        }
        do {
            let page = try await client.list(cursor: cursor, limit: 50, captureID: nil)
            guard !Task.isCancelled,
                  requestGeneration == request,
                  clients.session.isCurrent(sessionGeneration)
            else { return }
            shares = reset ? page.items : shares + page.items
            nextCursor = page.nextCursor
            copiedID = nil
            error = page.items.contains { !$0.isExpired() && $0.url.isEmpty }
                ? L("Sharing is not configured on this server.")
                : ""
            loaded = true
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == request,
                  clients.session.isCurrent(sessionGeneration)
            else { return }
            self.error = describeCaptureShareError(error)
            loaded = true
        }
    }
}

struct SharedCopiesSettingsSection: View {
    let clients: CaptureClients

    @ObservedObject private var localization = DesktopLocalization.shared
    @StateObject private var model: SharedCopiesSettingsModel
    @State private var shareToRevoke: CaptureShare?

    init(clients: CaptureClients) {
        self.clients = clients
        _model = StateObject(wrappedValue: SharedCopiesSettingsModel(clients: clients))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Shared copies")).font(.headline)
                    Text(L("Review and revoke Capture links that work without signing in."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if clients.share() != nil {
                    Button { Task { await model.reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("Refresh"))
                    .disabled(model.loading)
                }
            }

            if clients.share() == nil {
                HStack {
                    Text(L("Sign in to manage shared copies."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Sign In")) { clients.openSignIn() }
                }
            } else if model.loading && !model.loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Loading shared copies…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.loaded && model.shares.isEmpty {
                Text(L("No shared copies."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(model.shares) { shareRow($0) }
                if model.nextCursor != nil {
                    Button(model.loading ? L("Loading…") : L("Load more")) {
                        Task { await model.loadMore() }
                    }
                    .disabled(model.loading)
                }
            }

            if !model.error.isEmpty {
                Text(model.error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: CaptureShareEvents.changed)) { _ in
            Task { await model.reload() }
        }
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            model.sessionDidChange()
            if clients.share() != nil {
                Task { await model.reload() }
            }
        }
        .confirmationDialog(
            L("Revoke this link?"),
            isPresented: Binding(
                get: { shareToRevoke != nil },
                set: { if !$0 { shareToRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Revoke"), role: .destructive) {
                guard let share = shareToRevoke else { return }
                shareToRevoke = nil
                Task { await model.revoke(share) }
            }
            Button(L("Cancel"), role: .cancel) { shareToRevoke = nil }
        } message: {
            Text(L("This link will stop working immediately."))
        }
    }

    private func shareRow(_ share: CaptureShare) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(share.snapshotRawText)
                    .lineLimit(2)
                Text(expiryDescription(share))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !share.isExpired(), !share.url.isEmpty {
                Button(model.copiedID == share.id ? L("Copied") : L("Copy link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.url, forType: .string)
                    model.markCopied(share.id)
                }
            }
            Button(L("Revoke"), role: .destructive) {
                shareToRevoke = share
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func expiryDescription(_ share: CaptureShare) -> String {
        if share.isExpired() { return L("Expired") }
        guard let expiresAt = share.expiresAt else { return L("No expiry") }
        return DesktopLocalization.shared.format(
            "Expires %@",
            CaptureTime.precise(expiresAt)
        )
    }

}
