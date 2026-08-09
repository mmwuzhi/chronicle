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
    private let captureSession = CaptureSession()
    private var verifiedSessionScope: LocalCaptureScope?
    private var identityVerificationTask: Task<Void, Never>?
    private var statusItemFeedbackActive = false
    private var statusItemFeedbackGeneration = 0
    private lazy var captureSyncCoordinator = CaptureSyncCoordinator(store: localStore)
    // Offline semantic search over the local cache via a local Ollama. Lazy so it
    // can reference localStore; degrades to keyword search when Ollama is absent.
    private lazy var localSemantic = LocalSemanticSearch(store: localStore, embedder: LocalEmbedder())
    private lazy var googleDriveAuthorizer = GoogleDriveAuthorizer()
    private let googleDriveClient = GoogleDriveClient()
    private var reminderNotifier: ReminderNotifier?
    // Retained: UNUserNotificationCenter keeps only a weak reference to its delegate.
    private var notificationDelegate: ReminderNotificationDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if E2ERunner.isEnabled {
            localStore.activate(.testing)
            E2ERunner(delegate: self).run()
            return
        }

        // A persisted binding is safe for offline use only on the same API
        // origin. Remote clients remain disabled until /users/me verifies the
        // current token below.
        localStore.activate(settings.loadLocalCaptureScope())
        cleanupStaleCaptureTemporaryFiles()
        installApplicationMenu()
        // The former JSON queue and pre-scope SQLite rows have no trustworthy
        // account identity. Keep them on disk, but never adopt them into whichever
        // account happens to sign in next.
        // Warm the active account's on-device semantic index in the background.
        Task { await localSemantic.ensureIndexed() }
        clients = makeClients()
        panelController = QuickCapturePanelController(
            clients: clients,
            onSubmit: { [weak self] text, remindAt, keepVisible in
                self?.saveCapture(text, remindAt: remindAt, keepVisible: keepVisible)
                    ?? .failed(L("We couldn't save this Capture. Try again."))
            },
        )
        detailWindowController = CaptureDetailWindowController(clients: clients)
        pinnedStickyController = PinnedStickyController(
            recall: clients.recall,
            initialScope: localStore.scope
        )
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
        let startingConfig = settings.load()
        let generation = captureSession.snapshot()
        let apiURL = startingConfig.apiURL
        Task { @MainActor in
            let result: Result<String, Error>
            do {
                result = .success(try await AuthAPIClient(apiURL: apiURL).refresh())
            } catch {
                result = .failure(error)
            }
            // A sign-in, sign-out, or server change while this request was in
            // flight owns the newer session. Never let the stale result replace
            // its token or clear it via the expired-session path.
            guard sessionRefreshStillCurrent(
                startedWith: startingConfig,
                current: settings.load()
            ), captureSession.isCurrent(generation) else { return }
            // A 401 here is the exact signal the weeks-signed-out incident lacked:
            // surface sign-in status. A network failure stays quiet (offline-first).
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
    private lazy var authRefresher = AuthRefresher(
        mint: { [weak self] requestToken in
            await self?.mintToken(refreshing: requestToken)
        },
        permitsRetry: { [weak self] _, refresh in
            await self?.permitsRetry(with: refresh) ?? false
        }
    )

    // Surfaces sign-out. The app once sat signed out for weeks, silently queuing
    // captures; the monitor invalidates the stale local session and updates the
    // sign-in surfaces when a refresh is rejected (401). A network error never
    // trips it (offline-first). onChange re-reads current health so racing
    // callbacks converge on the final state.
    private lazy var sessionMonitor = SessionMonitor { [weak self] _ in
        Task { @MainActor in self?.sessionHealthChanged() }
    }

    private func mintToken(refreshing requestToken: String) async -> AuthRefreshResult? {
        let generation = captureSession.snapshot()
        let startingConfig = settings.load()
        guard startingConfig.isUsable, startingConfig.token == requestToken else {
            return nil
        }
        let apiURL = startingConfig.apiURL
        let result: Result<String, Error>
        do {
            result = .success(try await AuthAPIClient(apiURL: apiURL).refresh())
        } catch {
            result = .failure(error)
        }
        guard sessionRefreshStillCurrent(
            startedWith: startingConfig,
            current: settings.load()
        ), captureSession.isCurrent(generation) else { return nil }
        sessionMonitor.apply(sessionSignal(forRefreshResult: result))
        guard case .success(let token) = result else { return nil }
        let refreshed = ChronicleConfig(apiURL: apiURL, token: token)
        // A rotating refresh cookie is still a credential, not an identity.
        // Re-verify it before allowing the request that triggered refresh to retry.
        // If it unexpectedly belongs to a different account, transition the app
        // after verification but never replay the old account's operation as it.
        guard let identity = try? await UserIdentityAPIClient(config: refreshed).me(),
              let scope = LocalCaptureScope(apiURL: apiURL, userID: identity.id)
        else { return nil }
        guard captureSession.isCurrent(generation) else { return nil }
        settings.save(refreshed)
        guard scope == verifiedSessionScope else {
            handleSignInChanged()
            return nil
        }
        return AuthRefreshResult(token: token, sessionGeneration: generation)
    }

    private func permitsRetry(with refresh: AuthRefreshResult) -> Bool {
        guard captureSession.isCurrent(refresh.sessionGeneration) else { return false }
        guard let config = verifiedConfig() else { return false }
        return config.token == refresh.token
    }

    // Snapshot for the sign-in nudge: signed-out (proven-expired) + queued count.
    private func currentSessionStatus() -> SessionStatus {
        SessionStatus(
            signedOut: sessionMonitor.health == .expired,
            pending: (try? localStore.syncBacklog().total) ?? 0,
        )
    }

    // Keep the normal menu bar glyph stable across account states. A signed-out
    // session is routine, not an app failure; the tooltip carries that detail.
    private func sessionHealthChanged() {
        // Multiple refresh/sign-in callbacks may already be queued onto the main
        // actor. Read the converged state now instead of acting on a stale value
        // captured before a newer login completed.
        let health = sessionMonitor.health
        // A session transition supersedes transient save feedback so the icon
        // immediately reflects whether any local work is still waiting to sync.
        statusItemFeedbackGeneration &+= 1
        statusItemFeedbackActive = false
        if health == .expired {
            settingsModel?.handleSessionExpired()
        }
        updateStatusItemAppearance()
    }

    @objc private func capturesChangedForStatusItem() {
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let status = currentSessionStatus()
        button.title = ""
        button.imagePosition = .imageOnly
        if !statusItemFeedbackActive {
            button.image = statusItemImage(named: status.statusItemSymbolName)
        }
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
        } else if status.pending > 0 {
            button.toolTip = DesktopLocalization.shared.format(
                status.pending == 1
                    ? "Chronicle · %d Capture waiting to sync"
                    : "Chronicle · %d Captures waiting to sync",
                status.pending
            )
        } else {
            button.toolTip = "Chronicle"
        }
        button.setAccessibilityLabel(button.toolTip)
        installStatusItemMenu(for: status)
    }

    private func statusItemImage(named name: String) -> NSImage? {
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Chronicle")
            ?? NSImage(
                systemSymbolName: "tray.and.arrow.down.fill",
                accessibilityDescription: "Chronicle"
            )
        icon?.isTemplate = true
        return icon
    }

    private func makeClients() -> CaptureClients {
        CaptureClients(
            session: captureSession,
            recall: { [weak self] in
                guard let self, let config = self.verifiedConfig() else { return nil }
                return config.isUsable
                    ? RecallAPIClient(config: config, refresher: self.authRefresher) : nil
            },
            webhook: { [weak self] in
                guard let self, let config = self.verifiedConfig() else { return nil }
                return config.isUsable
                    ? WebhookAPIClient(config: config, refresher: self.authRefresher) : nil
            },
            share: { [weak self] in
                guard let self, let config = self.verifiedConfig() else { return nil }
                return config.isUsable
                    ? CaptureShareAPIClient(config: config, refresher: self.authRefresher) : nil
            },
            openSignIn: { [weak self] in self?.showSignIn() },
            createCapture: { [unowned self] payload in
                RowItem(try self.createCaptureAndScheduleSync(payload, postChange: false))
            },
            uploadMedia: { [unowned self] upload in
                try await self.uploadMediaCapture(upload)
            },
            attachFile: { [unowned self] upload, text, remindAt, remindHide in
                try await self.attachFileCapture(
                    upload,
                    text: text,
                    remindAt: remindAt,
                    remindHide: remindHide
                )
            },
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
        reminderNotifier = ReminderNotifier(store: localStore, makeClient: { [weak self] in
            guard let self, let config = self.verifiedConfig() else { return nil }
            return ReminderAPIClient(config: config, refresher: self.authRefresher)
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Reflect whatever the launch refresh has already resolved (or the neutral
        // default until it does), then track every session change from here on.
        updateStatusItemAppearance()
    }

    private func installStatusItemMenu(for status: SessionStatus) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Quick Capture"), action: #selector(showQuickCaptureAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Open Chronicle"), action: #selector(showMainAction), keyEquivalent: ""))
        menu.addItem(.separator())
        switch status.menuAction {
        case .signIn:
            let title = status.pending > 0
                ? DesktopLocalization.shared.format(
                    status.pending == 1
                        ? "Sign in and sync %d Capture…"
                        : "Sign in and sync %d Captures…",
                    status.pending
                )
                : L("Sign In…")
            menu.addItem(NSMenuItem(
                title: title,
                action: #selector(showSignInAction),
                keyEquivalent: ""
            ))
        case .retrySync:
            menu.addItem(NSMenuItem(
                title: DesktopLocalization.shared.format("Retry Sync (%d)", status.pending),
                action: #selector(retryPendingCapturesAction),
                keyEquivalent: ""
            ))
        case nil:
            break
        }
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

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("File"))
        let newCaptureItem = NSMenuItem(
            title: L("New Capture"),
            action: #selector(showMainCaptureAction),
            keyEquivalent: "n"
        )
        newCaptureItem.target = self
        fileMenu.addItem(newCaptureItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

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
    @objc private func showMainCaptureAction() {
        mainWindowController.show(mode: .browse)
        NotificationCenter.default.post(name: .chronicleFocusMainCapture, object: nil)
    }
    @objc private func showSignInAction() { showSignIn() }
    @objc private func retryPendingCapturesAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await retrySummary()
            if result.remaining == 0, result.status == .completed {
                showStatusItemSuccess()
            } else {
                updateStatusItemAppearance()
            }
        }
    }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func languageChanged() {
        installApplicationMenu()
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

    // Rebind the local cache only after the server proves which user owns the
    // current token. A token change is an untrusted identity transition until
    // GET /users/me succeeds; during that gap every local account is hidden and
    // every remote client/sync path is disabled.
    private func handleSignInChanged() {
        // Invalidate every async result before touching credentials, identity, or
        // account-scoped state. Detail windows are account content, so scrub them
        // rather than leaving A visible while B is being verified.
        captureSession.advance()
        detailWindowController?.closeAll()
        googleDriveAuthorizer.invalidate()
        identityVerificationTask?.cancel()
        identityVerificationTask = nil
        verifiedSessionScope = nil

        let config = settings.load()
        guard config.isUsable else {
            // Explicit sign-out/expiry: the last verified same-origin account is
            // still a safe, explicit offline boundary.
            localStore.activate(settings.loadLocalCaptureScope())
            reminderNotifier?.accountScopeChanged()
            pinnedStickyController?.activate(localStore.scope)
            sessionMonitor.apply(.expired)
            CaptureEvents.postChanged()
            return
        }

        // Never leave the previously active account visible while a new token is
        // being identified (the common A → sign out → B transition).
        localStore.activate(nil)
        reminderNotifier?.accountScopeChanged()
        pinnedStickyController?.activate(nil)
        CaptureEvents.postChanged()

        let verificationGeneration = captureSession.snapshot()
        identityVerificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let identity = try await UserIdentityAPIClient(
                        config: config,
                        refresher: self.authRefresher
                    ).me()
                    let current = self.settings.load()
                    guard !Task.isCancelled,
                          self.captureSession.isCurrent(verificationGeneration),
                          current.isUsable,
                          LocalCaptureScope.origin(of: current.apiURL)
                            == LocalCaptureScope.origin(of: config.apiURL),
                          let scope = LocalCaptureScope(
                            apiURL: config.apiURL,
                            userID: identity.id
                          )
                    else { return }

                    // Identity verification is its own boundary: callbacks from
                    // the quarantined pre-verification phase cannot write into
                    // the newly active account.
                    self.settings.saveVerifiedLocalCaptureScope(scope)
                    self.verifiedSessionScope = scope
                    self.localStore.activate(scope)
                    self.sessionMonitor.apply(.active)
                    let verifiedGeneration = self.captureSession.advance()
                    self.googleDriveAuthorizer.invalidate()
                    self.reminderNotifier?.accountScopeChanged()
                    self.pinnedStickyController?.activate(scope)
                    self.pinnedStickyController?.refreshAll()
                    CaptureEvents.postChanged()
                    await self.localSemantic.ensureIndexed()
                    guard !Task.isCancelled,
                          self.captureSession.isCurrent(verifiedGeneration)
                    else { return }
                    if let client = self.makeClient() {
                        _ = await self.syncPendingCaptures(using: client)
                    }
                    return
                } catch AuthAPIError.httpStatus(401) {
                    guard !Task.isCancelled,
                          self.captureSession.isCurrent(verificationGeneration)
                    else { return }
                    self.sessionMonitor.apply(.expired)
                    return
                } catch {
                    // Network/server uncertainty is not proof of either identity.
                    // Keep the cache quarantined and retry until connectivity
                    // returns or a newer sign-in/origin transition cancels us.
                    try? await Task.sleep(for: .seconds(5))
                }
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

    private func saveCapture(
        _ text: String,
        remindAt: Date?,
        keepVisible: Bool
    ) -> QuickCaptureSaveResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(L("We couldn't save this Capture. Try again."))
        }

        var payload = CapturePayload(rawText: trimmed)
        payload.remindAt = remindAt
        // Notify-only: keep it visible in browse. Only meaningful with a reminder;
        // nil otherwise lets the server default (hide until due) stand.
        if remindAt != nil && keepVisible {
            payload.remindHide = false
        }

        do {
            _ = try createCaptureAndScheduleSync(payload, postChange: true)
            showStatusItemSuccess()
            return .saved
        } catch {
            return .failed(L("We couldn't save this Capture. Try again."))
        }
    }

    /// Shared local-first creation path for the quick panel and main-window
    /// composer. A missing session is a normal success: the record remains in
    /// the local backlog and sign-in replay handles it later.
    private func createCaptureAndScheduleSync(
        _ payload: CapturePayload,
        postChange: Bool
    ) throws -> LocalCaptureRecord {
        let record = try localStore.create(payload)
        if postChange {
            CaptureEvents.postChanged()
        }
        reminderNotifier?.schedule(record)
        // Embed independently of server sync so offline recall sees it too.
        Task { await localSemantic.ensureIndexed() }
        if let client = makeClient() {
            Task {
                await sync(record, using: client, notifySuccess: false)
            }
        }
        return record
    }

    private func uploadMediaCapture(_ upload: CaptureMediaUpload) async throws -> RowItem {
        let generation = captureSession.snapshot()
        guard let config = verifiedConfig() else {
            throw CaptureClientError.requiresSignIn
        }
        let uploaded = try await CaptureMediaUploadClient(
            config: config,
            refresher: authRefresher
        ).upload(upload)
        guard !Task.isCancelled, captureSession.isCurrent(generation) else {
            throw CancellationError()
        }
        let payload = CapturePayload(
            rawText: upload.text,
            mediaType: uploaded.mediaType,
            remindAt: upload.remindAt,
            remindHide: upload.remindHide
        )
        let createdAt = uploaded.createdAt.flatMap(Self.parseISO) ?? Date()
        if let record = try? localStore.cacheServerCapture(
            serverId: uploaded.id,
            payload: payload,
            createdAt: createdAt
        ) {
            reminderNotifier?.schedule(record)
            Task { await localSemantic.ensureIndexed() }
        }
        return RowItem(
            id: uploaded.id,
            content: upload.text,
            createdAt: uploaded.createdAt ?? ISO8601DateFormatter().string(from: createdAt),
            modality: uploaded.mediaType,
            mediaUrl: uploaded.mediaUrl
        )
    }

    private func attachFileCapture(
        _ upload: CloudCaptureFileUpload,
        text: String,
        remindAt: Date?,
        remindHide: Bool?
    ) async throws -> RowItem {
        let generation = captureSession.snapshot()
        guard let config = verifiedConfig() else {
            throw CaptureClientError.requiresSignIn
        }
        guard let clientID = GoogleDriveConfiguration.clientID() else {
            throw GoogleDriveError.notConfigured
        }
        var accessToken = try await googleDriveAuthorizer.authorize(clientID: clientID)
        guard !Task.isCancelled, captureSession.isCurrent(generation) else {
            throw CancellationError()
        }
        var attachment: CloudAttachmentDraft
        do {
            attachment = try await googleDriveClient.upload(
                fileURL: upload.fileURL,
                sizeBytes: upload.sizeBytes,
                filename: upload.filename,
                mimeType: upload.mimeType,
                operationId: upload.operationId,
                accessToken: accessToken
            )
            guard !Task.isCancelled, captureSession.isCurrent(generation) else {
                throw CancellationError()
            }
        } catch GoogleDriveError.httpStatus(401) {
            googleDriveAuthorizer.invalidate()
            accessToken = try await googleDriveAuthorizer.authorize(clientID: clientID)
            guard !Task.isCancelled, captureSession.isCurrent(generation) else {
                throw CancellationError()
            }
            do {
                attachment = try await googleDriveClient.upload(
                    fileURL: upload.fileURL,
                    sizeBytes: upload.sizeBytes,
                    filename: upload.filename,
                    mimeType: upload.mimeType,
                    operationId: upload.operationId,
                    accessToken: accessToken
                )
                guard !Task.isCancelled, captureSession.isCurrent(generation) else {
                    throw CancellationError()
                }
            } catch GoogleDriveError.httpStatus(401) {
                // Do not cache a token that the provider has already rejected.
                // The next user retry must start a fresh authorization flow.
                googleDriveAuthorizer.invalidate()
                throw GoogleDriveError.httpStatus(401)
            }
        }
        let payload = CapturePayload(
            rawText: text.isEmpty ? upload.filename : text,
            remindAt: remindAt,
            remindHide: remindHide
        )
        let created = try await CaptureWithAttachmentAPIClient(
            config: config,
            refresher: authRefresher
        ).create(
            operationId: upload.operationId,
            text: payload.rawText,
            remindAt: remindAt,
            remindHide: remindHide,
            attachment: attachment
        )
        guard !Task.isCancelled, captureSession.isCurrent(generation) else {
            throw CancellationError()
        }
        // Never compensate an API error by deleting the Drive object. A previous
        // ambiguous attempt may already have committed a reference to that exact
        // operation file; automatic deletion would turn a safe retry into data loss.
        if let record = try? localStore.cacheServerCapture(
            serverId: created.id,
            payload: payload
        ) {
            reminderNotifier?.schedule(record)
            Task { await localSemantic.ensureIndexed() }
        }
        return RowItem(created)
    }

    // Kept as the minimal persistence seam used by the executable E2E runner.
    func persistCapture(_ payload: CapturePayload) throws -> LocalCaptureRecord {
        let record = try localStore.create(payload)
        CaptureEvents.postChanged()
        return record
    }

    func syncPendingCaptures(using client: CaptureAPIClient) async -> CaptureSyncSummary {
        let generation = captureSession.snapshot()
        let summary = await captureSyncCoordinator.syncPending(using: client)
        if captureSession.isCurrent(generation), summary.changed {
            CaptureEvents.postChanged()
        }
        return summary
    }

    private func pushPendingCaptureUpdates(using client: CaptureAPIClient) async {
        let generation = captureSession.snapshot()
        let summary = await captureSyncCoordinator.pushPendingUpdates(using: client)
        if captureSession.isCurrent(generation), summary.changed {
            CaptureEvents.postChanged()
        }
    }

    @discardableResult
    func sync(_ record: LocalCaptureRecord, using client: CaptureAPIClient, notifySuccess: Bool) async -> Bool {
        let generation = captureSession.snapshot()
        let outcome = await captureSyncCoordinator.sync(record, using: client)
        guard captureSession.isCurrent(generation) else { return false }
        switch outcome {
        case .synced:
            CaptureEvents.postChanged()
            if notifySuccess {
                await MainActor.run {
                    self.showStatusItemSuccess()
                }
            }
            return true
        case .failed:
            if notifySuccess {
                await MainActor.run {
                    self.updateStatusItemAppearance()
                }
            }
            return false
        case .alreadyInFlight:
            return false
        }
    }

    func syncServerReminders(using client: ReminderAPIClient) async {
        let pending = (try? await client.pending()) ?? []
        guard let scope = localStore.scope else { return }
        let defaults: UserDefaults
        if let databasePath = ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_DB_PATH"] {
            let databaseID = URL(fileURLWithPath: databasePath)
                .deletingLastPathComponent().lastPathComponent
            defaults = UserDefaults(suiteName: "chronicle.e2e.reminders.\(databaseID)") ?? .standard
        } else {
            defaults = .standard
        }
        let dueSynchronizer = ReminderDueSynchronizer(defaults: defaults)
        let dueBatch = try? await dueSynchronizer.fetch(using: client, scope: scope)
        for item in pending {
            guard let at = item.remindAt.flatMap(Self.parseISO) else { continue }
            _ = try? localStore.upsertServerReminder(serverId: item.id, text: item.summary, remindAt: at)
        }
        if let dueBatch {
            do {
                for item in dueBatch.items {
                    let at = item.remindAt.flatMap(Self.parseISO) ?? Date()
                    if let record = try localStore.upsertDueServerReminder(
                        serverId: item.id,
                        text: item.summary,
                        remindAt: at
                    ) {
                        // The executable E2E harness has no notification center;
                        // reaching here represents successful delivery.
                        try localStore.markNotified(localId: record.id)
                    }
                }
                dueSynchronizer.commit(dueBatch, for: scope)
            } catch {
                // Leave the checkpoint unchanged. A later sync retries the
                // complete window; already persisted rows remain deduplicated.
            }
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
        guard let config = verifiedConfig() else { return nil }
        return CaptureAPIClient(config: config, refresher: authRefresher)
    }

    private func verifiedConfig() -> ChronicleConfig? {
        let config = settings.load()
        guard config.isUsable,
              let verifiedSessionScope,
              localStore.scope == verifiedSessionScope,
              LocalCaptureScope.origin(of: config.apiURL) == verifiedSessionScope.apiOrigin
        else { return nil }
        return config
    }

    // Capture is a high-frequency keyboard action, so feedback replaces the icon
    // in place without animation, sound, or a variable-width status-item title.
    private func showStatusItemSuccess() {
        statusItemFeedbackGeneration &+= 1
        let generation = statusItemFeedbackGeneration
        statusItemFeedbackActive = true
        statusItem.button?.title = ""
        statusItem.button?.image = statusItemImage(named: "checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard self?.statusItemFeedbackGeneration == generation else { return }
            self?.statusItemFeedbackActive = false
            self?.updateStatusItemAppearance()
        }
    }
}
