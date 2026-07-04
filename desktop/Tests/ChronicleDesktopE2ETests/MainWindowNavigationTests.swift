import Foundation
import Testing
@testable import ChronicleDesktop
import ChronicleDesktopCore

@MainActor
@Suite("Main window navigation")
struct MainWindowNavigationTests {
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

    private func tempStore() -> LocalCaptureStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-main-window-tests-\(UUID().uuidString).sqlite")
        return LocalCaptureStore(fileURL: url)
    }
}
