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
    @State private var editDraft: CaptureEditDraft?
    @State private var pendingEditTarget: RowItem?

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
    @State private var pendingDeletePlan: CaptureDeletePlan?
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

                if busy && !(navigation.mode == .browse && editDraft != nil) {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    // LazyVStack, not a plain ForEach: browse rows accumulate across
                    // pagination (`maybeLoadMore`) and each row backs its selectable
                    // text with a native NSTextView (see SelectableRowText). Without
                    // laziness every loaded row, on- or off-screen, stays fully
                    // mounted, so any reflow (scroll, sidebar width change) had to
                    // re-lay-out all of them at once.
                    LazyVStack(alignment: .leading, spacing: 8) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
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
                WorkspaceField(icon: "magnifyingglass", prompt: "Search captures…",
                               text: $query, onSubmit: runBrowse, disabled: busy)
            case .ask:
                WorkspaceField(icon: "sparkles",
                               prompt: "Ask a question, e.g. what did I work on this week",
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
            if rows.isEmpty && editDraft == nil && !searched && !busy {
                Text((signedIn && !offline) ? "No captures yet." : "No local captures yet — capture something or sign in to sync.")
                    .foregroundStyle(.secondary).padding(.top, 8)
            }
            // The draft edits in place inside the ForEach. This fallback only
            // renders when the edited row left the list mid-edit (e.g. a new
            // search filtered it out), so the draft can't get lost off-list.
            if let draft = editDraft, !rows.contains(where: { $0.id == draft.id }) {
                editRow(draft)
                    .padding(.bottom, 4)
            }
            if busy && editDraft != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            if searched && rows.isEmpty && !busy {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, editDraft == nil ? 8 : 0)
            }
            ForEach(rows) { row in
                Group {
                    if let draft = editDraft, draft.id == row.id {
                        editRow(draft)
                    } else {
                        CaptureRow(
                            item: row,
                            onCopy: { copy(row.content) },
                            onDelete: { delete(row) },
                            onEdit: { edit(row.id, $0) },
                            onOpen: { clients.openDetail(row) },
                            onPin: { clients.togglePin(row) },
                            isPinned: clients.isPinned(row.id),
                            onBeginEdit: { beginEdit(row) },
                        )
                    }
                }
                .onAppear { maybeLoadMore(row) }
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

    // The one active edit draft, rendered as an edit bubble in the row's own
    // list position (or above the list via the fallback in `content`).
    private func editRow(_ draft: CaptureEditDraft) -> some View {
        CaptureRow(
            item: draft.item,
            onCopy: { copy(draft.text) },
            onDelete: nil,
            onEdit: { _ in },
            onOpen: { clients.openDetail(draft.item) },
            onPin: { clients.togglePin(draft.item) },
            isPinned: clients.isPinned(draft.id),
            isEditing: true,
            draftText: draft.text,
            showsUnsavedPrompt: pendingEditTarget != nil && draft.isDirty,
            onBeginEdit: nil,
            onDraftChange: updateEditDraft,
            onCommitEdit: { commitActiveEdit() },
            onCancelEdit: cancelActiveEdit,
            onSaveAndContinue: saveAndContinuePendingEdit,
            onDiscardAndContinue: discardAndContinuePendingEdit,
            onKeepEditing: keepEditingCurrentDraft,
        )
    }

    // MARK: - Row actions

    private func beginEdit(_ row: RowItem) {
        guard !row.content.isEmpty else { return }
        if let draft = editDraft {
            guard draft.id != row.id else { return }
            if draft.isDirty {
                pendingEditTarget = row
                return
            }
        }
        editDraft = CaptureEditDraft(item: row)
        pendingEditTarget = nil
    }

    private func updateEditDraft(_ text: String) {
        editDraft?.text = text
        if editDraft?.isDirty == false {
            pendingEditTarget = nil
        }
    }

    private func commitActiveEdit() {
        guard let draft = editDraft else { return }
        let next = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        editDraft = nil
        pendingEditTarget = nil
        guard !next.isEmpty, next != draft.originalText else { return }
        edit(draft.id, next)
    }

    private func cancelActiveEdit() {
        editDraft = nil
        pendingEditTarget = nil
    }

    private func saveAndContinuePendingEdit() {
        guard let target = pendingEditTarget else { return }
        let current = editDraft
        editDraft = CaptureEditDraft(item: target)
        pendingEditTarget = nil
        guard let current else { return }
        let next = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != current.originalText else { return }
        edit(current.id, next)
    }

    private func discardAndContinuePendingEdit() {
        guard let target = pendingEditTarget else { return }
        editDraft = CaptureEditDraft(item: target)
        pendingEditTarget = nil
    }

    private func keepEditingCurrentDraft() {
        pendingEditTarget = nil
    }

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
    private func delete(_ row: RowItem) {
        let plan = captureDeletePlan(for: row, hasServerClient: clients.recall() != nil)
        guard plan != .unavailable else { return }
        error = ""
        // A second delete supersedes the first — commit the earlier one immediately.
        flushPendingDelete()
        pendingDeleteId = row.id
        pendingDeletePlan = plan
        pendingDeleteTask = Task { @MainActor in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await commitDelete(plan)
        }
    }

    private func undoDelete() {
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingDeleteId = nil
        pendingDeletePlan = nil
    }

    // Commit the pending deletion right now (a new delete arrived, or the view is
    // tearing down). The detached task keeps the row hidden via pendingDeleteId
    // until commitDelete clears it.
    private func flushPendingDelete() {
        guard let plan = pendingDeletePlan else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        Task { @MainActor in await commitDelete(plan) }
    }

    @MainActor
    private func commitDelete(_ plan: CaptureDeletePlan) async {
        let id: String
        switch plan {
        case .serverThenLocal(let captureId):
            guard let client = clients.recall() else {
                // Session lapsed since the delete was queued: keep the local cache
                // because the server copy was not moved to trash.
                clearPendingDelete(for: captureId)
                return
            }
            do {
                try await client.delete(id: captureId)
            } catch let err {
                // Couldn't delete — un-hide the row and surface the error.
                clearPendingDelete(for: captureId)
                error = describeCaptureError(err)
                return
            }
            id = captureId
        case .localOnly(let localId):
            id = localId
        case .unavailable:
            return
        }
        // The server soft-deleted it; also drop the cached local row, or it reappears
        // in offline browse/search. Local-only rows have no server trash yet, so the
        // deferred local delete is the whole operation.
        clients.localDelete(id)
        CaptureEvents.postChanged(from: captureEventToken)
        withAnimation(.easeInOut(duration: 0.2)) {
            fragments.removeAll { $0.id == id }
            hits.removeAll { $0.id == id }
            localRows.removeAll { $0.id == id }
            rebuildBrowseRows()
        }
        clearPendingDelete(for: id)
    }

    private func clearPendingDelete(for id: String) {
        if pendingDeleteId == id {
            pendingDeleteId = nil
            pendingDeletePlan = nil
            pendingDeleteTask = nil
        }
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
