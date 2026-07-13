import AppKit
import Foundation
import Testing
@testable import ChronicleDesktop
import ChronicleDesktopCore

@MainActor
@Suite("Main window navigation")
struct MainWindowNavigationTests {
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

    @Test("collapsing from the hovered titlebar button does not reopen on button exit")
    func collapseFromHoveredButtonIgnoresExitGrace() {
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
