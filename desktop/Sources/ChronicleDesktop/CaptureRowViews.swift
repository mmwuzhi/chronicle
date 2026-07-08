import AppKit
import SwiftUI
import ChronicleDesktopCore

// The shared capture row and its trailing-action vocabulary, used by browse,
// the quick panel, the detail window, and the link picker.

// MARK: - Row actions

/// One icon action in a row's trailing slot: fixed 24×22 footprint, its own
/// hover/pressed wash, and no hit testing while hidden (an invisible button
/// must not swallow clicks on the empty space beside a row).
private struct RowActionButton: View {
    let systemImage: String
    let help: String
    // Shown only while the pointer is on this button; resting state stays
    // secondary so a danger tint doesn't shout from every hovered row.
    var hoverTint: Color?
    var visible: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? (hoverTint ?? .secondary) : .secondary)
        }
        .buttonStyle(RowActionButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        // A hidden control must not announce itself: .help registers its tooltip
        // area regardless of opacity, so without the gate the empty space beside
        // an un-hovered row pops "Copy"/"Delete" tips over invisible buttons.
        .help(visible ? help : "")
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
/// Layered by universality (rag's model): copy (universal, safe) stays direct;
/// low-frequency state actions (pin, remove link) fold into ⋯; open stays direct
/// because it is the list's only route into the detail window (double-click is
/// taken by editing); delete sits last and only turns danger-red under the
/// pointer — the same "red only at the moment of intent" rule as the web's
/// overflow menu (the 5s undo toast is the actual safety net).
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
            RowActionButton(systemImage: "doc.on.doc", help: "Copy",
                            visible: hovering, action: onCopy)
            if onPin != nil || onUnlink != nil {
                RowActionMenu(visible: hovering) {
                    if let onPin {
                        Button(action: onPin) {
                            Label(isPinned ? "Unpin from desktop" : "Pin to desktop",
                                  systemImage: isPinned ? "pin.slash" : "pin")
                        }
                    }
                    if let onUnlink {
                        Button(action: onUnlink) {
                            Label("Remove link", systemImage: "minus.circle")
                        }
                    }
                }
            }
            if let onOpen {
                RowActionButton(systemImage: "arrow.up.forward.square", help: "Open",
                                visible: hovering, action: onOpen)
            }
            if let onDelete {
                RowActionButton(systemImage: "trash", help: "Delete",
                                hoverTint: .red.opacity(0.85),
                                visible: hovering, action: onDelete)
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
            + (onUnlink == nil && onPin == nil ? 0 : 1)
        return CGFloat(count) * 24 + CGFloat(count - 1) * 2
    }
}

/// The ⋯ overflow in a row's trailing slot: same 24×22 footprint and hover wash
/// as its sibling buttons, hidden (and not hit-testable) until the row is hovered.
private struct RowActionMenu<Items: View>: View {
    var visible: Bool
    @ViewBuilder var items: () -> Items

    @State private var hovering = false

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        // The borderless menu style paints its label with the environment tint,
        // overriding the label's own foregroundStyle — without this counter-tint
        // the window root's brand tint turns the ⋯ green.
        .tint(Color.secondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 22)
        .background(
            Color.primary.opacity(hovering ? 0.07 : 0),
            in: RoundedRectangle(cornerRadius: 6),
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        // Same gate as RowActionButton: no tooltip while hidden.
        .help(visible ? "More" : "")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
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

// MARK: - Row body text

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

// MARK: - Capture row

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
        .overlay(alignment: .leading) {
            PinnedEdgeBar(isPinned: isPinned && !rowIsEditing)
        }
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
        // Resting metadata stays tertiary; the whole line firms up to secondary
        // on hover because that's the moment the user is actually reading it.
        // The todo marker mirrors the web card's footer vocabulary (Todo/Done).
        HStack(spacing: 4) {
            if let todo = item.todoState {
                Image(systemName: todo == .done ? "checkmark.square" : "square")
                Text(todo == .done ? "Done" : "Todo")
                Text("·")
            }
            Text(hovering ? CaptureTime.precise(item.createdAt)
                          : CaptureTime.display(item.createdAt))
        }
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
                .foregroundStyle(Color.chronicleAccent)
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
        .background(Color.chronicleAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
