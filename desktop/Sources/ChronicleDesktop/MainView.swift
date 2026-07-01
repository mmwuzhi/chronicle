import AppKit
import SwiftUI
import ChronicleDesktopCore

// The resizable main window (ported from rag3's MainView): two modes.
// Browse — empty query shows everything (newest first, paged); typing searches.
// Ask — query-time analysis with cited sources. Rows are editable (double-click)
// and deletable (hover), both wired to the capture API.
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

    // Trash: soft-deleted captures, filtered instantly on the loaded list.
    @State private var trash: [Capture] = []
    @State private var trashQuery = ""
    @State private var confirmingEmptyTrash = false
    // Set to the capture id awaiting a permanent-delete confirmation (irreversible).
    @State private var pendingPermanentDeleteId: String?

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
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                MainTabRail(
                    modes: Mode.allCases,
                    selected: navigation.mode,
                    floating: false,
                    onHover: { navigation.setTabsRailHovering($0) },
                    onSelect: select,
                )
                .frame(width: navigation.tabsExpanded ? MainTabRail.width : 0, alignment: .leading)
                .clipped()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .transaction { transaction in
                    transaction.animation = nil
                }
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
        .animation(navigation.tabsRailPeeking ? nil : .spring(response: 0.3, dampingFraction: 0.92), value: navigation.tabsExpanded)
        .task {
            await loadBrowse(reset: true)
            if navigation.mode == .trash { await loadTrash() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleMainShown)) { _ in
            if navigation.mode == .browse && !searched { Task { await loadBrowse(reset: true) } }
            if navigation.mode == .trash { Task { await loadTrash() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
        .onDisappear { flushPendingDelete() }
    }

    @ViewBuilder private var tabContent: some View {
        switch navigation.mode {
        case .browse, .ask, .trash:
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
            // Per-row permanent delete is irreversible; confirm before hard-deleting,
            // matching Empty Trash and the web flow.
            .confirmationDialog(
                "Delete this capture permanently? This can't be undone.",
                isPresented: Binding(
                    get: { pendingPermanentDeleteId != nil },
                    set: { if !$0 { pendingPermanentDeleteId = nil } },
                ),
                presenting: pendingPermanentDeleteId,
            ) { id in
                Button("Delete Permanently", role: .destructive) { permanentlyDelete(id) }
                Button("Cancel", role: .cancel) {}
            }
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
                WorkspaceField(prompt: "Filter trash", text: $trashQuery, disabled: busy)
                if !trash.isEmpty {
                    Button("Empty", role: .destructive) { confirmingEmptyTrash = true }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                        .confirmationDialog(
                            "Permanently delete all \(trash.count) captures in the trash?",
                            isPresented: $confirmingEmptyTrash, titleVisibility: .visible,
                        ) {
                            Button("Empty Trash", role: .destructive) { emptyTrash() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This can't be undone.")
                        }
                }
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
        } else if navigation.mode == .trash {
            trashContent
        } else if !signedIn {
            signInPrompt
        } else {
            askContent
        }
    }

    // MARK: - Trash

    // Instant keyword filter over the loaded trash — a "find the one I deleted"
    // surface, plain substring, never semantic (so a trashed row can't leak into a
    // recall path). Empty query shows everything.
    private var filteredTrash: [Capture] {
        let q = trashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return trash }
        return trash.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private var trashContent: some View {
        let items = filteredTrash
        if items.isEmpty {
            Text(trashQuery.isEmpty ? "Trash is empty." : "No trashed captures match.")
                .foregroundStyle(.secondary).padding(.top, 8)
        } else {
            ForEach(items) { trashRow($0) }
        }
    }

    @ViewBuilder private func trashRow(_ capture: Capture) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if capture.mediaType != "text" && capture.content.isEmpty {
                Image(systemName: capture.mediaType == "audio" ? "waveform" : "photo")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.content.isEmpty ? "(media capture)" : capture.content)
                    .textSelection(.enabled).lineLimit(6)
                    .foregroundStyle(capture.content.isEmpty ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text("Deleted \(CaptureTime.display(capture.deletedAt ?? capture.createdAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { restore(capture.id) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    Button(role: .destructive) { pendingPermanentDeleteId = capture.id } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        Divider().opacity(0.5)
    }

    private func loadTrash() async {
        guard let client = clients.recall() else { trash = []; return }
        do {
            let items = try await client.trash()
            withAnimation(.easeInOut(duration: 0.2)) { trash = items }
            error = ""
        } catch let err { error = describe(err) }
    }

    // Restore returns the capture (with its links + reminder) to browse. Drop it
    // from the local trash list and let the next browse load pick it back up.
    private func restore(_ id: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                try await client.restore(id: id)
                withAnimation(.easeInOut(duration: 0.2)) { trash.removeAll { $0.id == id } }
            } catch let err { error = describe(err) }
        }
    }

    // Permanent delete is irreversible; the trash is itself the undo buffer, so
    // there's no toast — just drop the row.
    private func permanentlyDelete(_ id: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                try await client.permanentDelete(id: id)
                clients.localDelete(id)
                withAnimation(.easeInOut(duration: 0.2)) { trash.removeAll { $0.id == id } }
            } catch let err { error = describe(err) }
        }
    }

    private func emptyTrash() {
        guard let client = clients.recall() else { return }
        let ids = trash.map(\.id)
        Task { @MainActor in
            do {
                _ = try await client.emptyTrash()
                for id in ids { clients.localDelete(id) }
                withAnimation(.easeInOut(duration: 0.2)) { trash = [] }
            } catch let err { error = describe(err) }
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
            trashQuery = ""
            Task { await loadTrash() }
        case .browse:
            // Returning from the trash: a restore/permanent-delete may have changed
            // the live set, so re-sync browse (unless a search is showing).
            if !searched { Task { await loadBrowse(reset: true) } }
        case .ask:
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
final class MainWindowNavigation: ObservableObject {
    private static let modeKey = "ChronicleMainWindowMode"
    private static let tabsExpandedKey = "ChronicleMainWindowTabsExpanded"

    @Published var mode: MainView.Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    @Published var tabsExpanded: Bool {
        didSet { UserDefaults.standard.set(tabsExpanded, forKey: Self.tabsExpandedKey) }
    }

    @Published private var tabsButtonHovering = false
    @Published private var tabsRailHovering = false
    @Published private var tabsHoverGrace = false
    @Published private var tabsHoverSuppressed = false
    private var tabsHoverGraceTask: Task<Void, Never>?

    var tabsPeeking: Bool {
        tabsHoverSuppressed == false && (tabsButtonHovering || tabsRailHovering || tabsHoverGrace)
    }

    var tabsRailPeeking: Bool {
        tabsHoverSuppressed == false && tabsRailHovering
    }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.modeKey),
           let savedMode = MainView.Mode(rawValue: raw) {
            mode = savedMode
        } else {
            mode = .browse
        }
        if defaults.object(forKey: Self.tabsExpandedKey) == nil {
            tabsExpanded = true
        } else {
            tabsExpanded = defaults.bool(forKey: Self.tabsExpandedKey)
        }
    }

    func setTabsButtonHovering(_ hovering: Bool) {
        if hovering == false {
            tabsHoverSuppressed = false
        }
        setTabsHovering(hovering) { self.tabsButtonHovering = $0 }
    }

    func setTabsRailHovering(_ hovering: Bool) {
        setTabsHovering(hovering) { self.tabsRailHovering = $0 }
    }

    private func setTabsHovering(_ hovering: Bool, assign: @escaping (Bool) -> Void) {
        if hovering {
            tabsHoverGraceTask?.cancel()
            tabsHoverGrace = false
            assign(true)
        } else {
            assign(false)
            holdTabsOpenBriefly()
        }
    }

    private func holdTabsOpenBriefly() {
        guard tabsButtonHovering == false, tabsRailHovering == false else { return }
        tabsHoverGraceTask?.cancel()
        tabsHoverGrace = true
        tabsHoverGraceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard Task.isCancelled == false else { return }
            tabsHoverGrace = false
        }
    }

    func toggleTabsExpanded() {
        tabsExpanded.toggle()
        if tabsExpanded {
            tabsHoverSuppressed = false
        } else {
            tabsHoverGraceTask?.cancel()
            tabsHoverGrace = false
            tabsHoverSuppressed = true
        }
    }
}

private struct MainTabRail: View {
    static let width: CGFloat = 148

    let modes: [MainView.Mode]
    let selected: MainView.Mode
    let floating: Bool
    let onHover: (Bool) -> Void
    let onSelect: (MainView.Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(modes.filter { $0 != .settings }) { mode in
                tabButton(mode)
            }

            Spacer()

            if modes.contains(.settings) {
                tabButton(.settings)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(floating ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(0.025)))
        .overlay(alignment: .trailing) {
            Divider()
        }
        .shadow(color: Color.black.opacity(floating ? 0.12 : 0), radius: floating ? 18 : 0, x: floating ? 8 : 0, y: 0)
        .onHover(perform: onHover)
    }

    private func tabButton(_ mode: MainView.Mode) -> some View {
        let isSelected = selected == mode
        return Button { onSelect(mode) } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(mode.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                           : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 8),
            )
        }
        .buttonStyle(.plain)
        .help(mode.rawValue)
    }
}

@MainActor
final class MainWindowController: NSObject {
    private var window: NSWindow?
    private let clients: CaptureClients
    private let settingsModel: SettingsModel
    private let navigation = MainWindowNavigation()
    private weak var titlebarSidebarButton: NSButton?
    private weak var titlebarTitleLabel: NSTextField?

    init(clients: CaptureClients, settingsModel: SettingsModel) {
        self.clients = clients
        self.settingsModel = settingsModel
        super.init()
    }

    func show(mode: MainView.Mode? = nil) {
        if let mode {
            navigation.mode = mode
            if mode == .settings { settingsModel.refreshPending() }
        }
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
        w.titleVisibility = .hidden
        w.center()
        w.setFrameAutosaveName("ChronicleMainWindow")
        w.isReleasedWhenClosed = false
        // Follow the user to whatever Space (Mission Control desktop) is active
        // instead of yanking them back to the Space where the window was last
        // shown — e.g. a fullscreen app's dedicated Space.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(
            rootView: MainView(clients: clients, navigation: navigation, settingsModel: settingsModel),
        )
        installTitlebarControls(on: w)
        return w
    }

    private func installTitlebarControls(on window: NSWindow) {
        guard titlebarSidebarButton == nil,
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = zoomButton.superview
        else { return }
        let button = HoverSidebarButton(
            image: sidebarImage(),
            target: self,
            action: #selector(toggleSidebarTabs),
        )
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs"
        button.onHoverChange = { [weak self] hovering in
            self?.navigation.setTabsButtonHovering(hovering)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 20),
            button.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        titlebarSidebarButton = button

        let titleLabel = NSTextField(labelWithString: "Chronicle")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebar.trailingAnchor, constant: -16),
        ])
        titlebarTitleLabel = titleLabel
    }

    @objc private func toggleSidebarTabs() {
        navigation.toggleTabsExpanded()
        titlebarSidebarButton?.image = sidebarImage()
        titlebarSidebarButton?.toolTip = navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs"
    }

    private func sidebarImage() -> NSImage {
        NSImage(
            systemSymbolName: navigation.tabsExpanded ? "sidebar.left" : "sidebar.right",
            accessibilityDescription: navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs",
        ) ?? NSImage()
    }
}

private final class HoverSidebarButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
