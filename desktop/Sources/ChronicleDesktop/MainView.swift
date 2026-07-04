import AppKit
import SwiftUI
import ChronicleDesktopCore

// The resizable main window (ported from rag3's MainView): two modes.
// Browse — empty query shows everything (newest first, paged); typing searches.
// Ask — query-time analysis with cited sources. Rows are editable (double-click)
// and deletable (hover), both wired to the capture API.
//
// Split across files: window chrome (navigation model, tab rail, window
// controller) lives in MainWindowChrome.swift; the trash pane in
// MainTrashPane.swift. This file keeps the shell plus browse/search and ask.
struct MainView: View {
    let clients: CaptureClients
    @ObservedObject var navigation: MainWindowNavigation
    @ObservedObject var settingsModel: SettingsModel

    enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse", ask = "Ask", trash = "Trash", settings = "Settings"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .browse: "tray.full"
            case .ask: "sparkles"
            case .trash: "trash"
            case .settings: "gearshape"
            }
        }
    }

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

    // Marks this view's own capture-change posts so onReceive can skip them:
    // every local mutation already updates state optimistically (with removal
    // animations a full reload would stomp); the notification is for the other
    // open surfaces.
    @State private var captureEventToken = NSObject()

    private var rows: [RowItem] {
        let base = searched ? hits : browseRows
        guard let pendingDeleteId else { return base }
        return base.filter { $0.id != pendingDeleteId }
    }

    // Cached merge of local rows and server fragments — SwiftUI re-evaluates
    // `rows` on every render, and merging + sorting 200+ rows per frame is
    // wasted work. Every mutation of fragments/localRows/signedIn/offline must
    // call rebuildBrowseRows() (today: loadBrowse and commitDelete).
    @State private var browseRows: [RowItem] = []

    private func rebuildBrowseRows() {
        guard signedIn && !offline else { browseRows = localRows; return }
        browseRows = RowMerge.newestFirst(
            primary: fragments.map(RowItem.init),
            secondary: localRows,
            id: \.id,
            date: \.createdDate,
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if navigation.tabsExpanded {
                    MainTabRail(
                        modes: Mode.allCases,
                        selected: navigation.mode,
                        floating: false,
                        onHover: { navigation.setTabsRailHovering($0) },
                        onSelect: select,
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if navigation.tabsExpanded == false {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: MainTabRail.edgePeekInset)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(width: MainTabRail.edgePeekWidth)
                        .contentShape(Rectangle())
                        .onHover { navigation.setTabsRailHovering($0) }
                }
                .frame(maxHeight: .infinity)
                .zIndex(2)
            }

            if navigation.tabsPeeking && navigation.tabsExpanded == false {
                MainTabRail(
                    modes: Mode.allCases,
                    selected: navigation.mode,
                    floating: true,
                    onHover: { navigation.setTabsRailHovering($0) },
                    onSelect: select,
                )
                .zIndex(1)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(minWidth: 700, minHeight: 520)
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
        .animation(.easeOut(duration: 0.16), value: navigation.tabsPeeking)
        .animation(navigation.tabsExpandedAnimation, value: navigation.tabsExpanded)
        .task {
            await loadBrowse(reset: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleMainShown)) { _ in
            if navigation.mode == .browse && !searched { Task { await loadBrowse(reset: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleCapturesChanged)) { note in
            guard (note.object as? NSObject) !== captureEventToken else { return }
            refreshForCaptureChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
        .onDisappear { flushPendingDelete() }
    }

    @ViewBuilder private var tabContent: some View {
        switch navigation.mode {
        case .browse, .ask:
            VStack(spacing: 12) {
                contentHeader

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
        case .trash:
            MainTrashPane(clients: clients, captureEventToken: captureEventToken)
        case .settings:
            VStack(spacing: 0) {
                contentHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                Divider()
                SettingsView(model: settingsModel)
            }
        }
    }

    @ViewBuilder private var contentHeader: some View {
        HStack(spacing: 10) {
            switch navigation.mode {
            case .browse:
                WorkspaceField(prompt: "Search (empty = show everything)",
                               text: $query, onSubmit: runBrowse, disabled: busy)
            case .ask:
                WorkspaceField(prompt: "Ask a question, e.g. what did I work on this week",
                               text: $askQuery, onSubmit: runAsk, disabled: busy)
            case .trash:
                // Never rendered — trash mode mounts MainTrashPane, which brings
                // its own filter/Empty header.
                EmptyView()
            case .settings:
                Text("Settings")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if navigation.mode == .browse {
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
                    onPin: { clients.togglePin(row) },
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
            Button("Open Settings") { select(.settings) }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func select(_ next: Mode) {
        navigation.mode = next
        switch next {
        case .settings:
            settingsModel.refreshPending()
        case .trash:
            // MainTrashPane mounts fresh and loads itself.
            break
        case .browse:
            // Returning from the trash: a restore/permanent-delete may have changed
            // the live set, so re-sync browse (unless a search is showing).
            if !searched { Task { await loadBrowse(reset: true) } }
        case .ask:
            break
        }
    }

    private func refreshForCaptureChange() {
        switch navigation.mode {
        case .browse:
            if searched {
                runBrowse()
            } else {
                Task { await loadBrowse(reset: true) }
            }
        case .trash, .ask, .settings:
            // Trash observes capture changes itself while mounted.
            break
        }
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
        // Local substring results immediately — offline-first, no login.
        hits = clients.localSearch(q)
        searched = true
        // On-device semantic recall runs even signed out; server semantic merges
        // on top when signed in. Neither depends on the other.
        let client = clients.recall()
        busy = hits.isEmpty
        Task { @MainActor in
            mergeHits(await clients.localSemanticSearch(q))
            if let client {
                do {
                    let res = try await client.find(q: q)
                    mergeHits(res.items.map(RowItem.init))
                    degraded = res.degraded
                } catch {
                    // Keep local results; a server/auth error must not blank them.
                }
            }
            busy = false
        }
    }

    // Append hits not already shown, keyed by id (local substring, then local
    // semantic, then server).
    private func mergeHits(_ more: [RowItem]) {
        var seen = Set(hits.map(\.id))
        for item in more where !seen.contains(item.id) {
            hits.append(item)
            seen.insert(item.id)
        }
    }

    private func loadBrowse(reset: Bool) async {
        if reset {
            fragments = []
            localRows = clients.localRecent(200)
            nextCursor = nil
            searched = false
        }
        guard let client = clients.recall() else {
            // Offline / not signed in: browse the local store.
            signedIn = false
            rebuildBrowseRows()
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
            error = describeCaptureError(err)
        }
        rebuildBrowseRows()
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
            } catch let err { error = describeCaptureError(err) }
            busy = false
        }
    }

    // MARK: - Row actions

    private func edit(_ id: String, _ text: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                _ = try await client.update(id: id, rawText: text)
                CaptureEvents.postChanged(from: captureEventToken)
                if searched { runBrowse() } else { await loadBrowse(reset: true) }
            } catch let err { error = describeCaptureError(err) }
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
            error = describeCaptureError(err)
            return
        }
        // The server soft-deleted it; also drop the cached local row, or it reappears
        // in offline browse/search (captures saved here keep a local_captures row).
        clients.localDelete(id)
        CaptureEvents.postChanged(from: captureEventToken)
        withAnimation(.easeInOut(duration: 0.2)) {
            fragments.removeAll { $0.id == id }
            hits.removeAll { $0.id == id }
            localRows.removeAll { $0.id == id }
            rebuildBrowseRows()
        }
        if pendingDeleteId == id { pendingDeleteId = nil; pendingDeleteTask = nil }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private extension MainWindowNavigation {
    var tabsExpandedAnimation: Animation? {
        suppressTabsExpandedAnimation || tabsRailPeeking ? nil : .spring(response: 0.3, dampingFraction: 0.92)
    }
}
