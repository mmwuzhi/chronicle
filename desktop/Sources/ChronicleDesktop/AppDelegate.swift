import AppKit
import Carbon
import ChronicleDesktopCore
import UserNotifications

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
    private lazy var captureSyncCoordinator = CaptureSyncCoordinator(store: localStore)
    // Offline semantic search over the local cache via a local Ollama. Lazy so it
    // can reference localStore; degrades to keyword search when Ollama is absent.
    private lazy var localSemantic = LocalSemanticSearch(store: localStore, embedder: LocalEmbedder())
    private var reminderNotifier: ReminderNotifier?
    // Retained: UNUserNotificationCenter keeps only a weak reference to its delegate.
    private var notificationDelegate: ReminderNotificationDelegate?

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
            retry: { [weak self] in
                await self?.retrySummary() ?? CaptureSyncSummary(status: .failed)
            },
        )
        mainWindowController = MainWindowController(clients: clients, settingsModel: settingsModel)

        installStatusItem()
        // A capture saved while signed out bumps the queue; keep the menu bar
        // tooltip's "N waiting to sync" fresh without waiting for a session flip.
        NotificationCenter.default.addObserver(
            self, selector: #selector(capturesChangedForStatusItem),
            name: .chronicleCapturesChanged, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .chronicleLanguageChanged, object: nil,
        )
        installHotKey()
        installReminderNotifier()
        refreshSessionIfPossible()
        // Rebuild pinned stickies from cache now (works offline); refreshSessionIfPossible
        // → handleSignInChanged refreshes their content once a token lands.
        pinnedStickyController.restore()

        // First-run onboarding only. A signed-out *returning* user must not get
        // an uninvited window at every launch — it lands on whatever Space is
        // active, including over a fullscreen app; their signed-out state shows
        // in Settings and the quick panel instead.
        if settings.load().isUsable == false && settings.hasSignedInOnce == false {
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
            let result: Result<String, Error>
            do {
                result = .success(try await AuthAPIClient(apiURL: apiURL).refresh())
            } catch {
                result = .failure(error)
            }
            // A 401 here is the exact signal the weeks-signed-out incident lacked:
            // flip the badge. A network failure stays quiet (offline-first).
            sessionMonitor.apply(sessionSignal(forRefreshResult: result))
            guard case .success(let token) = result else { return }
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

    // Surfaces sign-out. The app once sat signed out for weeks, silently queuing
    // captures; the monitor flips the menu bar badge / banner the moment a refresh
    // is rejected (401) and clears it on a fresh token — a network error never
    // trips it (offline-first). onChange re-reads current health so racing
    // callbacks converge on the final state.
    private lazy var sessionMonitor = SessionMonitor { [weak self] _ in
        Task { @MainActor in self?.sessionHealthChanged() }
    }

    private func mintToken() async -> String? {
        let apiURL = settings.load().apiURL
        let result: Result<String, Error>
        do {
            result = .success(try await AuthAPIClient(apiURL: apiURL).refresh())
        } catch {
            result = .failure(error)
        }
        sessionMonitor.apply(sessionSignal(forRefreshResult: result))
        guard case .success(let token) = result else { return nil }
        settings.save(ChronicleConfig(apiURL: apiURL, token: token))
        return token
    }

    // Snapshot for the sign-in nudge: signed-out (proven-expired) + queued count.
    private func currentSessionStatus() -> SessionStatus {
        SessionStatus(
            signedOut: sessionMonitor.health == .expired,
            pending: (try? localStore.syncBacklog().total) ?? 0,
        )
    }

    // Menu bar icon + tooltip are the only sign-in surface — react to session
    // health changes by refreshing the status-item glyph and tooltip.
    private func sessionHealthChanged() {
        updateStatusItemAppearance()
    }

    @objc private func capturesChangedForStatusItem() {
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let status = currentSessionStatus()
        button.image = statusItemImage(signedOut: status.signedOut)
        if status.signedOut {
            let n = status.pending
            button.toolTip = n > 0
                ? DesktopLocalization.shared.format(
                    n == 1
                        ? "Chronicle — signed out · %d capture waiting to sync"
                        : "Chronicle — signed out · %d captures waiting to sync",
                    n
                )
                : L("Chronicle — signed out · sign in to sync")
        } else {
            button.toolTip = "Chronicle"
        }
    }

    private func statusItemImage(signedOut: Bool) -> NSImage? {
        // A distinct glyph (not just a color — status-bar template images render
        // monochrome) so a signed-out state is noticeable at a glance; the tooltip
        // carries the pending count.
        let name = signedOut ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill"
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Chronicle")
        icon?.isTemplate = true
        return icon
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
            openSignIn: { [weak self] in self?.showSignIn() },
            openDetail: { [weak self] row in self?.detailWindowController?.open(row) },
            openDetailForEditing: { [weak self] row in
                self?.detailWindowController?.open(row, beginEditing: true)
            },
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
            localSetText: { [localStore] id, text in
                ((try? localStore.setText(id: id, rawText: text)) ?? 0) > 0
            },
            syncEdits: { [weak self] in
                guard let self, let client = self.makeClient() else { return }
                await self.pushPendingCaptureUpdates(using: client)
            },
        )
    }

    // One-time migration: the app moved from a JSON queue (CaptureQueue) to the
    // SQLite LocalCaptureStore. Drain captures still stranded in the old queue into
    // the store so they become locally searchable and sync-eligible, then clear it.
    // Idempotent — the emptied queue has nothing to drain on the next launch.
    // Runs at launch before any window exists, so it deliberately skips
    // CaptureEvents.postChanged(); if it ever runs mid-session, post it so open
    // lists rebuild.
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
        // The delegate must be in place before the authorization request in
        // start(), or reminders due while the agent runs are silently suppressed.
        notificationDelegate = ReminderNotificationDelegate(onOpenCapture: { [weak self] localId in
            self?.openCaptureFromNotification(localId)
        })
        UNUserNotificationCenter.current().delegate = notificationDelegate
        reminderNotifier = ReminderNotifier(store: localStore, makeClient: { [settings, authRefresher] in
            let config = settings.load()
            return config.isUsable
                ? ReminderAPIClient(config: config, refresher: authRefresher) : nil
        })
        reminderNotifier?.start()
    }

    // Tapping a reminder notification opens that capture's detail window. The row
    // comes from the local cache; a capture deleted since scheduling is a no-op.
    private func openCaptureFromNotification(_ localId: String) {
        guard let record = try? localStore.find(localId: localId) else { return }
        detailWindowController?.open(RowItem(record))
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Reflect whatever the launch refresh has already resolved (or the neutral
        // default until it does), then track every session change from here on.
        updateStatusItemAppearance()

        installStatusItemMenu()
    }

    private func installStatusItemMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Quick Capture"), action: #selector(showQuickCaptureAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Open Chronicle"), action: #selector(showMainAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Settings…"), action: #selector(showSettingsAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Chronicle"), action: #selector(quitAction), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit Chronicle"), action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
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

    @objc private func languageChanged() {
        installApplicationMenu()
        installStatusItemMenu()
        updateStatusItemAppearance()
    }

    private func showQuickCapture() {
        panelController.show()
    }

    private func showSettings() {
        mainWindowController.show(mode: .settings)
    }

    private func showSignIn() {
        mainWindowController.show(mode: .ask)
        settingsModel.presentSignIn()
    }

    // Re-sync reminders + offline captures after the signed-in state changes.
    private func handleSignInChanged() {
        // Sign-in and sign-out both funnel here (Settings toggles + launch
        // refresh), so the real config decides which: a usable token means live,
        // its absence means the user is signed out. This is what clears the badge
        // the instant a sign-in lands and raises it on an explicit sign-out.
        sessionMonitor.apply(settings.load().isUsable ? .active : .expired)
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

    private func retrySummary() async -> CaptureSyncSummary {
        guard let client = makeClient() else {
            do {
                let backlog = try localStore.syncBacklog()
                return CaptureSyncSummary(
                    pendingCreates: backlog.pendingCreates,
                    pendingUpdates: backlog.pendingUpdates
                )
            } catch {
                return CaptureSyncSummary(status: .failed)
            }
        }
        return await syncPendingCaptures(using: client)
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
                showNotification(title: L("Saved locally — sign in to sync"), body: trimmed)
                return
            }

            showNotification(title: L("Capture saved"), body: trimmed)
            Task {
                await sync(record, using: client, notifySuccess: false)
            }
        } catch {
            showNotification(title: L("Capture failed"), body: error.localizedDescription)
            return
        }
    }

    func persistCapture(_ payload: CapturePayload) throws -> LocalCaptureRecord {
        let record = try localStore.create(payload)
        CaptureEvents.postChanged()
        return record
    }

    func syncPendingCaptures(using client: CaptureAPIClient) async -> CaptureSyncSummary {
        let summary = await captureSyncCoordinator.syncPending(using: client)
        if summary.changed {
            CaptureEvents.postChanged()
        }
        return summary
    }

    private func pushPendingCaptureUpdates(using client: CaptureAPIClient) async {
        let summary = await captureSyncCoordinator.pushPendingUpdates(using: client)
        if summary.changed {
            CaptureEvents.postChanged()
        }
    }

    @discardableResult
    func sync(_ record: LocalCaptureRecord, using client: CaptureAPIClient, notifySuccess: Bool) async -> Bool {
        let outcome = await captureSyncCoordinator.sync(record, using: client)
        switch outcome {
        case .synced:
            CaptureEvents.postChanged()
            if notifySuccess {
                await MainActor.run {
                    self.showNotification(title: L("Capture synced"), body: record.payload.rawText)
                }
            }
            return true
        case .failed:
            if notifySuccess {
                await MainActor.run {
                    self.showNotification(title: L("Capture saved locally"), body: L("Sync will retry later."))
                }
            }
            return false
        case .alreadyInFlight:
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
