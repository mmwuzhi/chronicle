import Combine
import SwiftUI
import ChronicleDesktopCore

@MainActor
final class CaptureShareSheetModel: ObservableObject {
    @Published var expiresIn: CaptureShareExpiry = .sevenDays
    @Published private(set) var activeShare: CaptureShare?
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var copied = false
    @Published private(set) var error = ""

    let captureID: String
    let previewText: String

    var displayedPreviewText: String {
        activeShare?.snapshotRawText ?? previewText
    }

    private let clients: CaptureClients

    init(capture: RowItem, clients: CaptureClients) {
        captureID = capture.id
        previewText = capture.editableRawText ?? capture.content
        self.clients = clients
    }

    func load() async {
        guard !loading else { return }
        let generation = clients.session.snapshot()
        guard let client = clients.share() else {
            error = L("Sign in to share this Capture.")
            return
        }
        loading = true
        defer {
            if clients.session.isCurrent(generation) { loading = false }
        }
        do {
            let page = try await client.list(cursor: nil, limit: 2, captureID: captureID)
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            activeShare = page.items.first { !$0.isExpired() }
            copied = false
            error = activeShare?.url.isEmpty == true
                ? L("Sharing is not configured on this server.")
                : ""
        } catch {
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            self.error = describeCaptureShareError(error)
        }
    }

    func create() async {
        guard !working else { return }
        let generation = clients.session.snapshot()
        guard let client = clients.share() else {
            error = L("Sign in to share this Capture.")
            return
        }
        working = true
        defer {
            if clients.session.isCurrent(generation) { working = false }
        }
        do {
            let created = try await client.create(
                captureID: captureID,
                expiresIn: expiresIn,
                snapshotRawText: previewText
            )
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            activeShare = created
            copied = false
            error = ""
            CaptureShareEvents.postChanged()
        } catch {
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            self.error = describeCaptureShareError(error)
        }
    }

    func revoke() async {
        guard !working, let share = activeShare else { return }
        let generation = clients.session.snapshot()
        guard let client = clients.share() else {
            error = L("Sign in to share this Capture.")
            return
        }
        working = true
        defer {
            if clients.session.isCurrent(generation) { working = false }
        }
        do {
            try await client.revoke(id: share.id)
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            activeShare = nil
            copied = false
            error = ""
            CaptureShareEvents.postChanged()
        } catch {
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            self.error = describeCaptureShareError(error)
        }
    }

    func markCopied() {
        copied = true
        error = ""
    }

    func invalidate() {
        activeShare = nil
        loading = false
        working = false
        copied = false
        error = ""
    }
}

struct CaptureShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = DesktopLocalization.shared
    @StateObject private var model: CaptureShareSheetModel
    @State private var confirmingRevoke = false

    private let clients: CaptureClients
    private let onCopy: (String) -> Void

    init(capture: RowItem, clients: CaptureClients, onCopy: @escaping (String) -> Void) {
        self.clients = clients
        self.onCopy = onCopy
        _model = StateObject(
            wrappedValue: CaptureShareSheetModel(capture: capture, clients: clients)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Share a read-only copy"))
                    .font(.title2.weight(.semibold))
                Text(L("Anyone with the link can view this copy without signing in."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("Others will see"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(renderedMarkdown(model.displayedPreviewText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 150)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                Text(L("Only the Capture text is included. Media, transcripts, files, reminders, and Connections stay private."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Loading share…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let share = model.activeShare {
                existingShare(share)
            } else {
                createControls
            }

            if !model.error.isEmpty {
                Text(model.error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            actionRow
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.load() }
        .interactiveDismissDisabled(model.working)
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            model.invalidate()
            dismiss()
        }
        .confirmationDialog(
            L("Revoke this link?"),
            isPresented: $confirmingRevoke,
            titleVisibility: .visible
        ) {
            Button(L("Revoke"), role: .destructive) {
                Task { await model.revoke() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This link will stop working immediately."))
        }
    }

    private func existingShare(_ share: CaptureShare) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Share link"))
                .font(.caption.weight(.semibold))
            if !share.url.isEmpty {
                Text(share.url)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
        }
    }

    private var createControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Link expires"))
                .font(.caption.weight(.semibold))
            Picker(L("Link expires"), selection: $model.expiresIn) {
                Text(L("In 1 day")).tag(CaptureShareExpiry.oneDay)
                Text(L("In 7 days")).tag(CaptureShareExpiry.sevenDays)
                Text(L("In 30 days")).tag(CaptureShareExpiry.thirtyDays)
                Text(L("Never")).tag(CaptureShareExpiry.never)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.expiresIn == .never {
                Text(L("Anyone with the link can keep viewing this copy until you revoke it."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L("Creating a link revokes the previous link for this Capture."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if model.activeShare != nil {
                Button(L("Revoke"), role: .destructive) {
                    confirmingRevoke = true
                }
                .disabled(model.working)
                Spacer()
                Button(L("Done")) { dismiss() }
                if model.activeShare?.url.isEmpty == false {
                    Button(model.copied ? L("Copied") : L("Copy")) {
                        guard let url = model.activeShare?.url else { return }
                        onCopy(url)
                        model.markCopied()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working)
                }
            } else {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(model.working ? L("Creating…") : L("Create link")) {
                    Task { await model.create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.working)
            }
        }
    }
}

@MainActor
func describeCaptureShareError(_ error: Error) -> String {
    switch error {
    case CaptureAPIError.httpStatus(401):
        L("Session expired. Sign in again to manage sharing.")
    case CaptureAPIError.httpStatus(404):
        L("This Capture can no longer be shared.")
    case CaptureAPIError.httpStatus(503):
        L("Sharing is not configured on this server.")
    default:
        L("We couldn't update this share. Try again.")
    }
}

enum CaptureShareEvents {
    static let changed = Notification.Name("chronicleCaptureSharesChanged")

    @MainActor
    static func postChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
