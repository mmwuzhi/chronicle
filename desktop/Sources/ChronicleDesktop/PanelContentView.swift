import AppKit
import Combine
import SwiftUI
import ChronicleDesktopCore

func panelResultsHeight(
    busy: Bool,
    needsSignIn: Bool,
    hasError: Bool,
    isSearch: Bool,
    searched: Bool,
    hitCount: Int,
    recentLoaded: Bool,
    recentCount: Int,
    degraded: Bool,
    hiddenCount: Int,
    hasAnswer: Bool,
) -> CGFloat {
    if busy || needsSignIn || hasError { return 52 }
    let emptyCaptionHeight: CGFloat = 40
    let searchControlsHeight: CGFloat = isSearch && searched
        ? (degraded ? 18 : 0) + (hiddenCount > 0 ? 24 : 0)
        : 0
    if isSearch && searched && hitCount == 0 {
        return min(emptyCaptionHeight + searchControlsHeight, 320)
    }
    if isSearch && !searched && recentLoaded && recentCount == 0 {
        return emptyCaptionHeight
    }
    let rowCount = searched ? hitCount : recentCount
    let body = CGFloat(rowCount) * 48 + (hasAnswer ? 120 : 0)
    return min(max(body + searchControlsHeight + 20, 52), 320)
}

// The double-tap-Control quick panel, Claude-desktop style (ported from rag3):
// one input row up top, a pill toolbar (mode + send hint) below, and a results
// area that grows downward ONLY when there is something to show. Search starts
// with a small recent-captures preview; Ask stays collapsed until it has work.
struct PanelContentView: View {
    let clients: CaptureClients
    @ObservedObject private var localization = DesktopLocalization.shared
    // text, reminder time (nil = none), keepVisible (notify-only: stay in browse).
    let onSubmit: (String, Date?, Bool) -> QuickCaptureSaveResult
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void
    let onCancelHandlerChange: (@escaping () -> Void) -> Void

    @State private var mode: RecallMode = .capture
    @State private var texts: [RecallMode: String] = [.capture: "", .search: "", .ask: ""]
    @State private var focused = false
    @State private var inputHeight: CGFloat = 22

    @State private var hits: [RowItem] = []
    @State private var searched = false
    @State private var recentRows: [RowItem] = []
    @State private var recentLoaded = false
    @State private var degraded = false
    @State private var hiddenCount = 0
    @State private var includeDismissed = false
    @State private var activeSearchQuery = ""
    @State private var answer = ""
    @State private var sources: [AskSource] = []
    @State private var busy = false
    @State private var error = ""
    @State private var needsSignIn = false
    @State private var inFlight: Task<Void, Never>?
    @State private var pinTick = 0

    @State private var remindOn = false
    @State private var remindAt = Date().addingTimeInterval(3600)
    // Notify-only: keep the capture in browse instead of hiding it until due.
    @State private var remindKeepVisible = false

    private static let recentPreviewLimit = 8

    private var text: String { texts[mode] ?? "" }
    private var textBinding: Binding<String> {
        Binding(
            get: { texts[mode] ?? "" },
            set: {
                texts[mode] = $0
                if mode == .capture {
                    error = ""
                }
            }
        )
    }
    private var offersTodoSuggestion: Bool {
        mode == .capture && CaptureTodoTag.offersSuggestion(for: text)
    }

    private var expanded: Bool {
        searched || (mode == .search && recentLoaded) || !answer.isEmpty
            || busy || !error.isEmpty || needsSignIn
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ModeTextEditor(
                    text: textBinding, focused: $focused,
                    placeholder: mode.placeholder,
                    submitsOnEnter: mode != .capture,
                    onSubmit: submit, onCancel: escape,
                    onHeight: { h in inputHeight = min(max(h, 22), 120) },
                    hasCompletion: offersTodoSuggestion,
                    onComplete: completeTodoSuggestion,
                )
                .frame(height: inputHeight)

                if offersTodoSuggestion {
                    Button(action: completeTodoSuggestion) {
                        HStack(spacing: 8) {
                            TodoFacetChip(state: .open)
                            Text(L("Mark this capture as a todo"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L("Tab"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if mode == .capture && remindOn {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(Color.chronicleAccent)
                    DatePicker("", selection: $remindAt, in: Date()...)
                        .labelsHidden().datePickerStyle(.field).controlSize(.small)
                    Spacer()
                    Toggle(L("Keep visible"), isOn: $remindKeepVisible)
                        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                        .help(L("Notify only — the capture stays in browse instead of hiding until due"))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            toolbar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if expanded {
                Divider().padding(.horizontal, 12)
                resultsArea
            }
        }
        .frame(width: 540)
        .panelGlass(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { onHeightChange($0) }
        .background(shortcutButtons)
        .onAppear {
            onCancelHandlerChange(escape)
            DispatchQueue.main.async { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePanelShown)) { _ in
            reset()
        }
        .onChange(of: expanded) { _ in
            onCancelHandlerChange(escape)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            inFlight?.cancel()
            inFlight = nil
            texts[.search] = ""
            texts[.ask] = ""
            collapseResults()
            includeDismissed = false
            activeSearchQuery = ""
        }
        // In the body (not at the hosting site): the controller's hosting view is
        // typed NSHostingView<PanelContentView>, which a modifier there would break.
        .tint(.chronicleAccent)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            PillModePicker(
                segments: RecallMode.allCases.map { (id: $0, title: $0.title, hint: $0.shortcutHint) },
                selected: mode,
                onSelect: { switchMode(to: $0) },
            )
            Spacer()
            if mode == .capture {
                Button { remindOn.toggle() } label: {
                    Image(systemName: remindOn ? "bell.fill" : "bell")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(remindOn ? Color.chronicleAccent : .secondary)
                .help(L("Set a reminder"))
            }
            Text(mode.sendHint).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var shortcutButtons: some View {
        Group {
            Button("") { switchMode(to: .capture) }.keyboardShortcut("1", modifiers: .command)
            Button("") { switchMode(to: .search) }.keyboardShortcut("2", modifiers: .command)
            Button("") { switchMode(to: .ask) }.keyboardShortcut("3", modifiers: .command)
            Button("") { submit() }.keyboardShortcut(.return, modifiers: .command)
        }
        .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: - Results

    private var resultsArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                resultsContent
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: resultsHeight)
    }

    private var resultsHeight: CGFloat {
        panelResultsHeight(
            busy: busy,
            needsSignIn: needsSignIn,
            hasError: !error.isEmpty,
            isSearch: mode == .search,
            searched: searched,
            hitCount: hits.count,
            recentLoaded: recentLoaded,
            recentCount: recentRows.count,
            degraded: degraded,
            hiddenCount: hiddenCount,
            hasAnswer: !answer.isEmpty,
        )
    }

    @ViewBuilder private var resultsContent: some View {
        if needsSignIn {
            signInPrompt(mode == .ask ? L("Sign in to ask across your captures.")
                                      : L("Sign in to search your captures."))
        } else if busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(mode == .ask ? L("Thinking…") : L("Searching…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 4)
        } else if !error.isEmpty {
            Text(error).foregroundStyle(.red).font(.caption)
        } else if mode == .search && searched {
            if degraded {
                Text(L("⚠︎ Semantic search unavailable — keyword results."))
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            if hits.isEmpty {
                Text(L("No matches.")).font(.caption).foregroundStyle(.secondary)
            }
            if hiddenCount > 0 {
                Button(includeDismissed ? L("Hide dismissed results") : DesktopLocalization.shared.format(
                    "Show %d hidden results", hiddenCount
                )) {
                    includeDismissed.toggle()
                    runFind(activeSearchQuery)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            }
            ForEach(hits) { hit in
                searchRow(hit)
            }
        } else if mode == .search && recentLoaded {
            if recentRows.isEmpty {
                Text(L("No recent captures.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Recent")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(recentRows) { row in
                    searchRow(row)
                }
            }
        } else if mode == .ask && !answer.isEmpty {
            answerView
        }
    }

    private func searchRow(_ row: RowItem) -> some View {
        let isPinned = clients.isPinned(row.id)
        _ = pinTick
        return CaptureRow(
            item: row,
            onDelete: { delete(row) },
            onEdit: nil,
            onOpen: { clients.openDetail(row) },
            onDismiss: searched && row.synced ? {
                setSearchDismissed(row, dismissed: !row.dismissed)
            } : nil,
            dismissTitle: row.dismissed
                ? L("Restore result") : L("Not relevant for this search"),
            dismissSystemImage: row.dismissed ? "arrow.uturn.backward" : "eye.slash",
            onPin: {
                clients.togglePin(row)
                pinTick &+= 1
            },
            isPinned: isPinned,
            onBeginEdit: { clients.openDetailForEditing(row) },
        )
    }

    @ViewBuilder private var answerView: some View {
        HStack {
            Spacer()
            Button { copy(answer) } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
        SelectableRowText(text: answer, onCancel: escape)
            .frame(maxWidth: .infinity, alignment: .leading)
        if !sources.isEmpty {
            Divider().padding(.vertical, 4)
            Text(L("Sources")).font(.caption).foregroundStyle(.secondary)
            ForEach(sources) { s in
                HStack(alignment: .top, spacing: 6) {
                    Text("[\(s.n)]").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    SelectableRowText(
                        text: s.content,
                        onCancel: escape,
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                        maximumNumberOfLines: 2,
                    )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func signInPrompt(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button(L("Sign in")) { clients.openSignIn() }
                .buttonStyle(.link).font(.callout)
            Spacer()
        }
    }

    // MARK: - Actions

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { return }
        switch mode {
        case .capture:
            guard !q.isEmpty else { return }
            let result = onSubmit(
                q,
                remindOn ? remindAt : nil,
                remindOn ? remindKeepVisible : false
            )
            guard result.shouldDismiss else {
                error = result.errorMessage ?? L("We couldn't save this Capture. Try again.")
                focused = true
                return
            }
            texts[.capture] = ""
            remindOn = false
            remindKeepVisible = false
            error = ""
            onClose()
        case .search:
            guard !q.isEmpty else {
                loadRecentPreview()
                return
            }
            runFind(q.replacingOccurrences(of: "\n", with: " "))
        case .ask:
            guard !q.isEmpty else { return }
            runAsk(q.replacingOccurrences(of: "\n", with: " "))
        }
    }

    private func completeTodoSuggestion() {
        texts[.capture] = CaptureTodoTag.completingSuggestion(
            in: texts[.capture] ?? ""
        )
        focused = true
    }

    private func runFind(_ query: String) {
        let generation = clients.session.snapshot()
        inFlight?.cancel()
        let nextIncludeDismissed = query == activeSearchQuery ? includeDismissed : false
        collapseResults()
        includeDismissed = nextIncludeDismissed
        activeSearchQuery = query
        let client = clients.recall()
        let localLiteral = clients.localSearch(query)
        let allCachedDismissedIDs = clients.cachedFindDismissedIDs(query)
        let cachedDismissedIDs = includeDismissed
            ? Set<String>() : allCachedDismissedIDs
        // Online, retain unsynced captures and dirty server-backed captures whose
        // local text is newer than the server fragment.
        hits = client == nil
            ? localLiteral.filter { !cachedDismissedIDs.contains($0.id) }
            : RowMerge.localRecallSupplement(
                localLiteral, id: \.id, synced: \.synced, dirty: \.dirty,
                excludedIDs: cachedDismissedIDs)
        searched = true
        // 2) On-device semantic recall runs even signed out. Online, server-ranked
        //    results lead and this layer only contributes unsynced local captures.
        busy = hits.isEmpty
        inFlight = Task { @MainActor in
            let semantic = await clients.localSemanticSearch(query)
            guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
            if let client {
                do {
                    let res = try await client.find(q: query, includeDismissed: true)
                    guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
                    let serverRows = res.items.map(RowItem.init)
                    let dismissedIDs = clients.cachedFindDismissedIDs(query).union(
                        serverRows.filter(\.dismissed).map(\.id))
                    hiddenCount = max(
                        res.hiddenCount ?? serverRows.filter(\.dismissed).count,
                        dismissedIDs.count)
                    let excludedIDs = includeDismissed ? Set<String>() : dismissedIDs
                    let visibleServerRows = RowMerge.visibleRecallResults(
                        serverRows,
                        includeDismissed: includeDismissed,
                        id: \.id,
                        dismissed: \.dismissed,
                        excludedIDs: dismissedIDs)
                    hits = RowMerge.localRecallSupplement(
                        localLiteral, id: \.id, synced: \.synced, dirty: \.dirty,
                        excludedIDs: excludedIDs)
                    mergeHits(visibleServerRows)
                    mergeHits(RowMerge.localRecallSupplement(
                        semantic, id: \.id, synced: \.synced, dirty: \.dirty,
                        excludedIDs: excludedIDs))
                    degraded = res.degraded
                } catch {
                    // Keep local results; a server/auth error must not blank them.
                    let allDismissedIDs = clients.cachedFindDismissedIDs(query)
                    let excludedIDs = includeDismissed ? Set<String>() : allDismissedIDs
                    hits = localLiteral.filter { !excludedIDs.contains($0.id) }
                    mergeHits(semantic.filter { !excludedIDs.contains($0.id) })
                    hiddenCount = allDismissedIDs.count
                }
            } else {
                let excludedIDs = includeDismissed ? Set<String>() : allCachedDismissedIDs
                hits = localLiteral.filter { !excludedIDs.contains($0.id) }
                mergeHits(semantic.filter { !excludedIDs.contains($0.id) })
                hiddenCount = allCachedDismissedIDs.count
            }
            if clients.session.isCurrent(generation) { busy = false }
        }
    }

    // Append hits not already shown, keyed by id, preserving each source's order.
    private func mergeHits(_ more: [RowItem]) {
        hits = RowMerge.preservingOrder(
            existing: hits,
            incoming: more,
            id: \.id,
        ) { current, incoming in
            current.mergeDisplayEvidence(from: incoming)
        }
    }

    private func setSearchDismissed(_ row: RowItem, dismissed: Bool) {
        let q = activeSearchQuery
        guard !q.isEmpty, let client = clients.recall() else { return }
        let generation = clients.session.snapshot()
        inFlight?.cancel()
        inFlight = Task { @MainActor in
            do {
                try await client.setFindResultDismissed(
                    q: q, targetId: row.id, dismissed: dismissed)
                guard !Task.isCancelled, clients.session.isCurrent(generation),
                      q == activeSearchQuery else { return }
                runFind(q)
            } catch let err {
                guard clients.session.isCurrent(generation) else { return }
                error = describeCaptureError(err)
            }
        }
    }

    private func loadRecentPreview() {
        let generation = clients.session.snapshot()
        inFlight?.cancel()
        collapseResults()
        let local = clients.localRecent(Self.recentPreviewLimit)
        recentRows = local
        recentLoaded = !local.isEmpty
        guard let client = clients.recall() else {
            recentLoaded = true
            return
        }
        busy = local.isEmpty
        inFlight = Task { @MainActor in
            do {
                let page = try await client.recent(limit: Self.recentPreviewLimit)
                guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
                recentRows = Array(
                    RowMerge.newestFirst(
                        primary: page.items.map(RowItem.init),
                        secondary: local,
                        id: \.id,
                        date: \.createdDate,
                    ).prefix(Self.recentPreviewLimit))
                recentLoaded = true
                error = ""
            } catch let err {
                if local.isEmpty { error = describeCaptureError(err) }
                recentLoaded = true
            }
            if clients.session.isCurrent(generation) { busy = false }
        }
    }

    private func runAsk(_ question: String) {
        let generation = clients.session.snapshot()
        guard let client = clients.recall() else { needsSignIn = true; collapseResults(); return }
        collapseResults(); busy = true
        inFlight?.cancel()
        inFlight = Task { @MainActor in
            do {
                let res = try await client.ask(question: question)
                guard !Task.isCancelled, clients.session.isCurrent(generation) else { return }
                answer = res.answer.isEmpty ? L("No answer — not enough captures yet.") : res.answer
                sources = res.sources
            } catch let err {
                if !Task.isCancelled, clients.session.isCurrent(generation) {
                    error = describeCaptureError(err)
                }
            }
            if clients.session.isCurrent(generation) { busy = false }
        }
    }

    private func switchMode(to m: RecallMode) {
        guard m != mode else { return }
        inFlight?.cancel()
        mode = m
        collapseResults()
        if m == .search { loadRecentPreview() }
        DispatchQueue.main.async { focused = true }
    }

    private func escape() {
        if expanded { inFlight?.cancel(); collapseResults() } else { onClose() }
    }

    private func collapseResults() {
        hits = []; searched = false; recentRows = []; recentLoaded = false; degraded = false
        hiddenCount = 0
        answer = ""; sources = []; error = ""; needsSignIn = false; busy = false
    }

    private func reset() {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expanded
        if !hasContent {
            mode = .capture
            remindOn = false
            remindKeepVisible = false
            collapseResults()
        }
        DispatchQueue.main.async { focused = true }
    }

    private func delete(_ row: RowItem) {
        let generation = clients.session.snapshot()
        let plan = captureDeletePlan(for: row, hasServerClient: clients.recall() != nil)
        guard plan != .unavailable else { return }
        error = ""
        inFlight?.cancel()
        inFlight = Task { @MainActor in
            let id: String
            do {
                switch plan {
                case .serverThenLocal(let captureId):
                    guard let client = clients.recall() else { return }
                    try await client.delete(id: captureId)
                    guard clients.session.isCurrent(generation) else { return }
                    id = captureId
                case .localOnly(let localId):
                    id = localId
                case .unavailable:
                    return
                }
                guard clients.session.isCurrent(generation) else { return }
                clients.localDelete(id)
                CaptureEvents.postChanged()
            } catch let err {
                guard clients.session.isCurrent(generation) else { return }
                error = describeCaptureError(err)
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                hits.removeAll { $0.id == id }
                recentRows.removeAll { $0.id == id }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

}

struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension Notification.Name {
    /// Posted each time the quick panel is shown (PanelContentView resets to capture).
    static let chroniclePanelShown = Notification.Name("chroniclePanelShown")
    /// Posted each time the main window is shown (MainView refreshes its browse list).
    static let chronicleMainShown = Notification.Name("chronicleMainShown")
    /// Standard New command switches Browse to its Capture composer.
    static let chronicleFocusMainCapture = Notification.Name("chronicleFocusMainCapture")
    /// Posted after captures are created, synced, edited, deleted, or restored so
    /// already-open browse/search surfaces can invalidate their lists.
    static let chronicleCapturesChanged = Notification.Name("chronicleCapturesChanged")
    /// Posted when the set of pinned desktop stickies changes, so capture rows can
    /// re-read their pinned state and update the pin indicator.
    static let chroniclePinsChanged = Notification.Name("chroniclePinsChanged")
}

/// Posts `.chronicleCapturesChanged`, always delivered on the main thread —
/// SwiftUI `onReceive` closures mutate view state.
enum CaptureEvents {
    /// Pass `sender` when the poster also observes the notification, so it can
    /// skip reloading over its own optimistic updates. Main-actor only: the
    /// non-Sendable sender must not hop threads.
    @MainActor
    static func postChanged(from sender: AnyObject) {
        NotificationCenter.default.post(name: .chronicleCapturesChanged, object: sender)
    }

    /// Post from any thread (capture sync runs off-main).
    static func postChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .chronicleCapturesChanged, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .chronicleCapturesChanged, object: nil)
            }
        }
    }
}

extension View {
    // Liquid Glass (`glassEffect`) only exists on macOS 26+, so applying it
    // unconditionally forces the whole app's deployment target up to 26 and locks
    // out every earlier macOS. Guard it and fall back to a translucent material on
    // macOS 13–25, so the panel keeps a frosted backdrop while the package minimum
    // stays at .v13.
    @ViewBuilder
    func panelGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
