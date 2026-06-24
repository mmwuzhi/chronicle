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
    // Offline-first local store access — always available, no login required.
    let localSearch: (String) -> [RowItem]
    let localRecent: (Int) -> [RowItem]
    // Drop a capture's cached local row after it is deleted on the server, keyed
    // by the row id (server id, or local id for an unsynced row).
    let localDelete: (String) -> Void

    init(
        recall: @escaping () -> RecallAPIClient?,
        webhook: @escaping () -> WebhookAPIClient?,
        openSettings: @escaping () -> Void,
        localSearch: @escaping (String) -> [RowItem],
        localRecent: @escaping (Int) -> [RowItem],
        localDelete: @escaping (String) -> Void
    ) {
        self.recall = recall
        self.webhook = webhook
        self.openSettings = openSettings
        self.localSearch = localSearch
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
    let modality: String

    init(_ hit: RecallItem) {
        id = hit.id
        content = hit.content
        createdAt = hit.createdAt
        modality = hit.modality
    }

    init(_ capture: Capture) {
        id = capture.id
        content = capture.content
        createdAt = capture.createdAt
        modality = capture.mediaType
    }

    // From a local record. A synced record keys on its server id so it dedupes
    // against the same capture's server search hit; an unsynced one keeps its
    // local id (it exists only on this device until it syncs).
    init(_ record: LocalCaptureRecord) {
        id = record.serverId ?? record.id
        content = record.payload.rawText
        createdAt = RowItem.iso.string(from: record.createdAt)
        modality = record.payload.mediaType
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
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

/// One capture/hit row: content, timestamp, hover-revealed copy + delete, and
/// double-click-to-edit (when `onEdit` is provided). Matches rag's row geometry:
/// fixed right-hand action slot so long content never collides with the icons.
struct CaptureRow: View {
    let item: RowItem
    var onCopy: () -> Void
    var onDelete: (() -> Void)?
    var onEdit: ((String) -> Void)?

    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.modality != "text" && item.content.isEmpty {
                Image(systemName: item.modality == "audio" ? "waveform" : "photo")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("", text: $editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...10)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                                .padding(.horizontal, -5)
                                .padding(.vertical, -3)
                        }
                    Text("⌘↩ save · esc cancel")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(item.content.isEmpty ? "(media capture)" : item.content)
                        .textSelection(.enabled)
                        .foregroundStyle(item.content.isEmpty ? .secondary : .primary)
                    Text(hovering ? CaptureTime.precise(item.createdAt)
                                  : CaptureTime.display(item.createdAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if editing {
                Group {
                    Button("") { commitEdit() }.keyboardShortcut(.return, modifiers: .command)
                    Button("") { cancelEdit() }.keyboardShortcut(.cancelAction)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0)
            } else {
                HStack(spacing: 8) {
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Copy")
                        .opacity(hovering ? 1 : 0)
                    if let onDelete {
                        Button(action: onDelete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Delete")
                            .opacity(hovering ? 1 : 0)
                    }
                }
                .frame(width: onDelete == nil ? 28 : 52, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard onEdit != nil, !editing, !item.content.isEmpty else { return }
            editText = item.content
            editing = true
        })
        .onHover { hovering = $0 }
    }

    private func commitEdit() {
        let next = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !next.isEmpty, next != item.content else { return }
        onEdit?(next)
    }

    private func cancelEdit() { editing = false }
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
/// workspace. `compact` is the denser form-row size; `secure` swaps in a
/// SecureField for passwords.
struct WorkspaceField: View {
    let prompt: String
    @Binding var text: String
    var secure: Bool = false
    var compact: Bool = false
    var onSubmit: () -> Void = {}
    var disabled: Bool = false

    private var radius: CGFloat { compact ? 8 : 10 }

    var body: some View {
        Group {
            if secure {
                SecureField(prompt, text: $text)
            } else {
                TextField(prompt, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: compact ? 13 : 15))
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 6 : 8)
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
