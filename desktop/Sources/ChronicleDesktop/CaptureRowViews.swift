import AppKit
import SwiftUI
import ChronicleDesktopCore

// The shared capture row and its trailing-action vocabulary, used by browse,
// the quick panel, the detail window, and the link picker.

// MARK: - Row actions

/// One low-contrast icon action in a row's trailing slot with a fixed 24×22
/// footprint and pressed feedback. It intentionally owns no hover state: these
/// buttons live inside virtualized scrolling rows.
private struct RowActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowActionButtonStyle())
        .accessibilityLabel(help)
    }
}

private struct RowActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 22)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 6),
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared, geometry-stable action group for capture rows. A single quiet
/// overflow affordance keeps repeated rows content-first while preserving a
/// discoverable path to every contextual action. It stays visible instead of
/// mutating per-row state as content moves under the pointer during scrolling.
struct CaptureRowActions: View {
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onOpen: (() -> Void)?
    var onUnlink: (() -> Void)?
    var onPin: (() -> Void)?
    var isPinned: Bool = false

    var body: some View {
        if hasActions {
            RowActionMenu(
                onOpen: onOpen,
                onEdit: onEdit,
                onPin: onPin,
                onUnlink: onUnlink,
                onDelete: onDelete,
                isPinned: isPinned,
            )
            .frame(width: 24, alignment: .trailing)
        }
    }

    private var hasActions: Bool {
        onOpen != nil || onEdit != nil || onPin != nil || onUnlink != nil || onDelete != nil
    }
}

/// The ⋯ overflow in a row's trailing slot. It deliberately stays a plain Button:
/// SwiftUI Menu mounts an AppKitPopUpAdaptor/NSPopUpButton, and moving rows through
/// the pointer while scrolling repeatedly creates and destroys that platform view.
/// On macOS 26 this can trap LazyVStack in a non-terminating layout pass. Build the
/// short-lived NSMenu only after a click instead.
private struct RowActionMenu: View {
    @ObservedObject private var localization = DesktopLocalization.shared
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?
    var onUnlink: (() -> Void)?
    var onDelete: (() -> Void)?
    var isPinned: Bool

    var body: some View {
        RowActionButton(systemImage: "ellipsis", help: L("More")) {
            CaptureRowOverflowMenu.present(
                onOpen: onOpen,
                onEdit: onEdit,
                onPin: onPin,
                onUnlink: onUnlink,
                onDelete: onDelete,
                isPinned: isPinned,
            )
        }
    }
}

enum CaptureRowOverflowMenu {
    @MainActor
    static func make(
        onOpen: (() -> Void)?,
        onEdit: (() -> Void)? = nil,
        onPin: (() -> Void)?,
        onUnlink: (() -> Void)?,
        onDelete: (() -> Void)?,
        isPinned: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        if let onOpen {
            menu.addItem(ClosureMenuItem(
                title: L("Open"),
                systemImage: "arrow.up.forward.square",
                action: onOpen,
            ))
        }
        if let onEdit {
            menu.addItem(ClosureMenuItem(
                title: L("Edit"),
                systemImage: "pencil",
                action: onEdit,
            ))
        }
        if let onPin {
            menu.addItem(ClosureMenuItem(
                title: isPinned ? L("Unpin from desktop") : L("Pin to desktop"),
                systemImage: isPinned ? "pin.slash" : "pin",
                action: onPin,
            ))
        }
        if let onUnlink {
            menu.addItem(ClosureMenuItem(
                title: L("Remove link"),
                systemImage: "minus.circle",
                action: onUnlink,
            ))
        }
        if let onDelete {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(
                title: L("Delete"),
                systemImage: "trash",
                destructive: true,
                action: onDelete,
            ))
        }
        return menu
    }

    @MainActor
    static func present(
        onOpen: (() -> Void)?,
        onEdit: (() -> Void)? = nil,
        onPin: (() -> Void)?,
        onUnlink: (() -> Void)?,
        onDelete: (() -> Void)?,
        isPinned: Bool
    ) {
        make(
            onOpen: onOpen,
            onEdit: onEdit,
            onPin: onPin,
            onUnlink: onUnlink,
            onDelete: onDelete,
            isPinned: isPinned,
        )
            .popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class ClosureMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(
            title: String,
            systemImage: String,
            destructive: Bool = false,
            action: @escaping () -> Void
        ) {
            self.handler = action
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            if destructive {
                attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            handler()
        }
    }
}

/// Left-edge accent bar marking a row whose capture is pinned to the desktop.
/// The authoritative display is the sticky itself; with pin folded into the ⋯
/// menu the list only needs this quiet callback — no lit icon, no layout shift.
struct PinnedEdgeBar: View {
    let isPinned: Bool

    var body: some View {
        if isPinned {
            Capsule()
                .fill(Color.chronicleAccent)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
    }
}

/// Compact, geometry-stable metadata for virtualized capture rows.
struct TodoFacetChip: View {
    let state: CaptureTodoState

    var body: some View {
        Text(state == .done ? "#todo ✓" : "#todo")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(
                state == .done
                    ? Color.secondary.opacity(0.7)
                    : Color.chronicleAccent
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                state == .done
                    ? Color.primary.opacity(0.05)
                    : Color.chronicleAccent.opacity(0.12),
                in: Capsule(),
            )
            .accessibilityLabel(state == .done ? L("Done") : L("Todo"))
    }
}

struct CaptureRowMetadata: View {
    @ObservedObject private var localization = DesktopLocalization.shared
    let todoState: CaptureTodoState?
    let createdAt: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let todoState {
                TodoFacetChip(state: todoState)
            }
            Text(hovering ? CaptureTime.precise(createdAt) : CaptureTime.display(createdAt))
                .accessibilityLabel(CaptureTime.precise(createdAt))
                .onHover { hovering = $0 }
        }
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Row body text

/// Selectable body text for non-virtualized recall results. Scrolling capture
/// rows deliberately use pure SwiftUI Text, while the quick panel's answer and
/// sources keep native click-drag selection through this lightweight wrapper.
struct SelectableRowText: NSViewRepresentable {
    let text: String
    var onDoubleClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var maximumNumberOfLines: Int = 0

    func makeNSView(context: Context) -> RowTextView {
        let tv = RowTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = font
        tv.textColor = .labelColor
        tv.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        tv.textContainer?.lineBreakMode = maximumNumberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: RowTextView, context: Context) {
        tv.onDoubleClick = onDoubleClick
        tv.onCancel = onCancel
        tv.font = font
        tv.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        tv.textContainer?.lineBreakMode = maximumNumberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        if tv.string != text { tv.string = text }
    }

    // Measurement must not touch the text view's own container: SwiftUI probes
    // several proposal widths per pass, and whatever width the container was left
    // with would win over the placed width (wrapping at the wrong column). The
    // container tracks the placed frame width instead (widthTracksTextView), and
    // this measures the same wrap statelessly.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: RowTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? .infinity
        let wrapWidth = proposed.isFinite && proposed > 0 ? proposed : .greatestFiniteMagnitude
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
        ).size
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = maximumNumberOfLines > 0
            ? min(ceil(measured.height), lineHeight * CGFloat(maximumNumberOfLines))
            : ceil(measured.height)
        let width = wrapWidth == .greatestFiniteMagnitude ? ceil(measured.width) : wrapWidth
        return CGSize(width: width, height: height)
    }

    final class RowTextView: NSTextView {
        var onDoubleClick: (() -> Void)?
        var onCancel: (() -> Void)?

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

        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                return
            }
            guard let onCancel else { return }
            onCancel()
        }

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == 53, !hasMarkedText(), let onCancel else {
                super.keyDown(with: event)
                return
            }
            onCancel()
        }
    }
}

// MARK: - Capture row

/// One capture/hit row: content, timestamp, stable shared actions, and
/// double-click-to-edit (when an edit path is provided). Content owns the full
/// row width; metadata and overflow actions share the quiet footer line.
struct CaptureRow: View {
    @ObservedObject private var localization = DesktopLocalization.shared
    let item: RowItem
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

    @State private var fallbackEditing = false
    @State private var fallbackText = ""
    @State private var draftFocused = false
    @State private var editorHeight: CGFloat = 22

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
        let original = (item.editableRawText ?? item.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !next.isEmpty && next != original
    }

    var body: some View {
        Group {
            if rowIsEditing {
                editContainer
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if item.modality != "text" && item.displayText.isEmpty {
                        Image(systemName: item.modality == "audio" ? "waveform" : "photo")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        restingContent
                        HStack(alignment: .center, spacing: 6) {
                            CaptureRowMetadata(
                                todoState: item.todoState,
                                createdAt: item.createdAt,
                            )
                            Spacer(minLength: 8)
                            CaptureRowActions(
                                onDelete: onDelete,
                                onEdit: beginEditAction,
                                onOpen: onOpen,
                                onUnlink: onUnlink,
                                onPin: onPin,
                                isPinned: isPinned,
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Keep editing on the whole text column. Resting list text is
                    // deliberately pure SwiftUI so LazyVStack never has to reflow
                    // a platform NSTextView while scrolling.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditingFromContent() })

                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        // The edit bubble carries its own inset; resting rows take the shared one
        // so the hover wash lines up across surfaces.
        .padding(.horizontal, rowIsEditing ? 0 : RowStyle.horizontalInset)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            PinnedEdgeBar(isPinned: isPinned && !rowIsEditing)
        }
    }

    @ViewBuilder
    private var restingContent: some View {
        if item.displayText.isEmpty {
            Text(L("(media capture)"))
                .foregroundStyle(.secondary)
        } else {
            Text(item.displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canBeginEditing: Bool {
        captureRowCanBeginEditing(
            item,
            hasInlineEdit: onEdit != nil,
            hasExternalBegin: onBeginEdit != nil
        )
    }

    private var beginEditAction: (() -> Void)? {
        guard canBeginEditing else { return nil }
        return { beginEditingFromContent() }
    }

    private var editContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The quick panel's capture editor, not a SwiftUI TextField: same key
            // semantics everywhere — Enter inserts a newline, ⌘Enter saves (the
            // Save button's shortcut), Esc cancels, and IME composition never
            // commits on a bare Enter. A vertical-axis TextField submits on Enter
            // and only breaks lines with Option+Enter.
            ModeTextEditor(
                text: draftBinding, focused: $draftFocused,
                placeholder: "",
                submitsOnEnter: false,
                onSubmit: { commitDraft() },
                onCancel: { cancelDraft() },
                onHeight: { h in editorHeight = min(max(h, 22), 190) },
                fontSize: 15,
            )
            .frame(height: editorHeight)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsUnsavedPrompt {
                unsavedPrompt
            }

            HStack(spacing: 8) {
                Spacer(minLength: 12)
                Button { cancelDraft() } label: {
                    CaptureDraftButtonLabel(title: L("Cancel"), shortcut: "esc")
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
                Button { commitDraft() } label: {
                    CaptureDraftButtonLabel(title: L("Save"), shortcut: "⌘↩")
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
                .foregroundStyle(Color.chronicleAccent)
            Text(L("Unsaved changes"))
                .font(.caption.weight(.medium))
            Spacer(minLength: 12)
            Button(L("Keep editing")) { onKeepEditing?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
            Button(L("Discard")) { onDiscardAndContinue?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .secondary))
            Button(L("Save")) { onSaveAndContinue?() }
                .buttonStyle(CaptureDraftButtonStyle(kind: .primary))
                .disabled(!canSaveDraft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.chronicleAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commitDraft() {
        if isEditing {
            onCommitEdit?()
            return
        }
        let next = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackEditing = false
        guard !next.isEmpty, next != item.editableRawText else { return }
        onEdit?(next)
    }

    private func beginEditingFromContent() {
        guard captureRowCanBeginEditing(
            item,
            hasInlineEdit: onEdit != nil,
            hasExternalBegin: onBeginEdit != nil
        ), !rowIsEditing else { return }
        if let onBeginEdit {
            onBeginEdit()
            return
        }
        guard let editableRawText = item.editableRawText else { return }
        fallbackText = editableRawText
        fallbackEditing = true
    }

    private func cancelDraft() {
        if isEditing {
            onCancelEdit?()
            return
        }
        fallbackEditing = false
    }
}

/// An external editor may hydrate a search/review projection before editing,
/// while the row's inline fallback requires raw text it already owns. Keeping
/// this distinction explicit prevents external edit callbacks from being gated
/// by the inline editor's stricter requirement.
func captureRowCanBeginEditing(
    _ item: RowItem,
    hasInlineEdit: Bool,
    hasExternalBegin: Bool
) -> Bool {
    guard !item.displayText.isEmpty else { return false }
    return hasExternalBegin || (hasInlineEdit && item.editableRawText != nil)
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
    @ObservedObject private var localization = DesktopLocalization.shared

    var body: some View {
        HStack(spacing: 12) {
            Text(L("Capture deleted")).font(.callout)
            Button(L("Undo"), action: onUndo)
                .buttonStyle(.plain)
                .foregroundStyle(Color.chronicleAccent)
                .font(.callout.weight(.medium))
            Text("⌘Z").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}
