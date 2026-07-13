import AppKit
import SwiftUI

// Text inputs shared by the desktop surfaces: the bordered workspace field and
// the quick panel's three-mode multi-line editor.

// MARK: - Workspace field

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
    var fontSize: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onCancel = onCancel
        tv.submitsOnEnter = submitsOnEnter
        tv.string = text
        tv.placeholderString = placeholder
        tv.font = .systemFont(ofSize: fontSize)
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

    @MainActor
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
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            return
        }
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
