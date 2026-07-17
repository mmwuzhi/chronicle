import AppKit
import SwiftUI
import ChronicleDesktopCore

// The contents of a pinned desktop sticky — a borderless Liquid-Glass note ported
// from rag4, adapted to Chronicle:
//
//   • top handle: drag to move (no native title bar to grab); the ✕ fades in on
//     hover (top-left, where the macOS close button lives).
//   • body: the capture text with inline markdown, an optional image thumbnail, and
//     the timestamp pinned below it (hover → precise).
//   • double-click anywhere opens the capture's detail window. The body text keeps
//     native click-drag selection via the shared RowTextView implementation:
//     double-click goes to the open action instead
//     of word selection — the same trade the main window's rows make for editing.
//   • bottom edge: an invisible resize bar (drag to grow/shrink vertically).
//
// The body reports its natural height up through `onHeight` so the window fits its
// content (short note → small window; long note → scrolls). Once the user drags the
// resize bar, `onManualResize` fires and the controller stops auto-fitting that pin.
struct PinnedStickyView: View {
    @ObservedObject private var localization = DesktopLocalization.shared
    let content: String
    let createdAt: String
    let mediaType: String
    let mediaUrl: String?
    let todoState: CaptureTodoState?
    let onUnpin: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onHeight: (CGFloat) -> Void
    let onManualResize: () -> Void

    @State private var headerHovering = false

    private static let headerHeight: CGFloat = 22
    private static let footerHeight: CGFloat = 10
    private static let timestampHeight: CGFloat = 20

    private var chromeHeight: CGFloat {
        Self.headerHeight + Self.footerHeight + Self.timestampHeight
    }

    private var thumbURL: URL? {
        guard mediaType == "image", let mediaUrl, let url = URL(string: mediaUrl) else { return nil }
        return url
    }

    private var visibleContent: String {
        guard todoState != nil else { return content }
        return CaptureTodoTag.displayText(from: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let todoState {
                        TodoFacetChip(state: todoState)
                    }
                    if !visibleContent.isEmpty {
                        StickySelectableText(
                            markdown: visibleContent,
                            onDoubleClick: onOpen,
                            onCancel: onUnpin
                        )
                    } else if thumbURL == nil {
                        Text(L("(media capture)")).foregroundStyle(.secondary)
                    }
                    if let thumbURL { StickyThumbnail(url: thumbURL) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .background(GeometryReader { g in
                    Color.clear.preference(key: StickyHeightKey.self, value: g.size.height)
                })
                .overlayScrollers()
            }
            timestampBar
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Whole-sticky double-click → detail window. The header's WindowDragHandle
        // and the bottom resize bar are NSViews that consume their own mouseDown
        // (the handle opens on double-click itself), so this covers everything else:
        // body text, margins, thumbnail, timestamp, and blank space.
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .panelGlass(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onPreferenceChange(StickyHeightKey.self) { onHeight(chromeHeight + $0) }
        .onExitCommand(perform: onUnpin)
    }

    // Drag bar: drag to move, double-click to open; ✕ (unpin) + copy fade in on hover.
    private var header: some View {
        ZStack {
            WindowDragHandle(onDoubleClick: onOpen)
            HStack {
                Button(action: onUnpin) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("Unpin from desktop (or press Esc)"))
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("Copy"))
            }
            .opacity(headerHovering ? 1 : 0)
            .padding(.horizontal, 6)
        }
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        .onHover { headerHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: headerHovering)
    }

    private var timestampBar: some View {
        HoverTimestamp(iso: createdAt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: Self.timestampHeight)
    }

    private var footer: some View {
        StickyResizeHandle(onResizeBegan: onManualResize)
            .frame(height: Self.footerHeight)
            .contentShape(Rectangle())
    }
}

// MARK: - Inline markdown

/// Inline-only markdown (**bold**/*italic*/`code`; "- "/"* " bullets → "• ") as a
/// single AttributedString. Block syntax (headings, code fences) is left literal.
/// Ported from rag4's renderedMarkdown.
func renderedMarkdown(_ md: String) -> AttributedString {
    let bulletized = String(("\n" + md)
        .replacingOccurrences(of: "\n- ", with: "\n• ")
        .replacingOccurrences(of: "\n* ", with: "\n• ")
        .dropFirst())
    let opts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: bulletized, options: opts)) ?? AttributedString(md)
}

// MARK: - Selectable body text

/// Sticky body text: a shared NSTextView (native click-drag selection,
/// `clickCount == 2` handed to the open action instead of word selection). SwiftUI's
/// `Text` + `.textSelection` swallows double-clicks in its AppKit host, which made
/// most of a text-dense sticky a dead zone for the open gesture.
private struct StickySelectableText: NSViewRepresentable {
    let attributed: NSAttributedString
    let onDoubleClick: () -> Void
    let onCancel: () -> Void

    init(markdown: String, onDoubleClick: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.attributed = Self.render(markdown)
        self.onDoubleClick = onDoubleClick
        self.onCancel = onCancel
    }

    func makeNSView(context: Context) -> SelectableRowText.RowTextView {
        let tv = SelectableRowText.RowTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: SelectableRowText.RowTextView, context: Context) {
        tv.onDoubleClick = onDoubleClick
        tv.onCancel = onCancel
        if tv.string != attributed.string {
            tv.textStorage?.setAttributedString(attributed)
        }
    }

    // Same stateless measurement as SelectableRowText (never touch the text view's
    // own container during SwiftUI's multi-proposal probing), on the attributed body.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView tv: SelectableRowText.RowTextView, context: Context
    ) -> CGSize? {
        let proposed = proposal.width ?? .infinity
        let wrapWidth = proposed.isFinite && proposed > 0 ? proposed : .greatestFiniteMagnitude
        let measured = attributed.boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
        ).size
        let width = wrapWidth == .greatestFiniteMagnitude ? ceil(measured.width) : wrapWidth
        return CGSize(width: width, height: ceil(measured.height))
    }

    // renderedMarkdown's AttributedString carries inline presentation intents that
    // SwiftUI Text resolves at draw time; NSTextView needs concrete fonts, so map
    // bold/italic/code onto the body font here.
    private static func render(_ md: String) -> NSAttributedString {
        let attr = renderedMarkdown(md)
        let body = NSFont.preferredFont(forTextStyle: .body)
        let out = NSMutableAttributedString()
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = body
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            out.append(NSAttributedString(
                string: String(attr.characters[run.range]),
                attributes: [.font: font, .foregroundColor: NSColor.labelColor],
            ))
        }
        return out
    }
}

// MARK: - Timestamp

/// Relative time at rest ("3m", "Jun 6"); precise on hover. The sticky's own copy
/// of the row's hover-timestamp behaviour, scoped here since only the sticky uses it.
struct HoverTimestamp: View {
    let iso: String
    @State private var hovering = false

    var body: some View {
        Text(hovering ? CaptureTime.precise(iso) : CaptureTime.display(iso))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .onHover { hovering = $0 }
    }
}

// MARK: - Thumbnail

/// An image-capture thumbnail loaded straight from its R2 URL (the same public URL
/// the web app renders with `<img src>`), so no auth or on-disk decode is needed.
private struct StickyThumbnail: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
            case .failure:
                Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 160, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Height reporting

/// The body's natural height, reduced to the max across siblings, used to fit the
/// window to its content.
private struct StickyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Drag handle

/// The top handle's drag implementation. A borderless window has no native title bar
/// to grab, so mouseDown drives the window drag directly; a double-click opens the
/// detail window instead of dragging.
private struct WindowDragHandle: NSViewRepresentable {
    let onDoubleClick: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = DragView(); v.onDoubleClick = onDoubleClick; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragView)?.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?

        // The sticky usually isn't the key window; without accepting first mouse the
        // first click would only activate it, so the user would have to click twice
        // to start a drag. Returning true gives the standard click-and-drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(); return }
            window?.makeKeyAndOrderFront(nil) // select the sticky → Esc can reach it
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Resize handle

/// The invisible bottom-edge resize bar. A borderless window has no native draggable
/// edge, so this view tracks the mouse: the top edge is pinned and height grows/
/// shrinks from the bottom, clamped to [minH, screen height − 80]; width never
/// changes. The first drag reports `onResizeBegan` so the controller stops auto-fit.
private struct StickyResizeHandle: NSViewRepresentable {
    let onResizeBegan: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = ResizeView(); v.onResizeBegan = onResizeBegan; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ResizeView)?.onResizeBegan = onResizeBegan
    }

    final class ResizeView: NSView {
        var onResizeBegan: (() -> Void)?
        private static let minH: CGFloat = 80
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation // screen coordinates
            window.makeKeyAndOrderFront(nil)
            onResizeBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let dy = NSEvent.mouseLocation.y - startMouse.y // dragging down = negative
            let maxH = (window.screen?.visibleFrame.height ?? 800) - 80
            let top = startFrame.maxY // pin the top edge
            let h = min(max(startFrame.height - dy, Self.minH), maxH)
            var f = startFrame
            f.size.height = h
            f.origin.y = top - h
            window.setFrame(f, display: true, animate: false) // → windowDidResize → persist
        }
    }
}

// MARK: - Overlay scrollers

/// Pins the enclosing NSScrollView's scroller to overlay (floating, zero-width) so
/// showing/hiding it never reflows the text. macOS keeps demoting it back to the
/// legacy width-taking style on mouse contact, so this re-asserts on every layout.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ReapplyScrollerStyle { ReapplyScrollerStyle() }
    func updateNSView(_ nsView: ReapplyScrollerStyle, context: Context) { nsView.apply() }
}

final class ReapplyScrollerStyle: NSView {
    func apply() {
        guard let sv = enclosingScrollView else { return }
        sv.scrollerStyle = .overlay
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }
}

extension View {
    func overlayScrollers() -> some View { background(OverlayScrollers()) }
}
