import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ChronicleDesktop
import ChronicleDesktopCore

@MainActor
@Suite("Main window navigation")
struct MainWindowNavigationTests {
    @Test("sidebar navigation rows have no dead click zone between them")
    func sidebarNavigationRowsMeetAtTheirBoundaries() {
        #expect(MainTabRail.itemSpacing == 0)
    }

    @Test("new Capture sheet accepts either text or a file")
    func newCaptureSheetSaveEligibility() throws {
        let model = MainCaptureSheetModel()
        #expect(!model.canSave)

        model.text = "  remember this  "
        #expect(model.canSave)

        model.text = " \n "
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-sheet-test-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.selectFile(url)
        #expect(model.canSave)
        #expect(model.file?.kind == .cloudAttachment)
    }

    @Test("small images upload directly while generic files use cloud attachments")
    func newCaptureSheetRoutesFilesByType() throws {
        let directory = FileManager.default.temporaryDirectory
        let nonce = UUID().uuidString
        let imageURL = directory.appendingPathComponent("chronicle-sheet-test-\(nonce).png")
        let disguisedImageURL = directory.appendingPathComponent("chronicle-sheet-test-\(nonce).txt")
        let fakeImageURL = directory.appendingPathComponent("chronicle-sheet-test-fake-\(nonce).png")
        let fileURL = directory.appendingPathComponent("chronicle-sheet-test-\(nonce).pdf")
        let onePixelPNG = try #require(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZRM8AAAAASUVORK5CYII="
            )
        )
        try onePixelPNG.write(to: imageURL)
        try onePixelPNG.write(to: disguisedImageURL)
        try Data("not an image".utf8).write(to: fakeImageURL)
        try Data("document".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: disguisedImageURL)
            try? FileManager.default.removeItem(at: fakeImageURL)
            try? FileManager.default.removeItem(at: fileURL)
        }

        #expect(try captureDraftFile(at: imageURL).kind == .directMedia)
        #expect(try captureDraftFile(at: disguisedImageURL).kind == .directMedia)
        #expect(try captureDraftFile(at: fakeImageURL).kind == .cloudAttachment)
        #expect(try captureDraftFile(at: fileURL).kind == .cloudAttachment)
    }

    @Test("new Capture sheet uses a multiline body-font editor")
    func newCaptureSheetUsesNativeEditor() async throws {
        let model = MainCaptureSheetModel()
        let host = NSHostingView(
            rootView: MainCaptureSheet(
                model: model,
                clients: CaptureClients(
                    recall: { nil },
                    webhook: { nil },
                    openSignIn: {},
                    localSearch: { _ in [] },
                    localRecent: { _ in [] },
                    localDelete: { _ in }
                ),
                signedIn: false,
                onSaved: { _ in },
                onRequestSignIn: {},
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textView: SubmitTextView = try #require(
            host.firstDescendant(ofType: SubmitTextView.self)
        )
        #expect(textView.font?.pointSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(textView.submitsOnEnter == false)
        #expect(textView.isVerticallyResizable)
    }

    @Test("capture row actions stay outside the overlay scrollbar")
    func captureActionsReserveScrollbarGutter() {
        let overlayWidth = NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: .overlay
        )
        #expect(DesktopScrollLayout.trailingActionGutter >= overlayWidth)
    }

    @Test("stored plaintext remote endpoint invalidates its bearer token")
    func unsafeStoredEndpointCannotBeUsedWithCredentials() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("http://192.168.1.10:8080", forKey: "apiURL")
        defaults.set("bearer-secret", forKey: "token")

        let config = SettingsStore(defaults: defaults).load()

        #expect(config.apiURL.absoluteString == "http://localhost:8080")
        #expect(config.token.isEmpty)
    }

    @Test("changing API origin clears credentials")
    func changingAPIOriginRequiresFreshSignIn() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://one.example/api", forKey: "apiURL")
        defaults.set("bearer-secret", forKey: "token")
        let store = SettingsStore(defaults: defaults)

        store.saveAPIURL(URL(string: "https://two.example/api")!)

        #expect(store.load().apiURL.absoluteString == "https://two.example/api")
        #expect(store.load().token.isEmpty)
    }

    @Test("changing API path on the same origin keeps credentials")
    func changingAPIPathKeepsSession() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://one.example/api", forKey: "apiURL")
        defaults.set("bearer-secret", forKey: "token")
        let store = SettingsStore(defaults: defaults)

        store.saveAPIURL(URL(string: "https://one.example/v2")!)

        #expect(store.load().token == "bearer-secret")
    }

    @Test("a proven expired session clears credentials and updates open surfaces")
    func expiredSessionUpdatesSettingsModel() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://api.example.com", forKey: "apiURL")
        defaults.set("expired-bearer", forKey: "token")
        let store = SettingsStore(defaults: defaults)
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
        )
        var signInChanges = 0
        let model = SettingsModel(
            settings: store,
            localStore: tempStore(),
            clients: clients,
            onSaveShortcut: { _ in },
            onSignInChanged: { signInChanges += 1 },
            retry: { CaptureSyncSummary() },
        )

        #expect(model.isSignedIn)
        model.handleSessionExpired()

        #expect(!model.isSignedIn)
        #expect(store.load().token.isEmpty)
        #expect(signInChanges == 1)
    }

    @Test("collapsing from the hovered titlebar button does not reopen on button exit")
    func collapseFromHoveredButtonIgnoresExit() {
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        navigation.tabsExpanded = true
        navigation.setTabsButtonHovering(true)
        #expect(navigation.tabsPeeking)

        navigation.toggleTabsExpanded()
        #expect(!navigation.tabsExpanded)
        #expect(!navigation.tabsPeeking)

        navigation.setTabsButtonHovering(false)
        #expect(!navigation.tabsPeeking)
    }

    @Test("expanding clears hover owned by the removed floating overlay")
    func expandingClearsFloatingRailHover() {
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        navigation.tabsExpanded = false
        navigation.setTabsRailHovering(true)
        #expect(navigation.tabsPeeking)

        navigation.toggleTabsExpanded()

        #expect(navigation.tabsExpanded)
        #expect(!navigation.tabsPeeking)
        #expect(!navigation.tabsRailPeeking)
    }

    @Test("floating sidebar uses one growing hover region and no time delay")
    func floatingSidebarUsesContinuousSpatialBuffer() async {
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        navigation.tabsExpanded = false
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
        )
        let settingsModel = SettingsModel(
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            localStore: tempStore(),
            clients: clients,
            onSaveShortcut: { _ in },
            onSignInChanged: {},
            retry: { CaptureSyncSummary() },
        )
        let host = NSHostingView(
            rootView: MainView(clients: clients, navigation: navigation, settingsModel: settingsModel),
        )
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let sensors: [SidebarHoverTrackingView] = host.descendants(
            ofType: SidebarHoverTrackingView.self,
        )
        #expect(sensors.count == 1)
        #expect(sensors.first?.frame.width == MainTabRail.collapsedHoverWidth)
        #expect(MainTabRail.hoverBufferWidth == 54)
        #expect(MainTabRail.floatingHoverWidth == 202)

        var navigationInvalidations = 0
        let invalidation = navigation.objectWillChange.sink {
            navigationInvalidations += 1
        }
        navigation.setTabsRailHovering(true)
        #expect(navigation.tabsPeeking)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let expandedSensors: [SidebarHoverTrackingView] = host.descendants(
            ofType: SidebarHoverTrackingView.self,
        )
        #expect(expandedSensors.count == 1)
        #expect(expandedSensors.first?.frame.width == MainTabRail.floatingHoverWidth)
        #expect(navigationInvalidations == 0)

        navigation.setTabsRailHovering(true)
        #expect(navigationInvalidations == 0)

        navigation.setTabsRailHovering(false)
        #expect(!navigation.tabsPeeking)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        #expect(navigationInvalidations == 0)
        withExtendedLifetime(invalidation) {}
    }

    @Test("cancelled authentication attempts cannot complete later")
    func cancelledAuthenticationAttemptIsRejected() throws {
        var gate = AuthenticationAttemptGate()
        let startedAttempt = gate.begin()
        let attempt = try #require(startedAttempt)
        let concurrentAttempt = gate.begin()

        #expect(concurrentAttempt == nil)
        #expect(gate.accepts(attempt))

        gate.cancel()
        let staleFinishAccepted = gate.finish(attempt)

        #expect(!gate.accepts(attempt))
        #expect(!staleFinishAccepted)
    }

    @Test("MFA challenge advances and can return to primary sign-in")
    func mfaChallengeControlsSignInStep() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
        )
        let settingsModel = SettingsModel(
            settings: SettingsStore(defaults: defaults),
            localStore: tempStore(),
            clients: clients,
            onSaveShortcut: { _ in },
            onSignInChanged: {},
            retry: { CaptureSyncSummary() },
        )
        settingsModel.password = "password123"

        settingsModel.prepareMFA(
            LoginResponse(mfaRequired: true, mfaToken: "short-lived-mfa-token"),
            apiURL: URL(string: "https://api.example.com")!,
        )

        #expect(settingsModel.needsMFA)
        #expect(settingsModel.password.isEmpty)

        settingsModel.mfaCode = "123456"
        settingsModel.backFromMFA()

        #expect(!settingsModel.needsMFA)
        #expect(settingsModel.mfaCode.isEmpty)
    }

    @Test("review is a first-class workspace between browse and ask")
    func reviewWorkspaceNavigationOrder() {
        #expect(MainView.Mode.allCases == [
            .browse, .review, .ask, .trash, .settings,
        ])
        #expect(MainView.Mode.review.icon == "clock.arrow.circlepath")
    }

    @Test("settings scroll viewport stays inside the minimum main window")
    func settingsScrollViewportFitsMinimumWindow() async {
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
        )
        let localStore = tempStore()
        let settingsModel = SettingsModel(
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            localStore: localStore,
            clients: clients,
            onSaveShortcut: { _ in },
            onSignInChanged: {},
            retry: { CaptureSyncSummary() },
        )
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        navigation.mode = .settings
        let host = NSHostingView(
            rootView: MainView(clients: clients, navigation: navigation, settingsModel: settingsModel),
        )
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let scrollView: NSScrollView? = host.firstDescendant(ofType: NSScrollView.self)
        #expect(scrollView != nil)
        guard let scrollView else { return }
        let viewport = scrollView.convert(scrollView.bounds, to: host)

        #expect(host.bounds.contains(viewport))

        let languageControl: NSSegmentedControl? = host.firstDescendant(
            ofType: NSSegmentedControl.self
        )
        let switches: [NSSwitch] = host.descendants(ofType: NSSwitch.self)
        let languageTrailing = languageControl.map {
            $0.convert($0.bounds, to: host).maxX
        }
        #expect(languageTrailing != nil)
        #expect(switches.count >= 2)
        if let languageTrailing {
            for control in switches.prefix(2) {
                let trailing = control.convert(control.bounds, to: host).maxX
                #expect(abs(trailing - languageTrailing) <= 2)
            }
        }
    }

    @Test("ask workspace uses a multiline composer instead of a header field")
    func askWorkspaceUsesMultilineComposer() async {
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
        )
        let settingsModel = SettingsModel(
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            localStore: tempStore(),
            clients: clients,
            onSaveShortcut: { _ in },
            onSignInChanged: {},
            retry: { CaptureSyncSummary() },
        )
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        navigation.mode = .ask
        let host = NSHostingView(
            rootView: MainView(clients: clients, navigation: navigation, settingsModel: settingsModel),
        )
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textView: SubmitTextView? = host.firstDescendant(ofType: SubmitTextView.self)
        let singleLineField: NSTextField? = host.firstDescendant(ofType: NSTextField.self)
        #expect(textView != nil)
        #expect(textView?.isVerticallyResizable == true)
        #expect(singleLineField == nil)
    }

    @Test("capture overflow builds its menu only after a click")
    func captureOverflowAvoidsEmbeddedPopup() async {
        let host = NSHostingView(
            rootView: CaptureRowActions(
                onDelete: nil,
                onOpen: nil,
                onUnlink: nil,
                onPin: {},
            )
            .frame(width: 120, height: 30),
        )
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 30)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let popup: NSPopUpButton? = host.firstDescendant(ofType: NSPopUpButton.self)
        #expect(popup == nil)

        let menu = CaptureRowOverflowMenu.make(
            onOpen: {},
            onEdit: {},
            onPin: {},
            onUnlink: {},
            onDelete: {},
            isPinned: false,
        )
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Open", "Edit", "Pin to desktop", "Remove link", "Delete",
        ])
        #expect(menu.items.dropLast().last?.isSeparatorItem == true)
        let deleteItem = menu.items.first { $0.title == "Delete" }
        let deleteColor = deleteItem?.attributedTitle?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        #expect(deleteColor == .systemRed)
    }

    @Test("capture metadata keeps the compact timestamp in the row")
    func captureMetadataKeepsCompactTimestamp() {
        let createdAt = "2026-07-04T14:35:00Z"
        let metadata = NSHostingView(rootView: CaptureRowMetadata(
            todoState: nil, createdAt: createdAt,
        ))

        #expect(metadata.fittingSize.width < 100)
    }

    @Test("virtualized capture rows do not mount platform text views")
    func captureRowAvoidsPlatformTextView() async {
        let row = RowItem(
            id: "row-1",
            content: "A capture rendered inside a scrolling list",
            createdAt: "2026-07-04T14:35:00Z",
            modality: "text",
            mediaUrl: nil,
        )
        let host = NSHostingView(rootView: CaptureRow(item: row))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textView: NSTextView? = host.firstDescendant(ofType: NSTextView.self)
        #expect(textView == nil)
    }

    @Test("capture edit bubble renders its existing draft")
    func captureEditBubbleRendersDraft() async throws {
        let record = try tempStore().create(CapturePayload(rawText: "ヤニネコ"))
        let row = RowItem(record)
        let host = NSHostingView(rootView: CaptureRow(
            item: row,
            onEdit: { _ in },
            isEditing: true,
            draftText: record.payload.rawText
        ))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 180)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textView: SubmitTextView = try #require(host.firstDescendant(ofType: SubmitTextView.self))
        #expect(textView.string == "ヤニネコ")
        #expect(textView.font?.pointSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(textView.frame.height > 0)
        #expect((textView.textContainer?.size.width ?? 0) > 0)
    }

    @Test("mounted editors follow an updated preferred font size")
    func modeTextEditorUpdatesItsNativeFont() async throws {
        func editor(fontSize: CGFloat) -> ModeTextEditor {
            ModeTextEditor(
                text: .constant("Capture"),
                focused: .constant(false),
                placeholder: "",
                submitsOnEnter: false,
                onSubmit: {},
                onCancel: {},
                onHeight: { _ in },
                fontSize: fontSize,
            )
        }

        let host = NSHostingView(rootView: editor(fontSize: 12))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        host.layoutSubtreeIfNeeded()
        await Task.yield()

        host.rootView = editor(fontSize: 16)
        host.layoutSubtreeIfNeeded()
        await Task.yield()

        let textView: SubmitTextView = try #require(
            host.firstDescendant(ofType: SubmitTextView.self)
        )
        #expect(textView.font?.pointSize == 16)
    }

    @Test("delete planning sends unsynced search rows to local delete")
    func deletePlanningUsesLocalDeleteForUnsyncedRows() throws {
        let store = tempStore()
        let record = try store.create(CapturePayload(rawText: "local search result"))
        let found = try #require(store.search("local").first)
        let row = RowItem(found)

        #expect(captureDeletePlan(for: row, hasServerClient: true) == .localOnly(id: record.id))
        #expect(captureDeletePlan(for: row, hasServerClient: false) == .localOnly(id: record.id))
    }

    @Test("delete planning requires a client for synced rows")
    func deletePlanningRequiresServerForSyncedRows() throws {
        let store = tempStore()
        let record = try store.create(CapturePayload(rawText: "synced search result"))
        try store.markSynced(localId: record.id, serverId: "server-1")
        let found = try #require(store.search("synced").first)
        let row = RowItem(found)

        #expect(captureDeletePlan(for: row, hasServerClient: true) == .serverThenLocal(id: "server-1"))
        #expect(captureDeletePlan(for: row, hasServerClient: false) == .unavailable)
    }

    @Test("selectable text forwards cancel to the panel action")
    func selectableTextForwardsCancel() {
        let textView = SelectableRowText.RowTextView()
        var cancelCount = 0
        textView.onCancel = { cancelCount += 1 }

        textView.cancelOperation(nil)

        #expect(cancelCount == 1)
    }

    @Test("selectable text preserves IME composition on cancel")
    func selectableTextPreservesMarkedText() {
        let textView = SelectableRowText.RowTextView()
        var cancelCount = 0
        textView.onCancel = { cancelCount += 1 }
        textView.setMarkedText("candidate", selectedRange: NSRange(location: 0, length: 9), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())

        textView.cancelOperation(nil)

        #expect(cancelCount == 0)
    }

    @Test("capture input preserves IME composition on cancel")
    func captureInputPreservesMarkedText() {
        let textView = SubmitTextView()
        var cancelCount = 0
        textView.onCancel = { cancelCount += 1 }
        textView.setMarkedText("candidate", selectedRange: NSRange(location: 0, length: 9), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())

        textView.cancelOperation(nil)

        #expect(cancelCount == 0)
    }

    @Test("quick panel forwards cancel when no text responder handles it")
    func quickPanelForwardsCancel() {
        let panel = QuickCapturePanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var cancelCount = 0
        panel.onCancel = { cancelCount += 1 }

        panel.cancelOperation(nil)

        #expect(cancelCount == 1)
    }

    private func tempStore() -> LocalCaptureStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-main-window-tests-\(UUID().uuidString).sqlite")
        return LocalCaptureStore(fileURL: url)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }

    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? []
                + subview.descendants(ofType: type)
        }
    }
}
