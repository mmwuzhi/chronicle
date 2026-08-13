import AppKit
import SwiftUI
import ChronicleDesktopCore

// Pins a capture to the desktop as a floating, always-on-top sticky note — a
// borderless Liquid-Glass panel ported from rag4 and matched to Chronicle's quick-
// capture panel (clear background + `panelGlass`). The note's chrome is hand-rolled
// because a borderless window has no native title bar/edges: PinnedStickyView's top
// handle drags, its ✕ unpins, its bottom edge resizes, a double-click anywhere opens
// the detail window, and the body auto-fits the window until the user resizes it.
//
// Persistence (pinned-captures.json in Application Support) stores each pin's id,
// cached content/media and window frame, so stickies restore at the same spot across
// launches AND render offline from cache; when signed in, restore()/refreshAll()
// refresh each from GET /captures/{id} (best-effort — a failure keeps the cache).
//
// The one rule carried over from rag4: removing a pin from disk happens ONLY on an
// explicit user action (the ✕/Esc → unpin, or the row toggle). App termination also
// closes the panels (windowWillClose), but that path must never touch the file, or
// every pin would vanish on the next launch.
//
// Liquid Glass loses its backdrop sample across display sleep and renders dark on
// wake; the system won't re-sample a floating, non-activating, Space-pinned panel on
// its own, so recompositeAfterWake() nudges each frame by 1px to force a re-composite.
@MainActor
final class PinnedStickyController: NSObject, NSWindowDelegate {
    private let clients: CaptureClients
    private var activeScopeKey: String?
    private var windows: [String: NSPanel] = [:]
    private var saved: [String: PersistedPin] = [:]
    private var manualHeight: Set<String> = [] // pins the user resized: auto-fit off
    // Pins whose panel exists but hasn't been ordered on screen yet because a
    // fullscreen Space was active at the time (see surface(_:id:)).
    private var deferredUntilNormalSpace: Set<String> = []
    private var taskMutationTasks: [String: Task<Void, Never>] = [:]
    private var taskUpdating: Set<String> = []
    private var taskErrors: [String: String] = [:]

    /// Injected by AppDelegate: double-click a sticky → open that capture's window.
    var onOpen: ((RowItem) -> Void)?

    private static let width: CGFloat = 300
    private static let defaultMaxHeight: CGFloat = 360

    init(
        clients: CaptureClients,
        initialScope: LocalCaptureScope?
    ) {
        self.clients = clients
        activeScopeKey = initialScope?.persistenceKey
        super.init()
        load()
        // See class note: re-composite the glass on wake or every sticky renders dark.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompositeAfterWake() }
        }
        // Surface any pins that were created/restored while a fullscreen Space
        // was active as soon as the user lands back on a normal Space.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderDeferredPins() }
        }
    }

    /// Order a sticky onto the current Space — unless that Space is another
    /// app's fullscreen Space. A panel first ordered there joins that Space
    /// permanently: it floats on top of the fullscreen app forever and never
    /// appears on the desktop. Such pins wait for the next normal-Space switch.
    private func surface(_ panel: NSPanel, id: String) {
        if ScreenPlacement.activeSpaceIsFullScreen() {
            deferredUntilNormalSpace.insert(id)
        } else {
            panel.orderFront(nil)
        }
    }

    private func orderDeferredPins() {
        guard !deferredUntilNormalSpace.isEmpty,
              !ScreenPlacement.activeSpaceIsFullScreen() else { return }
        for id in deferredUntilNormalSpace {
            windows[id]?.orderFront(nil)
        }
        deferredUntilNormalSpace.removeAll()
    }

    func isPinned(_ id: String) -> Bool { saved[id] != nil }

    /// Hide the previous account's cached stickies and load only the newly active
    /// verified/offline scope. Legacy pins without a scope remain quarantined.
    func activate(_ scope: LocalCaptureScope?) {
        guard activeScopeKey != scope?.persistenceKey else { return }
        for panel in Array(windows.values) {
            panel.orderOut(nil)
            panel.close()
        }
        windows.removeAll()
        saved.removeAll()
        manualHeight.removeAll()
        deferredUntilNormalSpace.removeAll()
        for task in taskMutationTasks.values { task.cancel() }
        taskMutationTasks.removeAll()
        taskUpdating.removeAll()
        taskErrors.removeAll()
        activeScopeKey = scope?.persistenceKey
        load()
        restore()
    }

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
            // Mark manual-height pins before the first layout, or the body's initial
            // height report would snap them back to content height.
            if pin.manualHeight == true { manualHeight.insert(pin.id) }
            let panel = makePanel(for: pin, cascade: false)
            windows[pin.id] = panel
            surface(panel, id: pin.id)
            refresh(pin.id)
        }
        if !saved.isEmpty { notifyChanged() }
    }

    // MARK: - Pin / unpin

    private func pin(_ row: RowItem) {
        guard let activeScopeKey else { return }
        if let existing = windows[row.id] {
            surface(existing, id: row.id) // already pinned: just surface it
            return
        }
        let pin = PersistedPin(
            id: row.id, content: row.content, createdAt: row.createdAt,
            mediaType: row.modality, mediaUrl: row.mediaUrl,
            todoDone: row.todoState.map { $0 == .done }, frame: nil,
            accountScope: activeScopeKey,
            rawText: row.modality == "text" ? row.editableRawText : nil)
        saved[row.id] = pin
        let panel = makePanel(for: pin, cascade: true)
        windows[row.id] = panel
        saved[row.id]?.frame = panel.frame // remember the cascade spot even before a move
        persist()
        surface(panel, id: row.id) // orderFront, not makeKey: don't steal focus / activate
        notifyChanged()
        refresh(row.id)
    }

    /// Programmatic unpin (row toggle, ✕ button, Esc). Removes the pin from disk, then
    /// closes the panel; windowWillClose then only clears the dictionary entry.
    private func unpin(_ id: String) {
        guard saved[id] != nil else { return }
        saved.removeValue(forKey: id)
        manualHeight.remove(id)
        deferredUntilNormalSpace.remove(id)
        taskMutationTasks.removeValue(forKey: id)?.cancel()
        taskUpdating.remove(id)
        taskErrors.removeValue(forKey: id)
        persist()
        if let panel = windows.removeValue(forKey: id) {
            panel.close()
        }
        notifyChanged()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Fires for every close (programmatic unpin, app quit). Only forget the
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

    /// First manual resize of a pin → auto-fit yields to the user (persisted, so a
    /// relaunch doesn't snap it back to content height). The ongoing frame changes are
    /// persisted by windowDidResize; this only flips the flag once.
    private func markManualHeight(_ id: String) {
        guard manualHeight.insert(id).inserted else { return }
        saved[id]?.manualHeight = true
        persist()
    }

    // MARK: - Windows

    private func makePanel(for pin: PersistedPin, cascade: Bool) -> NSPanel {
        let panel = KeyableStickyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false,
        )
        panel.level = .floating // always on top
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear // glass is drawn by the SwiftUI content
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "Pinned capture" // a11y / window menu (borderless shows none)
        // Empty collection behavior keeps the sticky on the Space where it was created
        // (the opposite of the panel/main window, which follow the active Space).
        panel.collectionBehavior = []
        panel.delegate = self
        panel.onEsc = { [weak self] in self?.unpin(pin.id) }
        setContent(panel, pin: pin)
        if var frame = pin.frame {
            // Width is fixed by design (only height and position ever change). This
            // also heals frames that an old layout bug persisted at blown-out widths.
            frame.size.width = Self.width
            panel.setFrame(frame, display: false)
        } else if cascade {
            positionCascaded(panel)
        } else {
            panel.center()
        }
        return panel
    }

    private func setContent(_ panel: NSPanel, pin: PersistedPin) {
        let id = pin.id
        let taskMarkdown = (pin.mediaType ?? "text") == "text" ? pin.rawText : nil
        let renderedContent = taskMarkdown.flatMap {
            MarkdownTaskDocument.tasks(in: $0).isEmpty ? nil : $0
        } ?? pin.content
        let hosting = NSHostingView(rootView: PinnedStickyView(
            content: renderedContent,
            createdAt: pin.createdAt,
            mediaType: pin.mediaType ?? "text",
            mediaUrl: pin.mediaUrl,
            todoState: pin.todoDone.map { $0 ? .done : .open },
            taskMarkdown: taskMarkdown,
            taskBusy: taskUpdating.contains(id),
            taskError: taskErrors[id],
            onTaskChange: { [weak self] lineIndex, completedOn in
                self?.setTaskCompletion(id: id, lineIndex: lineIndex, completedOn: completedOn)
            },
            onUnpin: { [weak self] in self?.unpin(id) },
            onOpen: { [weak self] in self?.openDetail(id) },
            onCopy: { Self.copy(renderedContent) },
            onHeight: { [weak self, weak panel] h in
                guard let self, let panel, !self.manualHeight.contains(id) else { return }
                self.resize(panel, toContent: h)
            },
            onManualResize: { [weak self] in self?.markManualHeight(id) },
        ))
        // This controller owns the panel frame (persisted, height-fitted via
        // onHeight). The default sizing options let SwiftUI's ideal size drive the
        // window instead, which blew the sticky out to the body text's unwrapped
        // single-line width the moment the body became an NSTextView.
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    /// Content natural height → window height (fits content, scrolls past the cap).
    /// The top edge is pinned; height grows/shrinks from the bottom.
    private func resize(_ panel: NSPanel, toContent contentH: CGFloat) {
        let maxH = min(Self.defaultMaxHeight, (panel.screen?.visibleFrame.height ?? 800) - 80)
        let h = min(max(contentH, 80), maxH)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var f = panel.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true, animate: false) // → windowDidResize → persist
    }

    private func recompositeAfterWake() {
        for panel in windows.values {
            var f = panel.frame
            f.size.height += 1; panel.setFrame(f, display: true)
            f.size.height -= 1; panel.setFrame(f, display: true)
        }
    }

    private func openDetail(_ id: String) {
        guard let pin = saved[id] else { return }
        onOpen?(RowItem(
            id: pin.id, content: pin.content, createdAt: pin.createdAt,
            modality: pin.mediaType ?? "text", mediaUrl: pin.mediaUrl))
    }

    private func setTaskCompletion(id: String, lineIndex: Int, completedOn: String?) {
        guard !taskUpdating.contains(id),
              let displayedRawText = saved[id]?.rawText,
              let scope = activeScopeKey
        else { return }

        let generation = clients.session.snapshot()
        taskUpdating.insert(id)
        taskErrors.removeValue(forKey: id)
        if let panel = windows[id], let pin = saved[id] {
            setContent(panel, pin: pin)
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.taskUpdating.remove(id)
                self.taskMutationTasks.removeValue(forKey: id)
                if let panel = self.windows[id], let current = self.saved[id] {
                    self.setContent(panel, pin: current)
                }
            }
            do {
                let initialLocal = try self.clients.localTaskSource(id).get()
                let client = self.clients.recall()
                var currentRawText: String
                var writesLocally: Bool

                if let initialLocal, initialLocal.isAuthoritative || client == nil {
                    currentRawText = initialLocal.rawText
                    writesLocally = true
                } else {
                    guard let client else {
                        throw MarkdownTaskMutationError.sourceUnavailable
                    }
                    let current = try await client.capture(id: id)
                    guard !Task.isCancelled, self.activeScopeKey == scope,
                          self.clients.session.isCurrent(generation), self.saved[id] != nil,
                          current.mediaType == "text", let remoteRawText = current.rawText
                    else { return }
                    let latestLocal = try self.clients.localTaskSource(id).get()
                    if let latestLocal, latestLocal.isAuthoritative {
                        currentRawText = latestLocal.rawText
                        writesLocally = true
                    } else {
                        currentRawText = remoteRawText
                        writesLocally = initialLocal != nil
                    }
                }

                guard let next = MarkdownTaskDocument.settingCompletion(
                    in: currentRawText,
                    matchingTaskIn: displayedRawText,
                    lineIndex: lineIndex,
                    completedOn: completedOn
                ) else {
                    self.updateRawText(currentRawText, id: id)
                    self.taskErrors[id] = L("We couldn't update this task. Try again.")
                    self.persist()
                    return
                }
                guard next != currentRawText else { return }

                if writesLocally {
                    guard self.clients.localSetText(id, next) else {
                        throw MarkdownTaskMutationError.sourceUnavailable
                    }
                    self.updateRawText(next, id: id)
                    self.taskErrors.removeValue(forKey: id)
                    self.persist()
                    CaptureEvents.postChanged()
                    await self.clients.syncEdits()
                    return
                }

                guard let client else {
                    throw MarkdownTaskMutationError.sourceUnavailable
                }
                let updated = try await client.update(id: id, rawText: next)
                guard !Task.isCancelled, self.activeScopeKey == scope,
                      self.clients.session.isCurrent(generation), self.saved[id] != nil
                else { return }
                self.updatePin(from: updated, id: id)
                self.taskErrors.removeValue(forKey: id)
                self.persist()
                CaptureEvents.postChanged()
            } catch {
                guard !Task.isCancelled, self.activeScopeKey == scope,
                      self.clients.session.isCurrent(generation), self.saved[id] != nil
                else { return }
                self.taskErrors[id] = L("We couldn't update this task. Try again.")
            }
        }
        taskMutationTasks[id] = task
    }

    private func updateRawText(_ rawText: String, id: String) {
        guard var pin = saved[id] else { return }
        let previousRawText = pin.rawText
        pin.rawText = rawText
        if let previousRawText, pin.content == previousRawText {
            pin.content = rawText
        }
        pin.todoDone = CaptureTodoTag.state(in: rawText).map { $0 == .done }
        saved[id] = pin
    }

    private func updatePin(from capture: Capture, id: String) {
        guard var pin = saved[id] else { return }
        pin.content = capture.content
        pin.createdAt = capture.createdAt
        pin.mediaType = capture.mediaType
        pin.mediaUrl = capture.mediaUrl
        pin.todoDone = capture.todoState.map { $0 == .done }
        pin.rawText = capture.mediaType == "text" ? capture.rawText : nil
        saved[id] = pin
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
        guard let scope = activeScopeKey, let client = clients.recall() else { return }
        Task { @MainActor in
            guard let capture = try? await client.capture(id: id) else { return }
            guard activeScopeKey == scope, saved[id] != nil,
                  !taskUpdating.contains(id) else { return }
            updatePin(from: capture, id: id)
            persist()
            if let panel = windows[id], let pin = saved[id] {
                setContent(panel, pin: pin)
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let activeScopeKey else { return }
        guard let data = try? Data(contentsOf: ChronicleDesktopPaths.defaultPinsURL()),
              let list = try? JSONDecoder().decode([PersistedPin].self, from: data) else { return }
        for var pin in list where pin.accountScope == activeScopeKey {
            // Pins written before todoDone existed can still recover text-capture
            // state offline from their cached source text. Transcript-only pins
            // remain unknown until their normal best-effort server refresh.
            if pin.todoDone == nil,
               let state = CaptureTodoTag.state(in: pin.content)
            {
                pin.todoDone = state == .done
            }
            saved[pin.id] = pin
        }
    }

    private func persist() {
        guard let activeScopeKey else { return }
        let url = ChronicleDesktopPaths.defaultPinsURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing: [PersistedPin]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([PersistedPin].self, from: data)
            {
                existing = decoded
            } else {
                existing = []
            }
            // Preserve every other account and all legacy unscoped pins verbatim.
            let otherScopes = existing.filter { $0.accountScope != activeScopeKey }
            let data = try JSONEncoder().encode(otherScopes + Array(saved.values))
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

// One persisted sticky. `content`/`mediaType`/`mediaUrl` cache the capture so the
// note renders offline; `frame` (nil until first move/resize) restores its position;
// `manualHeight` records that the user took over sizing. The trailing fields are
// optional so a pins.json written by an earlier build still decodes.
private struct PersistedPin: Codable {
    let id: String
    var content: String
    var createdAt: String
    var mediaType: String?
    var mediaUrl: String?
    var todoDone: Bool?
    var frame: NSRect?
    var manualHeight: Bool?
    var accountScope: String?
    var rawText: String?
}

/// A borderless sticky can't become key by default, so its content never sees the
/// keyboard and Esc never arrives. Allow it to become key (but not main, so it never
/// steals the app's main window), and route Esc to unpin from the window level —
/// there's no focused control inside the note to catch cancelOperation otherwise.
final class KeyableStickyPanel: NSPanel {
    var onEsc: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEsc?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEsc?() } // 53 = Esc
        else { super.keyDown(with: event) }
    }
}
