import AppKit
import ChronicleDesktopCore
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
                    RomanOnlySecureField(
                        prompt: prompt,
                        text: $text,
                        onSubmit: onSubmit,
                    )
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

/// AppKit exposes the input-source restriction that SwiftUI's `SecureField`
/// does not. Passwords accept Roman input sources only, so a currently active
/// CJK IME switches to direct input instead of opening a candidate window.
final class RomanOnlySecureTextField: NSSecureTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        (cell as? NSTextFieldCell)?.allowedInputSourceLocales = [
            NSAllRomanInputSourcesLocaleIdentifier,
        ]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        (cell as? NSTextFieldCell)?.allowedInputSourceLocales = [
            NSAllRomanInputSourcesLocaleIdentifier,
        ]
    }
}

private struct RomanOnlySecureField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RomanOnlySecureTextField {
        let field = RomanOnlySecureTextField(frame: .zero)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = prompt
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: RomanOnlySecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RomanOnlySecureField

        init(_ parent: RomanOnlySecureField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() {
            parent.onSubmit()
        }
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
    var hasCompletion = false
    var onComplete: (() -> Void)?
    var onPasteAttachment: ((URL, Bool) -> Void)?
    var onPasteAttachmentError: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onCancel = onCancel
        tv.onComplete = onComplete
        tv.onPasteAttachment = onPasteAttachment
        tv.onPasteAttachmentError = onPasteAttachmentError
        tv.submitsOnEnter = submitsOnEnter
        tv.hasCompletion = hasCompletion
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

        let scroll = ModeTextScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.editorCoordinator = context.coordinator
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SubmitTextView else { return }
        tv.onSubmit = onSubmit
        tv.onCancel = onCancel
        tv.onComplete = onComplete
        tv.onPasteAttachment = onPasteAttachment
        tv.onPasteAttachmentError = onPasteAttachmentError
        tv.submitsOnEnter = submitsOnEnter
        tv.hasCompletion = hasCompletion
        let desiredFont = NSFont.systemFont(ofSize: fontSize)
        if tv.font?.pointSize != desiredFont.pointSize {
            tv.font = desiredFont
        }
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        if tv.placeholderString != placeholder {
            tv.placeholderString = placeholder
            tv.needsDisplay = true
        }
        context.coordinator.updateContainerWidth(scroll.frame.width - 16)
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

        func updateContainerWidth(_ width: CGFloat) {
            guard width > 0, let tv = textView, let tc = tv.textContainer,
                  abs(tc.size.width - width) > 0.5
            else { return }
            tc.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            tv.frame.size.width = width
            reportHeight()
        }

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

/// SwiftUI can create and update the representable before AppKit gives the
/// scroll view a width. Keep the text container synced from the native layout
/// lifecycle so an existing draft never remains laid out in a zero-width box.
final class ModeTextScrollView: NSScrollView {
    weak var editorCoordinator: ModeTextEditor.Coordinator?

    override func layout() {
        super.layout()
        editorCoordinator?.updateContainerWidth(frame.width - 16)
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onComplete: (() -> Void)?
    var onPasteAttachment: ((URL, Bool) -> Void)?
    var onPasteAttachmentError: (() -> Void)?
    var submitsOnEnter = true
    var hasCompletion = false
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

    override func insertTab(_ sender: Any?) {
        if hasCompletion {
            onComplete?()
        } else {
            super.insertTab(sender)
        }
    }

    override func paste(_ sender: Any?) {
        guard let onPasteAttachment else {
            super.paste(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        if let url = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first {
            onPasteAttachment(url, false)
            return
        }
        let imageData: Data?
        let fileExtension: String
        if let png = pasteboard.data(forType: .png) {
            imageData = png
            fileExtension = "png"
        } else if let tiff = pasteboard.data(forType: .tiff) {
            imageData = tiff
            fileExtension = "tiff"
        } else {
            imageData = nil
            fileExtension = ""
        }
        guard let imageData else {
            super.paste(sender)
            return
        }
        guard imageData.count <= directCaptureUploadMaxBytes else {
            onPasteAttachmentError?()
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-paste-\(UUID().uuidString).\(fileExtension)")
        do {
            try imageData.write(to: url, options: .atomic)
            onPasteAttachment(url, true)
        } catch {
            super.paste(sender)
        }
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
