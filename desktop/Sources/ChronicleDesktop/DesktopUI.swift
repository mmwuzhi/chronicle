import AppKit
import SwiftUI
import ChronicleDesktopCore

// Shared SwiftUI building blocks for the three desktop surfaces (quick-capture
// panel, main window, settings). Visual language ported from rag3: Divider rows,
// hover-only borderless icon buttons, caption/secondary hierarchy. No cards, no
// decorative shadows — the same quiet treatment across every surface.

// MARK: - Clients

/// Fresh API clients built from the current signed-in config, or nil when not
/// signed in. Views call these per request so a sign-in mid-session is picked up.
@MainActor
final class CaptureClients {
    let recall: () -> RecallAPIClient?
    let webhook: () -> WebhookAPIClient?
    let openSettings: () -> Void
    // Open the single-capture detail window focused on the given row.
    let openDetail: (RowItem) -> Void
    // Pin / unpin a capture as a desktop sticky, and read whether one is pinned.
    let togglePin: (RowItem) -> Void
    let isPinned: (String) -> Bool
    // Offline-first local store access — always available, no login required.
    let localSearch: (String) -> [RowItem]
    // On-device semantic recall over the local cache (local Ollama). Returns []
    // when the embedder is unavailable, so callers merge it on top of localSearch.
    let localSemanticSearch: (String) async -> [RowItem]
    let localRecent: (Int) -> [RowItem]
    // Drop a capture's cached local row after it is deleted on the server, keyed
    // by the row id (server id, or local id for an unsynced row).
    let localDelete: (String) -> Void

    init(
        recall: @escaping () -> RecallAPIClient?,
        webhook: @escaping () -> WebhookAPIClient?,
        openSettings: @escaping () -> Void,
        openDetail: @escaping (RowItem) -> Void = { _ in },
        togglePin: @escaping (RowItem) -> Void = { _ in },
        isPinned: @escaping (String) -> Bool = { _ in false },
        localSearch: @escaping (String) -> [RowItem],
        localSemanticSearch: @escaping (String) async -> [RowItem] = { _ in [] },
        localRecent: @escaping (Int) -> [RowItem],
        localDelete: @escaping (String) -> Void
    ) {
        self.recall = recall
        self.webhook = webhook
        self.openSettings = openSettings
        self.openDetail = openDetail
        self.togglePin = togglePin
        self.isPinned = isPinned
        self.localSearch = localSearch
        self.localSemanticSearch = localSemanticSearch
        self.localRecent = localRecent
        self.localDelete = localDelete
    }
}

// MARK: - Row model

/// One renderable row, projected from either a search hit (RecallItem) or a
/// browsed capture (Capture) so the list rendering is shared.
struct RowItem: Identifiable, Equatable {
    let id: String
    let content: String
    let createdAt: String
    // createdAt parsed once at construction — merge/sort comparators run per
    // pair, so parsing there re-parses the same strings hundreds of times.
    let createdDate: Date?
    let modality: String
    // True when this row is backed by a server capture (its id is a real server id).
    // Server-only actions can gate on this; desktop pins are allowed for local rows
    // because the sticky persists the capture content and can render offline.
    let synced: Bool
    // Remote media URL (R2) for image/audio captures, when known. Search hits and
    // local records don't carry it (nil); a desktop sticky fills it in on refresh
    // from GET /captures/{id} so it can show an image thumbnail.
    let mediaUrl: String?

    init(_ hit: RecallItem) {
        id = hit.id
        content = hit.content
        createdAt = hit.createdAt
        createdDate = CaptureTime.parse(hit.createdAt)
        modality = hit.modality
        synced = true
        mediaUrl = nil
    }

    init(_ capture: Capture) {
        id = capture.id
        content = capture.content
        createdAt = capture.createdAt
        createdDate = CaptureTime.parse(capture.createdAt)
        modality = capture.mediaType
        synced = true
        mediaUrl = capture.mediaUrl
    }

    init(_ related: RelatedCapture) {
        id = related.id
        content = related.content
        createdAt = related.createdAt
        createdDate = CaptureTime.parse(related.createdAt)
        modality = related.modality
        synced = true
        mediaUrl = nil
    }

    // Build a row from a pinned sticky's cached fields, so double-clicking a sticky
    // can open the capture's detail window.
    init(id: String, content: String, createdAt: String, modality: String, mediaUrl: String?) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.createdDate = CaptureTime.parse(createdAt)
        self.modality = modality
        self.synced = true
        self.mediaUrl = mediaUrl
    }

    // From a local record. A synced record keys on its server id so it dedupes
    // against the same capture's server search hit; an unsynced one keeps its
    // local id (it exists only on this device until it syncs).
    init(_ record: LocalCaptureRecord) {
        id = record.serverId ?? record.id
        content = record.payload.rawText
        createdAt = RowItem.iso.string(from: record.createdAt)
        createdDate = record.createdAt
        modality = record.payload.mediaType
        synced = record.serverId != nil
        mediaUrl = nil
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct CaptureEditDraft: Equatable {
    var item: RowItem
    var text: String

    init(item: RowItem) {
        self.item = item
        self.text = item.content
    }

    var id: String { item.id }
    var originalText: String { item.content }
    var isDirty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != originalText
    }
}

enum CaptureDeletePlan: Equatable {
    case serverThenLocal(id: String)
    case localOnly(id: String)
    case unavailable
}

func captureDeletePlan(for row: RowItem, hasServerClient: Bool) -> CaptureDeletePlan {
    if row.synced {
        return hasServerClient ? .serverThenLocal(id: row.id) : .unavailable
    }
    return .localOnly(id: row.id)
}

// MARK: - Errors

/// One user-facing line for a capture-API failure, shared by every surface
/// (main window, quick panel, trash) so wording stays consistent.
func describeCaptureError(_ error: Error) -> String {
    switch error {
    case CaptureAPIError.httpStatus(401): "Session expired — sign in again from Settings."
    case CaptureAPIError.httpStatus(503): "Ask is unavailable — the recall service is offline."
    default: "Error: \(error.localizedDescription)"
    }
}

// MARK: - Recall mode

enum RecallMode: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case search = "Search"
    case ask = "Ask"

    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .capture: "Capture a thought…"
        case .search: "Search captures…"
        case .ask: "Ask a question…"
        }
    }

    var shortcutHint: String {
        switch self {
        case .capture: "⌘1"
        case .search: "⌘2"
        case .ask: "⌘3"
        }
    }

    var sendHint: String {
        switch self {
        case .capture: "⌘↩ Save"
        case .search: "↩ Search"
        case .ask: "↩ Ask"
        }
    }
}

// MARK: - Timestamps

enum CaptureTime {
    // ISO8601DateFormatter is thread-safe for parsing; the unsafe annotation just
    // opts this immutable cached instance out of Swift 6's global-state check.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ value: String) -> Date? {
        iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Compact relative stamp ("3m", "2h", "Jun 6") for the resting row state.
    static func display(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        if secs < 604800 { return "\(Int(secs / 86400))d" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// Exact stamp, revealed on hover (avoids the system tooltip's delay).
    static func precise(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Capture row

/// Row hover geometry shared by every list surface (browse, quick panel, trash,
/// detail) so rows speak one hover language: no dividers, a rounded wash marks
/// the row under the cursor and visually claims its trailing actions.
enum RowStyle {
    static let washOpacity = 0.05
    static let cornerRadius: CGFloat = 8
    static let horizontalInset: CGFloat = 10
}

/// Rounded hover wash for list rows that don't go through CaptureRow (the trash
/// pane's custom rows). CaptureRow inlines the same treatment because it already
/// tracks hover for its actions and timestamp.
struct RowHoverWash: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RowStyle.horizontalInset)
            .background(
                Color.primary.opacity(hovering ? RowStyle.washOpacity : 0),
                in: RoundedRectangle(cornerRadius: RowStyle.cornerRadius),
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHoverWash() -> some View { modifier(RowHoverWash()) }
}

/// One icon action in a row's trailing slot: fixed 24×22 footprint, its own
/// hover/pressed wash, and no hit testing while hidden (an invisible button
/// must not swallow clicks on the empty space beside a row).
private struct RowActionButton: View {
    let systemImage: String
    let help: String
    var tint: Color?
    var visible: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
        }
        .buttonStyle(RowActionButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(help)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

private struct RowActionButtonStyle: ButtonStyle {
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 22)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)),
                in: RoundedRectangle(cornerRadius: 6),
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared hover action group for capture rows. Keeping this separate prevents the
/// main window and quick search panel from drifting into different button sets.
struct CaptureRowActions: View {
    var hovering: Bool
    var onCopy: () -> Void
    var onDelete: (() -> Void)?
    var onOpen: (() -> Void)?
    var onUnlink: (() -> Void)?
    var onPin: (() -> Void)?
    var isPinned: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            if let onOpen {
                RowActionButton(systemImage: "arrow.up.forward.square", help: "Open",
                                visible: hovering, action: onOpen)
            }
            if let onPin {
                RowActionButton(systemImage: isPinned ? "pin.fill" : "pin",
                                help: isPinned ? "Unpin from desktop" : "Pin to desktop",
                                tint: isPinned ? Color.accentColor : nil,
                                visible: hovering || isPinned, action: onPin)
            }
            RowActionButton(systemImage: "doc.on.doc", help: "Copy",
                            visible: hovering, action: onCopy)
            if let onDelete {
                RowActionButton(systemImage: "trash", help: "Delete",
                                visible: hovering, action: onDelete)
            }
            if let onUnlink {
                RowActionButton(systemImage: "minus.circle", help: "Remove link",
                                visible: hovering, action: onUnlink)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .frame(width: Self.slotWidth(
            onOpen: onOpen,
            onDelete: onDelete,
            onUnlink: onUnlink,
            onPin: onPin
        ), alignment: .trailing)
    }

    // One fixed slot per visible action so long content never collides with icons.
    static func slotWidth(
        onOpen: (() -> Void)?,
        onDelete: (() -> Void)?,
        onUnlink: (() -> Void)?,
        onPin: (() -> Void)?
    ) -> CGFloat {
        let count = 1 + (onOpen == nil ? 0 : 1) + (onDelete == nil ? 0 : 1)
            + (onUnlink == nil ? 0 : 1) + (onPin == nil ? 0 : 1)
        return CGFloat(count) * 24 + CGFloat(count - 1) * 2
    }
}

/// Row body text: native click-drag selection without surrendering double-click.
/// SwiftUI's `.textSelection` wraps the glyphs in an AppKit host that consumes
/// double-clicks for word selection before any SwiftUI gesture can run, so rows
/// could never open their editor from the text itself. This NSTextView keeps
/// single-click selection and hands `clickCount == 2` to the row's edit action;
/// rows without one (link picker, drafts) keep the native word selection.
struct SelectableRowText: NSViewRepresentable {
    let text: String
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> RowTextView {
        let tv = RowTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: RowTextView, context: Context) {
        tv.onDoubleClick = onDoubleClick
        if tv.string != text { tv.string = text }
    }

    // Measurement must not touch the text view's own container: SwiftUI probes
    // several proposal widths per pass, and whatever width the container was left
    // with would win over the placed width (wrapping at the wrong column). The
    // container tracks the placed frame width instead (widthTracksTextView), and
    // this measures the same wrap statelessly.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: RowTextView, context: Context) -> CGSize? {
        let font = tv.font ?? .preferredFont(forTextStyle: .body)
        let proposed = proposal.width ?? .infinity
        let wrapWidth = proposed.isFinite && proposed > 0 ? proposed : .greatestFiniteMagnitude
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
        ).size
        let width = wrapWidth == .greatestFiniteMagnitude ? ceil(measured.width) : wrapWidth
        return CGSize(width: width, height: ceil(measured.height))
    }

    final class RowTextView: NSTextView {
        var onDoubleClick: (() -> Void)?

        // The main window may not be key (quick panel, stickies); without this the
        // first click only activates the window and selection needs a second try.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            super.mouseDown(with: event)
        }
    }
}

/// One capture/hit row: content, timestamp, hover-revealed shared actions, and
/// double-click-to-edit (when `onEdit` is provided). Matches rag's row geometry:
/// fixed right-hand action slot so long content never collides with the icons.
struct CaptureRow: View {
    let item: RowItem
    var onCopy: () -> Void
    var onDelete: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onOpen: (() -> Void)?
    // Remove an explicit link to this row. Distinct from onDelete: it severs the
    // relation, it does not delete the capture (so it never shows a trash icon).
    var onUnlink: (() -> Void)?
    // Pin / unpin this capture as a desktop sticky. When pinned the icon stays lit
    // even without hover, so the list shows at a glance what is on the desktop.
    var onPin: (() -> Void)?
    var isPinned: Bool = false
    var isEditing: Bool = false
    var draftText: String = ""
    var showsUnsavedPrompt: Bool = false
    var onBeginEdit: (() -> Void)?
    var onDraftChange: ((String) -> Void)?
    var onCommitEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?
    var onSaveAndContinue: (() -> Void)?
    var onDiscardAndContinue: (() -> Void)?
    var onKeepEditing: (() -> Void)?

    @State private var hovering = false
    @State private var fallbackEditing = false
    @State private var fallbackText = ""
    @FocusState private var draftFocused: Bool

    private var rowIsEditing: Bool {
        isEditing || fallbackEditing
    }

    private var currentDraftText: String {
        isEditing ? draftText : fallbackText
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { currentDraftText },
            set: { text in
                if isEditing {
                    onDraftChange?(text)
                } else {
                    fallbackText = text
                }
            }
        )
    }

    private var canSaveDraft: Bool {
        let next = currentDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !next.isEmpty && next != original
    }

    var body: some View {
        Group {
            if rowIsEditing {
                editContainer
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if item.modality != "text" && item.content.isEmpty {
                        Image(systemName: item.modality == "audio" ? "waveform" : "photo")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        restingContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // simultaneousGesture, not onTapGesture: the selectable Text
                    // consumes double-clicks for word selection on macOS, so a
                    // plain tap gesture on it never fires.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditingFromContent() })

                    CaptureRowActions(
                        hovering: hovering,
                        onCopy: onCopy,
                        onDelete: onDelete,
                        onOpen: onOpen,
                        onUnlink: onUnlink,
                        onPin: onPin,
                        isPinned: isPinned,
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        // The edit bubble carries its own inset; resting rows take the shared one
        // so the hover wash lines up across surfaces.
        .padding(.horizontal, rowIsEditing ? 0 : RowStyle.horizontalInset)
        .contentShape(Rectangle())
        .background(
            Color.primary.opacity(hovering && !rowIsEditing ? RowStyle.washOpacity : 0),
            in: RoundedRectangle(cornerRadius: RowStyle.cornerRadius),
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var restingContent: some View {
        if item.content.isEmpty {
            Text("(media capture)")
                .foregroundStyle(.secondary)
        } else {
            SelectableRowText(
                text: item.content,
                onDoubleClick: onEdit != nil ? { beginEditingFromContent() } : nil,
            )
        }
        // Resting metadata stays tertiary; the precise stamp firms up to secondary
        // on hover because that's the moment the user is actually reading it.
        Text(hovering ? CaptureTime.precise(item.createdAt)
                      : CaptureTime.display(item.createdAt))
            .font(.caption2)
            .foregroundStyle(hovering ? HierarchicalShapeStyle.secondary : .tertiary)
    }

    private var editContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: draftBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($draftFocused)

            if showsUnsavedPrompt {
                unsavedPrompt
            }

            HStack(spacing: 8) {
                Spacer(minLength: 12)
                Button { cancelDraft() } label: {
                    CaptureDraftButtonLabel(title: "Cancel", shortcut: "esc")
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
                Button { commitDraft() } label: {
                    CaptureDraftButtonLabel(title: "Save", shortcut: "⌘↩")
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(CaptureDraftButtonStyle(kind: .primary))
                    .disabled(!canSaveDraft)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .onAppear { draftFocused = true }
    }

    private var unsavedPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.accentColor)
            Text("Unsaved changes")
                .font(.caption.weight(.medium))
            Spacer(minLength: 12)
            Button("Keep editing") { onKeepEditing?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
            Button("Discard") { onDiscardAndContinue?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
            Button("Save") { onSaveAndContinue?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .primary))
                .disabled(!canSaveDraft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commitDraft() {
        if isEditing {
            onCommitEdit?()
            return
        }
        let next = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackEditing = false
        guard !next.isEmpty, next != item.content else { return }
        onEdit?(next)
    }

    private func beginEditingFromContent() {
        guard onEdit != nil, !rowIsEditing, !item.content.isEmpty else { return }
        if let onBeginEdit {
            onBeginEdit()
        } else {
            fallbackText = item.content
            fallbackEditing = true
        }
    }

    private func cancelDraft() {
        if isEditing {
            onCancelEdit?()
            return
        }
        fallbackEditing = false
    }
}

private struct CaptureDraftButtonLabel: View {
    var title: String
    var shortcut: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut)
                .font(.system(size: 11, weight: .medium))
                .opacity(0.58)
        }
    }
}

struct CaptureDraftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch kind {
        case .primary:
            Color.primary.opacity(isPressed ? 0.78 : 0.92)
        case .secondary:
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

// MARK: - Undo delete toast

/// Transient confirmation shown after a row is deleted, offering a few seconds to
/// undo before the soft delete actually commits. The visible button is the primary
/// action; ⌘Z is wired alongside it by the host view.
struct UndoDeleteToast: View {
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Capture deleted").font(.callout)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .font(.callout.weight(.medium))
            Text("⌘Z").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

// MARK: - Shared mode switcher

/// Accent-pill mode switcher shared by the quick panel and the main window, so
/// both surfaces speak one control language even though their materials differ
/// (glass overlay vs solid workspace). Stateless: it renders the current
/// selection and reports taps, leaving each caller's own switch side effects
/// (focus, cancel in-flight, reload) intact.
struct PillModePicker<ID: Hashable>: View {
    let segments: [(id: ID, title: String, hint: String?)]
    let selected: ID
    let onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(segments, id: \.id) { seg in
                Button { onSelect(seg.id) } label: {
                    HStack(spacing: 4) {
                        Text(seg.title).font(.system(size: 12, weight: .medium))
                        if let hint = seg.hint {
                            Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(selected == seg.id ? Color.primary : Color.secondary)
                    .background(
                        selected == seg.id ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                           : AnyShapeStyle(Color.clear),
                        in: Capsule(),
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Borderless, lightly-filled input shared by the solid main window and the
/// settings forms. Mirrors the quick panel's chrome-free input (no system bezel)
/// while keeping a faint fill so the field still reads against an opaque
/// workspace. `icon` marks search/filter fields with a leading symbol; `compact`
/// is the denser form-row size; `secure` swaps in a SecureField for passwords.
struct WorkspaceField: View {
    var icon: String?
    let prompt: String
    @Binding var text: String
    var secure: Bool = false
    var compact: Bool = false
    var onSubmit: () -> Void = {}
    var disabled: Bool = false

    private var radius: CGFloat { compact ? 8 : 10 }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(.tertiary)
            }
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 6 : 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1),
        )
        .onSubmit(onSubmit)
        .disabled(disabled)
    }
}

// MARK: - Multi-line input (ported from rag3)

/// Three-mode multi-line input. Key semantics by mode:
/// - submitsOnEnter (search/ask): Enter executes, Shift+Enter inserts a newline.
/// - capture (submitsOnEnter == false): Enter inserts a newline, send is ⌘Enter.
/// IME-safe: during composition AppKit doesn't call insertNewline:, so a bare
/// Enter while picking candidates never submits.
struct ModeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder: String
    var submitsOnEnter: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onCancel = onCancel
        tv.submitsOnEnter = submitsOnEnter
        tv.string = text
        tv.placeholderString = placeholder
        tv.font = .systemFont(ofSize: 16)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 5
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SubmitTextView else { return }
        tv.onSubmit = onSubmit
        tv.onCancel = onCancel
        tv.submitsOnEnter = submitsOnEnter
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        if tv.placeholderString != placeholder {
            tv.placeholderString = placeholder
            tv.needsDisplay = true
        }
        let cw = scroll.frame.width - 16
        if cw > 0, let tc = tv.textContainer, abs(tc.size.width - cw) > 0.5 {
            tc.containerSize = NSSize(width: cw, height: CGFloat.greatestFiniteMagnitude)
            tv.frame.size.width = cw
            context.coordinator.reportHeight()
        }
        if focused, let win = tv.window, win.firstResponder !== tv {
            win.makeFirstResponder(tv)
        }
        context.coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ModeTextEditor
        weak var textView: SubmitTextView?
        private var lastHeight: CGFloat = 0

        init(_ p: ModeTextEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            reportHeight()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer
            else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            guard abs(h - lastHeight) > 0.5 else { return }
            lastHeight = h
            parent.onHeight(h)
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var submitsOnEnter = true
    var placeholderString = ""

    override func insertNewline(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if submitsOnEnter && !shift {
            onSubmit?()
        } else {
            super.insertNewline(sender)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .systemFont(ofSize: 16),
        ]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        placeholderString.draw(at: NSPoint(x: x, y: textContainerInset.height), withAttributes: attrs)
    }
}

// MARK: - Multi-display window placement

/// Opens windows on the display the user is actually working on. Every show path
/// used to anchor to the window's *previous* screen (`window.center()` reads
/// `window.screen`; the main/settings windows never repositioned at all), so once
/// shown on screen A a window always jumped back to A. These helpers resolve the
/// screen under the cursor at show time instead.
@MainActor
enum ScreenPlacement {
    /// The display the cursor is on, falling back to the key window's screen, then
    /// the main screen.
    static func active() -> NSScreen? {
        let frames = NSScreen.screens.map(\.frame)
        if let i = PanelLayout.screenIndex(containing: NSEvent.mouseLocation, screenFrames: frames) {
            return NSScreen.screens[i]
        }
        return NSApp.keyWindow?.screen ?? NSScreen.main
    }

    /// Center `window` on the active screen, but only when it isn't already on it —
    /// so a window the user placed on the current screen stays put, while a stale
    /// window on another display follows them over.
    static func centerOnActiveScreen(_ window: NSWindow) {
        guard let screen = active(), window.screen !== screen else { return }
        window.setFrameOrigin(
            PanelLayout.centeredOrigin(in: screen.visibleFrame, size: window.frame.size),
        )
    }
}
