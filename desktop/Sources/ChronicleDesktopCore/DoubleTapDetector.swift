import Foundation

/// Times a double-tap of a single key (the "double Control" quick-capture
/// gesture). Kept in the core so the timing + invalidation logic is unit-testable
/// without an event tap.
///
/// `register` records taps against a monotonic clock; two taps within `window`
/// fire (return true) and reset the pair. `reset` invalidates a pending first tap
/// — the controller calls it whenever anything breaks the "clean single-key
/// repeat" purity: another key pressed between the taps, or a second modifier held
/// alongside Control. A gesture only counts when nothing muddied it.
public struct DoubleTapDetector {
    private let window: TimeInterval
    private var lastTap: TimeInterval?

    public init(window: TimeInterval) {
        self.window = window
    }

    /// Record a tap at `time` (seconds on a monotonic clock, e.g.
    /// `ProcessInfo.processInfo.systemUptime`). Returns true when it completes a
    /// pair inside the window; that pair is then consumed so a third tap starts
    /// fresh.
    public mutating func register(at time: TimeInterval) -> Bool {
        if let lastTap, time - lastTap <= window {
            self.lastTap = nil
            return true
        }
        lastTap = time
        return false
    }

    /// Invalidate the pending first tap: the next `register` starts a new pair.
    public mutating func reset() {
        lastTap = nil
    }
}
