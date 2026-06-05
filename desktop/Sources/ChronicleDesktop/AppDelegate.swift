import AppKit
import Carbon
import ChronicleDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: QuickCapturePanelController!
    private var hotKeyController: HotKeyController?
    private let settings = SettingsStore()
    private let queue = CaptureQueue(fileURL: ChronicleDesktopPaths.defaultQueueURL())

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        panelController = QuickCapturePanelController(onSubmit: saveCapture)
        installStatusItem()
        installHotKey()

        if settings.load().isUsable == false {
            showSettings()
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Chronicle"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quick Capture", action: #selector(showQuickCaptureAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Retry Queue", action: #selector(retryQueueAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettingsAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))
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

    @objc private func showQuickCaptureAction() {
        showQuickCapture()
    }

    @objc private func retryQueueAction() {
        retryQueuedCaptures()
    }

    @objc private func showSettingsAction() {
        showSettings()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func showQuickCapture() {
        NSApp.activate(ignoringOtherApps: true)
        panelController.show()
    }

    private func saveCapture(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let payload = CapturePayload(rawText: trimmed)
        guard let client = makeClient() else {
            queueCapture(payload)
            showNotification(title: "Capture queued", body: "Add an API token in Settings.")
            return
        }

        Task { [queue] in
            do {
                try await client.send(payload)
                await MainActor.run {
                    self.showNotification(title: "Capture saved", body: trimmed)
                }
            } catch {
                do {
                    try queue.append(payload)
                    await MainActor.run {
                        self.showNotification(title: "Capture queued", body: "Chronicle API was unavailable.")
                    }
                } catch {
                    await MainActor.run {
                        self.showNotification(title: "Capture failed", body: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func retryQueuedCaptures() {
        guard let client = makeClient() else {
            showSettings()
            return
        }

        Task { [queue] in
            do {
                let result = try await queue.retry(using: client)
                await MainActor.run {
                    self.showNotification(
                        title: "Queue retried",
                        body: "Sent \(result.sent), remaining \(result.remaining).",
                    )
                }
            } catch {
                await MainActor.run {
                    self.showNotification(title: "Retry failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func queueCapture(_ payload: CapturePayload) {
        do {
            try queue.append(payload)
        } catch {
            showNotification(title: "Queue failed", body: error.localizedDescription)
        }
    }

    private func makeClient() -> CaptureAPIClient? {
        let config = settings.load()
        guard config.isUsable else {
            return nil
        }
        return CaptureAPIClient(config: config)
    }

    private func showSettings() {
        let current = settings.load()
        let currentShortcut = settings.loadShortcut()
        let alert = NSAlert()
        alert.messageText = "Sign in to Chronicle"
        alert.informativeText = "Use your Chronicle email and password. Click the shortcut field, then press a shortcut."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 118)

        let emailField = NSTextField()
        emailField.placeholderString = "Email"
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = "Password"
        let shortcutField = ShortcutRecorderField(shortcut: currentShortcut)

        stack.addArrangedSubview(emailField)
        stack.addArrangedSubview(passwordField)
        stack.addArrangedSubview(shortcutField)
        alert.accessoryView = stack

        if alert.runModal() == .alertFirstButtonReturn {
            saveShortcut(shortcutField.shortcut)
            if emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               passwordField.stringValue.isEmpty
            {
                settings.save(current)
                showNotification(title: "Settings saved", body: "Quick capture settings updated.")
            } else {
                login(apiURL: current.apiURL, email: emailField.stringValue, password: passwordField.stringValue)
            }
        }
    }

    private func saveShortcut(_ spec: ShortcutSpec) {
        settings.saveShortcut(spec)
        installHotKey()
    }

    private func login(apiURL: URL, email: String, password: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            showNotification(title: "Login failed", body: "Email and password are required.")
            return
        }

        let client = AuthAPIClient(apiURL: apiURL)
        Task {
            do {
                let response = try await client.login(email: trimmedEmail, password: password)
                if response.mfaRequired == true {
                    throw AuthAPIError.mfaRequired
                }
                guard let token = response.accessToken, !token.isEmpty else {
                    throw AuthAPIError.missingAccessToken
                }
                await MainActor.run {
                    self.settings.save(ChronicleConfig(apiURL: apiURL, token: token))
                    self.showNotification(title: "Login saved", body: "Quick capture is ready.")
                }
            } catch AuthAPIError.mfaRequired {
                await MainActor.run {
                    self.showNotification(title: "MFA required", body: "Desktop MFA login is not implemented yet.")
                }
            } catch {
                await MainActor.run {
                    self.showNotification(title: "Login failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func showNotification(title: String, body: String) {
        statusItem.button?.title = title
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem.button?.title = "Chronicle"
        }
    }
}
