import AppKit
import SwiftUI
import ChronicleDesktopCore

// Pins a capture to the desktop as a floating, always-on-top sticky note.
//
// Where rag4's stickies were borderless Liquid-Glass panels that needed custom drag,
// custom resize and a wake-recomposite hack to fix glass darkening, Chronicle uses a
// native titled utility panel: the title bar gives drag, `.resizable` gives resize,
// the close button gives unpin — no custom AppKit, and with no glass there is no
// wake-darkening bug to patch. (Chronicle's guardrail: choose the simpler solution.)
//
// Persistence (pinned-captures.json in Application Support) stores each pin's id,
// cached content and window frame, so stickies restore at the same spot across
// launches AND render offline from cache; when signed in, restore()/refreshAll()
// refresh each from GET /captures/{id} (best-effort — a failure keeps the cache).
//
// The one rule carried over from rag4: removing a pin from disk happens ONLY on an
// explicit user action (the close button → windowShouldClose, or the row toggle →
// unpin). App termination also closes the panels (windowWillClose), but that path
// must never touch the file, or every pin would vanish on the next launch.
@MainActor
final class PinnedStickyController: NSObject, NSWindowDelegate {
    private let recall: () -> RecallAPIClient?
    private var windows: [String: NSPanel] = [:]
    private var saved: [String: PersistedPin] = [:]

    init(recall: @escaping () -> RecallAPIClient?) {
        self.recall = recall
        super.init()
        load()
    }

    func isPinned(_ id: String) -> Bool { saved[id] != nil }

    /// Toggle a row's pinned state — the surface for the pin button on capture rows.
    func toggle(_ row: RowItem) {
        if isPinned(row.id) { unpin(row.id) } else { pin(row) }
    }

    /// Re-fetch every pinned capture's content (called after a successful sign-in so
    /// stickies restored from cache on launch pick up the latest text).
    func refreshAll() {
        for id in saved.keys { refresh(id) }
    }

    /// Rebuild the stickies persisted from a previous session. Renders cached content
    /// immediately (works offline / signed out), then refreshes from the server.
    func restore() {
        for pin in saved.values where windows[pin.id] == nil {
            let panel = makePanel(for: pin, cascade: false)
            windows[pin.id] = panel
            panel.orderFront(nil)
            refresh(pin.id)
        }
        if !saved.isEmpty { notifyChanged() }
    }

    // MARK: - Pin / unpin

    private func pin(_ row: RowItem) {
        if let existing = windows[row.id] {
            existing.orderFront(nil) // already pinned: just surface it
            return
        }
        let pin = PersistedPin(id: row.id, content: row.content, createdAt: row.createdAt, frame: nil)
        saved[row.id] = pin
        let panel = makePanel(for: pin, cascade: true)
        windows[row.id] = panel
        saved[row.id]?.frame = panel.frame // remember the cascade spot even before a move
        persist()
        panel.orderFront(nil) // orderFront, not makeKey: don't steal focus / activate
        notifyChanged()
        refresh(row.id)
    }

    /// Programmatic unpin (row toggle). Removes the pin from disk, then closes the
    /// panel; windowWillClose then only clears the (already-removed) dictionary entry.
    private func unpin(_ id: String) {
        guard saved[id] != nil else { return }
        saved.removeValue(forKey: id)
        persist()
        if let panel = windows.removeValue(forKey: id) {
            panel.close()
        }
        notifyChanged()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // User clicked the close button (or ⌘W) → unpin. This delegate is NOT called
        // for programmatic close() (unpin path) or app-termination close, so those
        // can never reach here and wipe the file.
        guard let id = idFor(sender) else { return true }
        saved.removeValue(forKey: id)
        persist()
        windows.removeValue(forKey: id)
        notifyChanged()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Fires for every close (user, programmatic, app quit). Only forget the
        // window — NEVER touch `saved`/persist here, or quitting deletes all pins.
        guard let panel = notification.object as? NSPanel else { return }
        windows = windows.filter { $0.value !== panel }
    }

    func windowDidMove(_ notification: Notification) { syncFrame(notification) }
    func windowDidResize(_ notification: Notification) { syncFrame(notification) }

    private func syncFrame(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let id = idFor(panel), saved[id] != nil else { return }
        saved[id]?.frame = panel.frame
        persist()
    }

    // MARK: - Windows

    private func makePanel(for pin: PersistedPin, cascade: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false,
        )
        panel.title = "Pinned capture"
        panel.isFloatingPanel = true
        panel.level = .floating // always on top
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Empty collection behavior keeps the sticky on the Space where it was created
        // (the opposite of the panel/main window, which follow the active Space).
        panel.collectionBehavior = []
        panel.delegate = self
        setContent(panel, content: pin.content, createdAt: pin.createdAt)
        if let frame = pin.frame {
            panel.setFrame(frame, display: false)
        } else if cascade {
            positionCascaded(panel)
        } else {
            panel.center()
        }
        return panel
    }

    private func setContent(_ panel: NSPanel, content: String, createdAt: String) {
        panel.contentView = NSHostingView(
            rootView: StickyView(content: content, createdAt: createdAt, onCopy: Self.copy))
    }

    // Offset each new sticky from the top-right so several don't stack exactly.
    private func positionCascaded(_ panel: NSPanel) {
        let screen = ScreenPlacement.active()?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let step = CGFloat(windows.count % 6) * 26
        let x = screen.maxX - panel.frame.width - 40 - step
        let y = screen.maxY - panel.frame.height - 40 - step
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Server refresh

    // Pull the latest content for a pin. Best-effort: any failure (offline, signed
    // out, a 404 for a capture deleted elsewhere) keeps the cached sticky, which the
    // user can still read and close. Only a successful fetch updates cache + view.
    private func refresh(_ id: String) {
        guard let client = recall() else { return }
        Task { @MainActor in
            guard let capture = try? await client.capture(id: id) else { return }
            guard saved[id] != nil else { return } // unpinned while in flight
            saved[id]?.content = capture.content
            saved[id]?.createdAt = capture.createdAt
            persist()
            if let panel = windows[id] {
                setContent(panel, content: capture.content, createdAt: capture.createdAt)
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: ChronicleDesktopPaths.defaultPinsURL()),
              let list = try? JSONDecoder().decode([PersistedPin].self, from: data) else { return }
        for pin in list { saved[pin.id] = pin }
    }

    private func persist() {
        let url = ChronicleDesktopPaths.defaultPinsURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(saved.values))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Chronicle: pin persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func idFor(_ window: NSWindow) -> String? {
        windows.first(where: { $0.value === window })?.key
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .chroniclePinsChanged, object: nil)
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// One persisted sticky. `content`/`createdAt` are a cache so the sticky renders
// offline; `frame` (nil until first move/resize) restores its on-screen position.
private struct PersistedPin: Codable {
    let id: String
    var content: String
    var createdAt: String
    var frame: NSRect?
}

// The sticky's contents: the capture text (scrollable), its timestamp, and a copy
// button. Plain material — no glass — so there's no wake-darkening to work around.
private struct StickyView: View {
    let content: String
    let createdAt: String
    var onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(content.isEmpty ? "(media capture)" : content)
                    .textSelection(.enabled)
                    .foregroundStyle(content.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(CaptureTime.display(createdAt))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { onCopy(content) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
