import AppKit
import SwiftUI

// Shared SwiftUI building blocks for the three desktop surfaces (quick-capture
// panel, main window, settings). Visual language ported from rag3: Divider rows,
// hover-only borderless icon buttons, caption/secondary hierarchy. No cards, no
// decorative shadows — the same quiet treatment across every surface.

// MARK: - Brand

extension Color {
    /// Chronicle's brand green — the web app's `--accent: #0e9e6e` — fixed
    /// instead of following the macOS system accent: the two ends should read
    /// as one product, and a user-chosen system accent (orange, blue, …) was
    /// the loudest visual split between them. Lightened in dark mode so it
    /// keeps contrast on dark surfaces.
    static let chronicleAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.76, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.055, green: 0.62, blue: 0.431, alpha: 1)
    })
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
                        selected == seg.id ? AnyShapeStyle(Color.chronicleAccent.opacity(0.22))
                                           : AnyShapeStyle(Color.clear),
                        in: Capsule(),
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
