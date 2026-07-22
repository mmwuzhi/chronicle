import AppKit
import SwiftUI

// Shared SwiftUI building blocks for the three desktop surfaces (quick-capture
// panel, main window, settings). Visual language ported from rag3: Divider rows,
// hover-only borderless icon buttons, caption/secondary hierarchy. No cards, no
// decorative shadows — the same quiet treatment across every surface.

// MARK: - Palette

extension Color {
    /// Chronicle stays neutral until a deliberate theme system exists.
    /// Use concrete adaptive colors instead of `Color.primary` as a tint: semantic
    /// foreground colors can resolve as both a prominent control's fill and label.
    static let chronicleAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .white
            : NSColor(srgbRed: 19 / 255, green: 23 / 255, blue: 32 / 255, alpha: 1)
    })

    /// Foreground placed on `chronicleAccent` controls.
    static let chronicleOnAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .black
            : .white
    })

    /// A quiet neutral navigation surface. Unlike the old glass rail, it stays
    /// opaque when the sidebar peeks over text-heavy content.
    static let chronicleSidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.115, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.968, blue: 0.972, alpha: 1)
    })
}

enum DesktopScrollLayout {
    // An overlay NSScroller is 17pt wide on macOS. Reserve its gutter so it
    // never owns a trailing row-action hit target while visible.
    static let trailingActionGutter: CGFloat = 20
}

// MARK: - Row hover geometry

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

// MARK: - Shared mode switcher

/// Pill mode switcher shared by the quick panel and the main window, so
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
                        selected == seg.id ? AnyShapeStyle(Color.primary.opacity(0.10))
                                           : AnyShapeStyle(Color.clear),
                        in: Capsule(),
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
