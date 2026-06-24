import CoreGraphics

/// Geometry for the double-tap-Control quick panel.
///
/// The panel anchors its TOP edge at a fixed point above the visible area's
/// center, so it opens in the same place every time and the results list grows
/// downward. Anchoring the bottom instead let the panel's (variable) height leak
/// into the top position: a tall, stale panel re-appeared shifted upward on the
/// next show. Keeping this pure makes that invariant testable without a window
/// or a live screen.
public enum PanelLayout {
    /// Distance from the visible area's vertical center up to the panel's top edge.
    public static let topOffsetAboveCenter: CGFloat = 230

    /// The panel's top-edge y. AppKit coordinates: larger y is higher on screen.
    public static func topY(visibleFrame: CGRect) -> CGFloat {
        visibleFrame.midY + topOffsetAboveCenter
    }

    /// Bottom-left origin y that places a panel of `height` with its top edge at
    /// `topY`. The top edge is independent of `height` — that independence is
    /// exactly what stops re-shows (and live resizes) from drifting vertically.
    public static func originY(visibleFrame: CGRect, height: CGFloat) -> CGFloat {
        topY(visibleFrame: visibleFrame) - height
    }

    /// Index of the screen frame that contains `point`, or nil if none. Used to
    /// pick the display the cursor is on at show time, so a window opens where the
    /// user is working instead of wherever it last appeared.
    public static func screenIndex(containing point: CGPoint, screenFrames: [CGRect]) -> Int? {
        screenFrames.firstIndex { $0.contains(point) }
    }

    /// Bottom-left origin that centers a window of `size` within `visibleFrame`.
    public static func centeredOrigin(in visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
        )
    }
}
