import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.refreshPending()
        let window = window ?? makeWindow()
        self.window = window
        ScreenPlacement.centerOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = L("Chronicle Settings")
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = NSHostingView(
            rootView: SettingsView(model: model).tint(.chronicleAccent)
        )
        return window
    }
}
