import AppKit
import SwiftUI
import ChronicleDesktopCore

// A focused window for one capture: its full content, the explicit links the user
// has made (GET /captures/{id}/links — add/remove right here), and the semantic
// "Related" suggestions (GET /captures/{id}/related). Tapping a linked or related
// row navigates to it in place (with a Back stack), so the window doubles as a
// lightweight way to walk a chain of related memories. Editing and deleting still
// live in the main window and the web app; explicit linking is editable here.
@MainActor
final class CaptureDetailModel: ObservableObject {
    @Published var capture: RowItem
    @Published var linked: [RowItem] = []
    @Published var related: [RowItem] = []
    @Published var loading = false
    @Published var error = ""
    @Published private(set) var canGoBack = false

    private var history: [RowItem] = []
    private let clients: CaptureClients
    private var loadTask: Task<Void, Never>?

    init(capture: RowItem, clients: CaptureClients) {
        self.capture = capture
        self.clients = clients
    }

    var signedIn: Bool { clients.recall() != nil }

    var isPinned: Bool { clients.isPinned(capture.id) }
    func togglePin() { clients.togglePin(capture) }

    // Navigate to a related capture, remembering where we came from.
    func open(_ row: RowItem) {
        guard row.id != capture.id else { return }
        history.append(capture)
        canGoBack = true
        capture = row
        reload()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
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
            let items = try await client.links(id: id)
            guard !Task.isCancelled, id == capture.id else { return }
            linked = items.map(RowItem.init)
        } catch {
            guard !Task.isCancelled, id == capture.id else { return }
            if case CaptureAPIError.httpStatus(401) = error {
                self.error = "Session expired — sign in again from Settings."
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
            self.error = "Session expired — sign in again from Settings."
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
    var onCopy: (String) -> Void

    @State private var showPicker = false
    // Bumped on .chroniclePinsChanged to re-read model.isPinned for the pin button.
    @State private var pinTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if model.canGoBack {
                    Button(action: model.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Back")
                }
                Text("Capture").font(.headline)
                Spacer()
                Button { model.togglePin() } label: {
                    Label(model.isPinned ? "Pinned" : "Pin",
                          systemImage: model.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless).font(.caption)
                .foregroundStyle(model.isPinned ? Color.chronicleAccent : .secondary)
                .help(model.isPinned ? "Unpin from desktop" : "Pin to desktop")
                Button { onCopy(model.capture.content) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.capture.content.isEmpty ? "(media capture)" : model.capture.content)
                            .textSelection(.enabled)
                            .foregroundStyle(model.capture.content.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CaptureTime.precise(model.capture.createdAt))
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if !model.error.isEmpty {
                        Text(model.error).foregroundStyle(.red).font(.caption)
                    }

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

                        Text("Related").font(.caption).foregroundStyle(.secondary)
                        relatedSection
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
    }

    private var linkedHeader: some View {
        HStack {
            Text("Linked").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.signedIn {
                Button { showPicker.toggle() } label: {
                    Label(showPicker ? "Done" : "Link",
                          systemImage: showPicker ? "checkmark" : "plus")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var linkedSection: some View {
        if !model.signedIn {
            Text("Sign in to manage links.")
                .foregroundStyle(.secondary).font(.caption)
        } else if model.linked.isEmpty {
            Text("No linked captures yet.")
                .foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(model.linked) { row in
                CaptureRow(
                    item: row,
                    onOpen: { model.open(row) },
                    onUnlink: { model.removeLink(row.id) },
                )
            }
        }
    }

    @ViewBuilder private var relatedSection: some View {
        if model.related.isEmpty {
            Text("No related captures yet.")
                .foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(model.related) { row in
                CaptureRow(
                    item: row,
                    onOpen: { model.open(row) },
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

    func open(_ row: RowItem) {
        if let existing = entries.first(where: { $0.model.capture.id == row.id }) {
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
        if trimmed.isEmpty { return "Capture" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
