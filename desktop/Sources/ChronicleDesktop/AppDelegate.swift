import AppKit
import Carbon
import ChronicleDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var clients: CaptureClients!
    private var panelController: QuickCapturePanelController!
    private var mainWindowController: MainWindowController!
    private var detailWindowController: CaptureDetailWindowController!
    private var pinnedStickyController: PinnedStickyController!
    private var settingsModel: SettingsModel!
    private var hotKeyController: HotKeyController?
    private let settings = SettingsStore()
    private let localStore = LocalCaptureStore(fileURL: ChronicleDesktopPaths.defaultLocalDatabaseURL())
    // Offline semantic search over the local cache via a local Ollama. Lazy so it
    // can reference localStore; degrades to keyword search when Ollama is absent.
    private lazy var localSemantic = LocalSemanticSearch(store: localStore, embedder: LocalEmbedder())
    private var reminderNotifier: ReminderNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if E2ERunner.isEnabled {
            E2ERunner(delegate: self).run()
            return
        }

        installApplicationMenu()
        drainLegacyQueue()
        // Warm the on-device semantic index in the background (embeds any captures
        // missing a vector, including ones just drained from the legacy queue).
        Task { await localSemantic.ensureIndexed() }
        clients = makeClients()
        panelController = QuickCapturePanelController(
            clients: clients,
            onSubmit: { [weak self] text, remindAt, keepVisible in
                self?.saveCapture(text, remindAt: remindAt, keepVisible: keepVisible)
            },
        )
        detailWindowController = CaptureDetailWindowController(clients: clients)
        pinnedStickyController = PinnedStickyController(recall: clients.recall)
        // Double-clicking a sticky opens that capture in a detail window.
        pinnedStickyController.onOpen = { [weak self] row in self?.detailWindowController?.open(row) }
        settingsModel = SettingsModel(
            settings: settings,
            localStore: localStore,
            clients: clients,
            onSaveShortcut: { [weak self] _ in self?.installHotKey() },
            onSignInChanged: { [weak self] in self?.handleSignInChanged() },
            retry: { [weak self] in await self?.retrySummary() ?? (0, 0) },
        )
        mainWindowController = MainWindowController(clients: clients, settingsModel: settingsModel)

        installStatusItem()
        installHotKey()
        installReminderNotifier()
        refreshSessionIfPossible()
        // Rebuild pinned stickies from cache now (works offline); refreshSessionIfPossible
        // → handleSignInChanged refreshes their content once a token lands.
        pinnedStickyController.restore()

        if settings.load().isUsable == false {
            mainWindowController.show()
        }
    }

    // Silent auto-login on launch: if a valid refresh cookie is on file (30-day
    // TTL, set at the last sign-in), trade it for a fresh access token so the user
    // stays signed in across launches instead of being dropped to the login gate
    // every time the 15-minute access token lapses. A failure is a no-op — the app
    // simply stays in offline/local mode.
    private func refreshSessionIfPossible() {
        let apiURL = settings.load().apiURL
        Task { @MainActor in
            guard let token = try? await AuthAPIClient(apiURL: apiURL).refresh() else { return }
            settings.save(ChronicleConfig(apiURL: apiURL, token: token))
            handleSignInChanged()
        }
    }

    // Shared by every API client: when a 15-minute access token lapses mid-session,
    // the client's 401 funnels here for a fresh one instead of stalling until the
    // next launch. @MainActor (AppDelegate is) so it can touch `settings`; the
    // AuthRefresher actor single-flights concurrent callers onto one mint.
    private lazy var authRefresher = AuthRefresher { [weak self] in
        await self?.mintToken()
    }

    private func mintToken() async -> String? {
        let apiURL = settings.load().apiURL
        guard let token = try? await AuthAPIClient(apiURL: apiURL).refresh() else { return nil }
        settings.save(ChronicleConfig(apiURL: apiURL, token: token))
        return token
    }

    private func makeClients() -> CaptureClients {
        CaptureClients(
            recall: { [settings, authRefresher] in
                let config = settings.load()
                return config.isUsable
                    ? RecallAPIClient(config: config, refresher: authRefresher) : nil
            },
            webhook: { [settings, authRefresher] in
                let config = settings.load()
                return config.isUsable
                    ? WebhookAPIClient(config: config, refresher: authRefresher) : nil
            },
            openSettings: { [weak self] in self?.showSettings() },
            openDetail: { [weak self] row in self?.detailWindowController?.open(row) },
            togglePin: { [weak self] row in self?.pinnedStickyController?.toggle(row) },
            isPinned: { [weak self] id in self?.pinnedStickyController?.isPinned(id) ?? false },
            localSearch: { [localStore] q in
                (try? localStore.search(q))?.map(RowItem.init) ?? []
            },
            localSemanticSearch: { [localSemantic] q in
                (await localSemantic.search(q))?.map(RowItem.init) ?? []
            },
            localRecent: { [localStore] limit in
                (try? localStore.recent(limit: limit))?.map(RowItem.init) ?? []
            },
            localDelete: { [localStore] id in try? localStore.delete(id: id) },
        )
    }

    // One-time migration: the app moved from a JSON queue (CaptureQueue) to the
    // SQLite LocalCaptureStore. Drain captures still stranded in the old queue into
    // the store so they become locally searchable and sync-eligible, then clear it.
    // Idempotent — the emptied queue has nothing to drain on the next launch.
    private func drainLegacyQueue() {
        let queue = CaptureQueue(fileURL: ChronicleDesktopPaths.defaultQueueURL())
        guard let queued = try? queue.load(), !queued.isEmpty else { return }
        // Drop only the items we actually persisted. If localStore.create throws
        // (e.g. a corrupt or locked SQLite store), keep that capture in the queue
        // for the next launch to retry instead of clearing it wholesale and losing
        // it. Still idempotent: a fully drained queue has nothing left to migrate.
        var unpersisted: [QueuedCapture] = []
        for item in queued {
            do {
                _ = try localStore.create(item.payload, now: item.queuedAt)
            } catch {
                unpersisted.append(item)
            }
        }
        try? queue.replace(with: unpersisted)
    }

    private func installReminderNotifier() {
        // UNUserNotificationCenter traps without a bundle id, i.e. under a bare
        // `swift run` / `make desktop-capture`. Only schedule from the packaged
        // .app (`make desktop-app`); dev runs simply skip notifications.
        guard Bundle.main.bundleIdentifier != nil else { return }
        reminderNotifier = ReminderNotifier(store: localStore, makeClient: { [settings, authRefresher] in
            let config = settings.load()
            return config.isUsable
                ? ReminderAPIClient(config: config, refresher: authRefresher) : nil
        })
        reminderNotifier?.start()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                           accessibilityDescription: "Chronicle")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quick Capture", action: #selector(showQuickCaptureAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Chronicle", action: #selector(showMainAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Chronicle", action: #selector(quitAction), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Chronicle", action: #selector(quitAction), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func installHotKey() {
        hotKeyController = HotKeyController(spec: settings.loadShortcut()) { [weak self] in
            self?.showQuickCapture()
        }
    }

    @objc private func showQuickCaptureAction() { showQuickCapture() }
    @objc private func showMainAction() { mainWindowController.show() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func showQuickCapture() {
        panelController.show()
    }

    private func showSettings() {
        mainWindowController.show(mode: .settings)
    }

    // Re-sync reminders + offline captures after the signed-in state changes.
    private func handleSignInChanged() {
        reminderNotifier?.syncFromServer()
        // Refresh pinned stickies' content now that a token is available (on launch
        // they restore from cache before the silent refresh completes).
        pinnedStickyController?.refreshAll()
        Task { @MainActor in
            if let client = makeClient() {
                _ = await syncPendingCaptures(using: client)
            }
        }
    }

    private func retrySummary() async -> (sent: Int, remaining: Int) {
        guard let client = makeClient() else {
            let remaining = (try? localStore.pendingSync(limit: 1000).count) ?? 0
            return (0, remaining)
        }
        let result = await syncPendingCaptures(using: client)
        return (result.sent, result.remaining)
    }

    private func saveCapture(_ text: String, remindAt: Date?, keepVisible: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        var payload = CapturePayload(rawText: trimmed)
        payload.remindAt = remindAt
        // Notify-only: keep it visible in browse. Only meaningful with a reminder;
        // nil otherwise lets the server default (hide until due) stand.
        if remindAt != nil && keepVisible {
            payload.remindHide = false
        }

        do {
            let record = try persistCapture(payload)
            reminderNotifier?.schedule(record)
            // Embed the new capture in the background so it becomes semantically
            // searchable offline, independent of whether it ever syncs.
            Task { await localSemantic.ensureIndexed() }

            guard let client = makeClient() else {
                showNotification(title: "Saved locally — sign in to sync", body: trimmed)
                return
            }

            showNotification(title: "Capture saved", body: trimmed)
            Task {
                await sync(record, using: client, notifySuccess: false)
            }
        } catch {
            showNotification(title: "Capture failed", body: error.localizedDescription)
            return
        }
    }

    struct SyncSummary {
        var sent: Int
        var remaining: Int
    }

    func persistCapture(_ payload: CapturePayload) throws -> LocalCaptureRecord {
        try localStore.create(payload)
    }

    func syncPendingCaptures(using client: CaptureAPIClient) async -> SyncSummary {
        let pending: [LocalCaptureRecord]
        do {
            pending = try localStore.pendingSync()
        } catch {
            return SyncSummary(sent: 0, remaining: 0)
        }

        var sent = 0
        for record in pending {
            if await sync(record, using: client, notifySuccess: false) {
                sent += 1
            }
        }
        let remaining = (try? localStore.pendingSync().count) ?? 0
        return SyncSummary(sent: sent, remaining: remaining)
    }

    @discardableResult
    func sync(_ record: LocalCaptureRecord, using client: CaptureAPIClient, notifySuccess: Bool) async -> Bool {
        do {
            let serverId = try await client.send(record.payload)
            try localStore.markSynced(localId: record.id, serverId: serverId)
            if notifySuccess {
                await MainActor.run {
                    self.showNotification(title: "Capture synced", body: record.payload.rawText)
                }
            }
            return true
        } catch {
            try? localStore.markFailed(localId: record.id, error: error)
            if notifySuccess {
                await MainActor.run {
                    self.showNotification(title: "Capture saved locally", body: "Sync will retry later.")
                }
            }
            return false
        }
    }

    func syncServerReminders(using client: ReminderAPIClient) async {
        let pending = (try? await client.pending()) ?? []
        let due = (try? await client.due(since: nil)) ?? []
        for item in pending {
            guard let at = item.remindAt.flatMap(Self.parseISO) else { continue }
            _ = try? localStore.upsertServerReminder(serverId: item.id, text: item.summary, remindAt: at)
        }
        for item in due {
            let at = item.remindAt.flatMap(Self.parseISO) ?? Date()
            _ = try? localStore.upsertDueServerReminder(serverId: item.id, text: item.summary, remindAt: at)
        }
    }

    private static func parseISO(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private func makeClient() -> CaptureAPIClient? {
        let config = settings.load()
        guard config.isUsable else {
            return nil
        }
        return CaptureAPIClient(config: config, refresher: authRefresher)
    }

    // A quiet status-item title flash for capture feedback. No sound — the old
    // NSSound.beep() on every capture was removed (it was jarring on each save).
    private func showNotification(title: String, body _: String) {
        statusItem.button?.title = "  \(title)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem.button?.title = ""
        }
    }
}
