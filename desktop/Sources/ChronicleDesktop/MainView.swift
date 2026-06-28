import AppKit
import SwiftUI
import ChronicleDesktopCore

// The resizable main window (ported from rag3's MainView): two modes.
// Browse — empty query shows everything (newest first, paged); typing searches.
// Ask — query-time analysis with cited sources. Rows are editable (double-click)
// and deletable (hover), both wired to the capture API.
struct MainView: View {
    let clients: CaptureClients

    enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse", ask = "Ask"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .browse

    @State private var query = ""
    @State private var fragments: [Capture] = []
    @State private var localRows: [RowItem] = []
    @State private var hits: [RowItem] = []
    @State private var searched = false
    @State private var degraded = false
    @State private var nextCursor: String?
    @State private var loadingMore = false

    @State private var askQuery = ""
    @State private var answer = ""
    @State private var sources: [AskSource] = []

    @State private var busy = false
    @State private var error = ""
    @State private var signedIn = true
    // Signed in but the server is unreachable / the session couldn't be refreshed:
    // browse falls back to the local store instead of a blank list.
    @State private var offline = false

    // Deferred delete: the row vanishes immediately and an undo toast shows for a
    // few seconds; the real (soft) delete only fires when that window lapses. While
    // pending, the id is hidden from `rows` without touching the backing arrays, so
    // an undo simply un-hides it in place.
    @State private var pendingDeleteId: String?
    @State private var pendingDeleteTask: Task<Void, Never>?
    private static let undoWindow: Duration = .seconds(5)

    // Bumped on .chroniclePinsChanged to re-read clients.isPinned for each row, so
    // pinning/unpinning anywhere keeps every row's pin indicator in sync.
    @State private var pinTick = 0

    private var rows: [RowItem] {
        let base = searched ? hits : ((signedIn && !offline) ? fragments.map(RowItem.init) : localRows)
        guard let pendingDeleteId else { return base }
        return base.filter { $0.id != pendingDeleteId }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                PillModePicker(
                    segments: Mode.allCases.map { (id: $0, title: $0.rawValue, hint: nil) },
                    selected: mode,
                    onSelect: { mode = $0 },
                )
                Spacer()
            }

            switch mode {
            case .browse:
                WorkspaceField(prompt: "Search (empty = show everything)",
                               text: $query, onSubmit: runBrowse, disabled: busy)
            case .ask:
                WorkspaceField(prompt: "Ask a question, e.g. what did I work on this week",
                               text: $askQuery, onSubmit: runAsk, disabled: busy)
            }

            if busy { ProgressView().frame(maxWidth: .infinity) }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .overlay(alignment: .bottom) {
            if pendingDeleteId != nil {
                UndoDeleteToast(onUndo: undoDelete)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            // ⌘Z undoes while the toast is up; the visible button is the primary path.
            Button("") { undoDelete() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .disabled(pendingDeleteId == nil)
        }
        .animation(.easeInOut(duration: 0.2), value: pendingDeleteId)
        .task { await loadBrowse(reset: true) }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleMainShown)) { _ in
            if mode == .browse && !searched { Task { await loadBrowse(reset: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
        .onDisappear { flushPendingDelete() }
    }

    @ViewBuilder private var content: some View {
        if mode == .browse {
            // Browse + search work offline against the local store; the server's
            // semantic results merge in on top when signed in.
            if searched && rows.isEmpty && !busy {
                Text("No matches.").foregroundStyle(.secondary).padding(.top, 8)
            }
            if rows.isEmpty && !searched && !busy {
                Text((signedIn && !offline) ? "No captures yet." : "No local captures yet — capture something or sign in to sync.")
                    .foregroundStyle(.secondary).padding(.top, 8)
            }
            ForEach(rows) { row in
                CaptureRow(
                    item: row,
                    onCopy: { copy(row.content) },
                    onDelete: { delete(row.id) },
                    onEdit: { edit(row.id, $0) },
                    onOpen: { clients.openDetail(row) },
                    // Only synced captures can be pinned: a local-only id can't be
                    // re-fetched by GET /captures/{id}, so it would orphan the sticky.
                    onPin: row.synced ? { clients.togglePin(row) } : nil,
                    isPinned: clients.isPinned(row.id),
                )
                .onAppear { maybeLoadMore(row) }
                Divider().opacity(0.5)
            }
            if loadingMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
        } else if !signedIn {
            signInPrompt
        } else {
            askContent
        }
    }

    @ViewBuilder private var askContent: some View {
        if !answer.isEmpty {
            HStack {
                Spacer()
                Button { copy(answer) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !sources.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                ForEach(sources) { s in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(s.n)]").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.content)
                            Text(String(s.createdAt.prefix(10)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2).foregroundStyle(.tertiary)
            Text("Sign in to ask across your captures.").foregroundStyle(.secondary)
            Text("Browse and search work offline; Ask needs the server.")
                .font(.caption).foregroundStyle(.tertiary)
            Button("Open Settings") { clients.openSettings() }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: - Browse

    private func runBrowse() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        error = ""
        if q.isEmpty {
            searched = false
            Task { await loadBrowse(reset: true) }
            return
        }
        // Local results immediately — offline-first, no login.
        hits = clients.localSearch(q)
        searched = true
        guard let client = clients.recall() else { return }
        busy = hits.isEmpty
        Task { @MainActor in
            do {
                let res = try await client.find(q: q)
                mergeServerHits(res.items.map(RowItem.init))
                degraded = res.degraded
            } catch {
                // Keep local results; a server/auth error must not blank them.
            }
            busy = false
        }
    }

    private func mergeServerHits(_ server: [RowItem]) {
        var seen = Set(hits.map(\.id))
        for item in server where !seen.contains(item.id) {
            hits.append(item)
            seen.insert(item.id)
        }
    }

    private func loadBrowse(reset: Bool) async {
        if reset { fragments = []; nextCursor = nil; searched = false }
        guard let client = clients.recall() else {
            // Offline / not signed in: browse the local store.
            signedIn = false
            localRows = clients.localRecent(200)
            return
        }
        signedIn = true
        do {
            let page = try await client.recent(cursor: reset ? nil : nextCursor)
            fragments.append(contentsOf: page.items)
            nextCursor = page.nextCursor
            offline = false
            error = ""
        } catch let err {
            // Reachable token but the request failed (server down, or the session
            // could not be refreshed). Surface the error but still load the local
            // store so captures saved on this device stay browsable offline.
            offline = true
            localRows = clients.localRecent(200)
            error = describe(err)
        }
    }

    private func maybeLoadMore(_ row: RowItem) {
        guard !searched, !loadingMore, let cursor = nextCursor,
              row.id == fragments.last?.id else { return }
        loadingMore = true
        Task { @MainActor in
            await loadBrowse(reset: false)
            loadingMore = false
            _ = cursor
        }
    }

    // MARK: - Ask

    private func runAsk() {
        let q = askQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard let client = clients.recall() else { signedIn = false; return }
        busy = true; error = ""
        Task { @MainActor in
            do {
                let res = try await client.ask(question: q)
                answer = res.answer
                sources = res.sources
            } catch let err { error = describe(err) }
            busy = false
        }
    }

    // MARK: - Row actions

    private func edit(_ id: String, _ text: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                _ = try await client.update(id: id, rawText: text)
                if searched { runBrowse() } else { await loadBrowse(reset: true) }
            } catch let err { error = describe(err) }
        }
    }

    // Hide the row now; commit the soft delete after the undo window unless undone.
    private func delete(_ id: String) {
        // Deletion leads with the server soft-delete. Offline / signed out, skip it
        // entirely (matches the pre-undo behaviour): dropping only the local row
        // would hard-delete the sole copy of a local-only / unsynced capture.
        guard clients.recall() != nil else { return }
        error = ""
        // A second delete supersedes the first — commit the earlier one immediately.
        flushPendingDelete()
        pendingDeleteId = id
        pendingDeleteTask = Task { @MainActor in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await commitDelete(id)
        }
    }

    private func undoDelete() {
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingDeleteId = nil
    }

    // Commit the pending deletion right now (a new delete arrived, or the view is
    // tearing down). The detached task keeps the row hidden via pendingDeleteId
    // until commitDelete clears it.
    private func flushPendingDelete() {
        guard let id = pendingDeleteId else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        Task { @MainActor in await commitDelete(id) }
    }

    @MainActor
    private func commitDelete(_ id: String) async {
        guard let client = clients.recall() else {
            // Session lapsed since the delete was queued: never hard-delete the
            // local-only copy — restore the row instead.
            if pendingDeleteId == id { pendingDeleteId = nil; pendingDeleteTask = nil }
            return
        }
        do {
            try await client.delete(id: id)
        } catch let err {
            // Couldn't delete — un-hide the row and surface the error.
            if pendingDeleteId == id { pendingDeleteId = nil; pendingDeleteTask = nil }
            error = describe(err)
            return
        }
        // The server soft-deleted it; also drop the cached local row, or it reappears
        // in offline browse/search (captures saved here keep a local_captures row).
        clients.localDelete(id)
        withAnimation(.easeInOut(duration: 0.2)) {
            fragments.removeAll { $0.id == id }
            hits.removeAll { $0.id == id }
            localRows.removeAll { $0.id == id }
        }
        if pendingDeleteId == id { pendingDeleteId = nil; pendingDeleteTask = nil }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case CaptureAPIError.httpStatus(401): "Session expired — sign in again from Settings."
        case CaptureAPIError.httpStatus(503): "Ask is unavailable — the recall service is offline."
        default: "Error: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let clients: CaptureClients

    init(clients: CaptureClients) { self.clients = clients }

    func show() {
        let w = window ?? makeWindow()
        window = w
        ScreenPlacement.centerOnActiveScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .chronicleMainShown, object: nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        w.title = "Chronicle"
        w.center()
        w.setFrameAutosaveName("ChronicleMainWindow")
        w.isReleasedWhenClosed = false
        // Follow the user to whatever Space (Mission Control desktop) is active
        // instead of yanking them back to the Space where the window was last
        // shown — e.g. a fullscreen app's dedicated Space.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(rootView: MainView(clients: clients))
        return w
    }
}
