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

    /// True while a fullscreen context is frontmost — a native fullscreen Space
    /// (another app's fullscreen window) or a WezTerm-style fake fullscreen (a
    /// window maximized over the whole screen on a regular Space, covering the
    /// menu bar with its own strip). Gates sticky surfacing: a panel first
    /// ordered front in a fullscreen context sticks to that Space permanently.
    /// (Not used for the main/detail/settings windows: an explicit open is
    /// allowed to overlay fullscreen — user decision 2026-07-09 — and probes
    /// showed every programmatic show lands on the fullscreen Space anyway.)
    ///
    /// Detection, verified live on both kinds: window bounds can't distinguish
    /// fullscreen from a maximized window (identical frames on a notched
    /// display with the Dock hidden), but the top strip can. Native fullscreen
    /// removes the menu bar backdrop (the window-server window at the main-menu
    /// level spanning the screen) from the on-screen list and the fullscreen
    /// app owns a full-width strip above menu-bar level; fake fullscreen keeps
    /// the menu bar in the list but covers it with the same kind of strip. A
    /// plain desktop has the backdrop and no such strip.
    /// Known limit: a user who auto-hides the menu bar on the desktop reads as
    /// "fullscreen" and loses only the follow-to-Space convenience.
    static func activeSpaceIsFullScreen() -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]],
            let width = NSScreen.screens.first?.frame.width
        else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        var menuBarPresent = false
        var menuBarCovered = false
        for win in info {
            guard let layer = win[kCGWindowLayer as String] as? Int,
                  let pid = win[kCGWindowOwnerPID as String] as? Int32,
                  let dict = win[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.minY == 0, rect.width >= width
            else { continue }
            if layer == menuLevel { menuBarPresent = true }
            if layer > menuLevel, pid != myPID { menuBarCovered = true }
        }
        return !menuBarPresent || menuBarCovered
    }
}
