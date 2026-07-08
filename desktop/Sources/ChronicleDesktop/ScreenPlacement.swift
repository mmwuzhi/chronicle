import AppKit
import ChronicleDesktopCore

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
