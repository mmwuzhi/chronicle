import AppKit
import SwiftUI
import ChronicleDesktopCore

// A focused window for one capture: its full content, the explicit links the user
// has made (GET /captures/{id}/links — add/remove right here), and the semantic
// "Related" suggestions (GET /captures/{id}/related). Tapping a linked or related
// row navigates to it in place (with a Back stack), so the window doubles as a
// lightweight way to walk a chain of related memories. Editing and explicit
// linking are both available in place.
@MainActor
final class CaptureDetailModel: ObservableObject {
    @Published var capture: RowItem
    @Published var linked: [RowItem] = []
    @Published var related: [RowItem] = []
    @Published var loading = false
    @Published var error = ""
    @Published private(set) var canGoBack = false
    @Published var editDraft: CaptureEditDraft?
    @Published var loadingEdit = false

    private var history: [RowItem] = []
    private let clients: CaptureClients
    private var loadTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?

    init(capture: RowItem, clients: CaptureClients) {
        self.capture = capture
        self.clients = clients
    }

    var signedIn: Bool { clients.recall() != nil }

    var isPinned: Bool { clients.isPinned(capture.id) }
    func togglePin() { clients.togglePin(capture) }

    func beginEditing() {
        guard editDraft == nil, !loadingEdit else { return }
        if let draft = CaptureEditDraft(item: capture) {
            editDraft = draft
            error = ""
            return
        }
        guard capture.synced, let client = clients.recall() else {
            error = L("This Capture has no editable text.")
            return
        }

        let id = capture.id
        loadingEdit = true
        editTask?.cancel()
        editTask = Task { @MainActor in
            defer { loadingEdit = false }
            do {
                let fullCapture = try await client.capture(id: id)
                guard !Task.isCancelled, capture.id == id else { return }
                let fullRow = RowItem(fullCapture)
                capture = fullRow
                guard let draft = CaptureEditDraft(item: fullRow) else {
                    error = L("This Capture has no editable text.")
                    return
                }
                editDraft = draft
                error = ""
            } catch let editError {
                guard !Task.isCancelled, capture.id == id else { return }
                error = describeCaptureError(editError)
            }
        }
    }

    func updateEditDraft(_ text: String) {
        editDraft?.text = text
    }

    func cancelEditing() {
        editTask?.cancel()
        editTask = nil
        loadingEdit = false
        editDraft = nil
    }

    func commitEditing() {
        guard !loadingEdit, let draft = editDraft else { return }
        let next = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        if next == draft.originalText {
            editDraft = nil
            return
        }

        let id = draft.id
        if clients.localSetText(id, next) {
            capture = capture.replacingRawText(next)
            editDraft = nil
            error = ""
            CaptureEvents.postChanged()
            Task { await clients.syncEdits() }
            return
        }
        guard let client = clients.recall() else {
            error = L("Not signed in — sign in from Settings to edit.")
            return
        }

        loadingEdit = true
        editTask?.cancel()
        editTask = Task { @MainActor in
            defer { loadingEdit = false }
            do {
                let updated = try await client.update(id: id, rawText: next)
                guard !Task.isCancelled, capture.id == id else { return }
                capture = RowItem(updated)
                editDraft = nil
                error = ""
                CaptureEvents.postChanged()
            } catch let editError {
                guard !Task.isCancelled, capture.id == id else { return }
                error = describeCaptureError(editError)
            }
        }
    }

    // Navigate to a related capture, remembering where we came from.
    func open(_ row: RowItem) {
        guard row.id != capture.id else { return }
        cancelEditing()
        history.append(capture)
        canGoBack = true
        capture = row
        reload()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        cancelEditing()
        canGoBack = !history.isEmpty
        capture = previous
        reload()
    }

    func reload() {
        loadTask?.cancel()
        linked = []
        related = []
        error = ""
        let id = capture.id
        loading = true
        loadTask = Task { @MainActor in
            defer { loading = false }
            if clients.recall() == nil {
                await self.loadLocalRelated(for: self.capture)
            } else {
                await self.loadLinksAndRelated(for: id)
            }
        }
    }

    // Links are the durable, user-owned surface, so a load failure surfaces a clear
    // auth lapse; related suggestions are best-effort and never an error surface.
    // The id guard drops a write whose capture the user has since navigated past.
    private func loadLinksAndRelated(for id: String) async {
        guard let client = clients.recall() else { return }
        do {
            let attachments = try await client.attachments(id: id)
            guard !Task.isCancelled, id == capture.id else { return }
            capture = capture.replacingAttachments(attachments)
        } catch {
            guard !Task.isCancelled, id == capture.id else { return }
            if case CaptureAPIError.httpStatus(401) = error {
                self.error = L("Session expired — sign in again from Settings.")
            }
        }
        do {
            let items = try await client.links(id: id)
            guard !Task.isCancelled, id == capture.id else { return }
            linked = items.map(RowItem.init)
        } catch {
            guard !Task.isCancelled, id == capture.id else { return }
            if case CaptureAPIError.httpStatus(401) = error {
                self.error = L("Session expired — sign in again from Settings.")
            }
        }
        if let items = try? await client.related(id: id) {
            guard !Task.isCancelled, id == capture.id else { return }
            related = items.map(RowItem.init)
        }
        if related.isEmpty {
            await loadLocalRelated(for: capture)
        }
    }

    // Offline/default suggestions: use the on-device semantic index to surface
    // possible neighbours even when the user is signed out or the server has no
    // embedding result. Explicit links and the current capture are filtered out.
    private func loadLocalRelated(for row: RowItem) async {
        let q = row.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let excluded = Set(linked.map(\.id)).union([row.id])
        let local = await clients.localSemanticSearch(q)
            .filter { !excluded.contains($0.id) }
        guard !Task.isCancelled, row.id == capture.id else { return }
        related = Array(local.prefix(10))
    }

    // Add/remove an explicit link, then re-sync both lists from the server so the
    // newly linked capture moves out of "Related" into "Linked" (and back on
    // removal). The server is the source of truth; we never guess optimistically.
    func addLink(_ targetId: String) {
        guard let client = clients.recall() else { return }
        let id = capture.id
        Task { @MainActor in
            do {
                try await client.addLink(id: id, targetId: targetId)
            } catch {
                handleMutateError(error, id: id)
                return
            }
            guard id == capture.id else { return }
            await loadLinksAndRelated(for: id)
        }
    }

    func removeLink(_ targetId: String) {
        guard let client = clients.recall() else { return }
        let id = capture.id
        Task { @MainActor in
            do {
                try await client.removeLink(id: id, targetId: targetId)
            } catch {
                handleMutateError(error, id: id)
                return
            }
            guard id == capture.id else { return }
            await loadLinksAndRelated(for: id)
        }
    }

    private func handleMutateError(_ error: Error, id: String) {
        guard id == capture.id else { return }
        if case CaptureAPIError.httpStatus(401) = error {
            self.error = L("Session expired — sign in again from Settings.")
        }
    }

    // Candidates for the "+ Link" picker: full-text search hits minus this capture
    // and anything already linked. Blank query or any failure yields no candidates.
    func linkCandidates(matching query: String) async -> [RowItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let client = clients.recall() else { return [] }
        guard let res = try? await client.find(q: q) else { return [] }
        let exclude = Set(linked.map(\.id)).union([capture.id])
        return res.items.map(RowItem.init).filter { !exclude.contains($0.id) }
    }
}

struct CaptureDetailView: View {
    @ObservedObject var model: CaptureDetailModel
    @ObservedObject private var localization = DesktopLocalization.shared
    var onCopy: (String) -> Void

    @State private var showPicker = false
    // Bumped on .chroniclePinsChanged to re-read model.isPinned for the pin button.
    @State private var pinTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if model.canGoBack, model.editDraft == nil {
                    Button(action: model.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Back"))
                }
                Text(L("Capture")).font(.headline)
                Spacer()
                if model.loadingEdit {
                    ProgressView().controlSize(.small)
                }
                Button { model.togglePin() } label: {
                    Label(model.isPinned ? L("Pinned") : L("Pin"),
                          systemImage: model.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless).font(.caption)
                .foregroundStyle(model.isPinned ? Color.chronicleAccent : .secondary)
                .help(model.isPinned ? L("Unpin from desktop") : L("Pin to desktop"))
                Button { onCopy(model.capture.content) } label: {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CaptureRow(
                        item: model.capture,
                        onEdit: { _ in },
                        isEditing: model.editDraft != nil,
                        draftText: model.editDraft?.text ?? "",
                        onBeginEdit: model.beginEditing,
                        onDraftChange: model.updateEditDraft,
                        onCommitEdit: model.commitEditing,
                        onCancelEdit: model.cancelEditing
                    )
                    .textSelection(.enabled)

                    if model.editDraft == nil, !model.capture.attachments.isEmpty {
                        attachmentSection
                    }

                    if !model.error.isEmpty {
                        Text(model.error).foregroundStyle(.red).font(.caption)
                    }

                    if model.editDraft == nil {
                        Divider()

                        if model.loading {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        } else {
                            linkedHeader
                            if showPicker {
                                LinkPickerView(
                                    suggestions: model.related,
                                    search: { await model.linkCandidates(matching: $0) },
                                    onPick: { row in model.addLink(row.id); showPicker = false },
                                )
                            }
                            linkedSection

                            Divider()

                            Text(L("Related")).font(.caption).foregroundStyle(.secondary)
                            relatedSection
                        }
                    }
                }
                .padding(.trailing, DesktopScrollLayout.trailingActionGutter)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Attachments"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.capture.attachments) { attachment in
                Button {
                    guard let url = URL(string: attachment.webUrl) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "paperclip")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .lineLimit(1)
                            if let size = attachment.sizeBytes {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(size),
                                    countStyle: .file
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .help(L("Open attachment"))
            }
        }
    }

    private var linkedHeader: some View {
        HStack {
            Text(L("Linked")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.signedIn {
                Button { showPicker.toggle() } label: {
                    Label(showPicker ? L("Done") : L("Link"),
                          systemImage: showPicker ? "checkmark" : "plus")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var linkedSection: some View {
        if !model.signedIn {
            Text(L("Sign in to manage links."))
                .foregroundStyle(.secondary).font(.caption)
        } else if model.linked.isEmpty {
            Text(L("No linked captures yet."))
                .foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(model.linked) { row in
                CaptureRow(
                    item: row,
                    onOpen: { model.open(row) },
                    onUnlink: { model.removeLink(row.id) },
                    onBeginEdit: {
                        model.open(row)
                        model.beginEditing()
                    }
                )
            }
        }
    }

    @ViewBuilder private var relatedSection: some View {
        if model.related.isEmpty {
            Text(L("No related captures yet."))
                .foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(model.related) { row in
                CaptureRow(
                    item: row,
                    onOpen: { model.open(row) },
                    onBeginEdit: {
                        model.open(row)
                        model.beginEditing()
                    }
                )
            }
        }
    }
}

// Opens a separate, independent detail window per capture so several can stay open
// side by side for comparison. Deduped by the capture each window currently shows
// (even after in-place Back/Related navigation) — opening one that's already on
// screen just brings it forward. No native window tabs, so the app stays .accessory
// and never flickers into the Dock; the windows follow the user's active Space like
// the main window does.
@MainActor
final class CaptureDetailWindowController: NSObject, NSWindowDelegate {
    private struct Entry {
        let window: NSWindow
        let model: CaptureDetailModel
    }

    private var entries: [Entry] = []
    private let clients: CaptureClients

    init(clients: CaptureClients) {
        self.clients = clients
        super.init()
    }

    func open(_ row: RowItem, beginEditing: Bool = false) {
        if let existing = entries.first(where: { $0.model.capture.id == row.id }) {
            if beginEditing { existing.model.beginEditing() }
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = CaptureDetailModel(capture: row, clients: clients)
        let view = CaptureDetailView(model: model, onCopy: Self.copy)
        let w = makeWindow(title: Self.title(for: row))
        w.delegate = self
        w.contentView = NSHostingView(rootView: view.tint(.chronicleAccent))
        positionCascaded(w) // before append: cascade off the already-open count
        entries.append(Entry(window: w, model: model))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if beginEditing { model.beginEditing() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        entries.removeAll { $0.window === w }
    }

    private func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.isRestorable = false // no uninvited reopen on relaunch (see main window)
        // Follow the user to the active Space (like the main window; opposite of
        // a pinned sticky, which stays put). No frame autosave: with many windows
        // they would all fight over one saved frame, so we cascade instead.
        w.collectionBehavior.insert(.moveToActiveSpace)
        return w
    }

    // Center the first window on the active screen; offset each subsequent one so a
    // fresh window never lands exactly on top of an existing one.
    private func positionCascaded(_ window: NSWindow) {
        let visible = (ScreenPlacement.active() ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let step = CGFloat(entries.count % 6) * 28
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2 + step,
            y: visible.midY - size.height / 2 - step,
        ))
    }

    // A short title from the capture's first line so several windows are
    // distinguishable in Mission Control and the Window menu.
    private static func title(for row: RowItem) -> String {
        let firstLine = row.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return L("Capture") }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
