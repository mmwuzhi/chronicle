import Foundation
import Testing

@testable import ChronicleDesktopCore

private let testConfig = ChronicleConfig(
    apiURL: URL(string: "http://localhost:8080")!,
    token: "test-token",
)

@Test
func dueRequestBuildsGETWithBearerAndSince() throws {
    let client = ReminderAPIClient(config: testConfig)

    let request = client.makeDueRequest(since: "2026-06-18T00:00:00Z")

    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/reminders/due")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "since", value: "2026-06-18T00:00:00Z")))
}

@Test
func dueRequestCarriesBoundedWindowAndStablePageCursor() throws {
    let client = ReminderAPIClient(config: testConfig)

    let request = client.makeDueRequest(
        since: "2026-06-18T00:00:00Z",
        until: "2026-06-19T00:00:00Z",
        beforeAt: "2026-06-18T12:00:00Z",
        beforeID: "d2ebedc1-c6b2-40f4-a789-8e48064252a1",
        limit: 25
    )

    let url = try #require(request.url)
    let items = try #require(
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "until", value: "2026-06-19T00:00:00Z")))
    #expect(items.contains(URLQueryItem(name: "beforeAt", value: "2026-06-18T12:00:00Z")))
    #expect(
        items.contains(
            URLQueryItem(
                name: "beforeId",
                value: "d2ebedc1-c6b2-40f4-a789-8e48064252a1")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "25")))
}

@Test
func dueRequestOmitsSinceWhenNil() throws {
    let client = ReminderAPIClient(config: testConfig)

    let request = client.makeDueRequest(since: nil)

    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/reminders/due")
    #expect(components.queryItems == nil)
}

@Test
func reminderCheckpointIsPartitionedByAccountScope() throws {
    let suite = "ReminderTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let synchronizer = ReminderDueSynchronizer(defaults: defaults)
    let firstScope = try #require(
        LocalCaptureScope(
            apiURL: URL(string: "https://chronicle.example")!,
            userID: "first-user"))
    let secondScope = try #require(
        LocalCaptureScope(
            apiURL: URL(string: "https://chronicle.example")!,
            userID: "second-user"))
    let checkpoint = Date(timeIntervalSince1970: 1_750_204_800)

    defaults.set(
        checkpoint,
        forKey: "chronicle.reminders.due-checkpoint.\(firstScope.persistenceKey)")

    #expect(synchronizer.checkpoint(for: firstScope) == checkpoint)
    #expect(synchronizer.checkpoint(for: secondScope) == nil)
}

@Test
func reminderCheckpointAdvancesOnlyAfterDurableHandlingCommits() throws {
    let suite = "ReminderTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let synchronizer = ReminderDueSynchronizer(defaults: defaults)
    let scope = try #require(
        LocalCaptureScope(
            apiURL: URL(string: "https://chronicle.example")!,
            userID: "durability-user"))
    let checkpoint = Date(timeIntervalSince1970: 1_750_204_800)
    let fetched = ReminderDueBatch(items: [], checkpoint: checkpoint)

    // Merely fetching/preparing a batch must not skip it if local persistence
    // subsequently fails or the app crashes.
    #expect(synchronizer.checkpoint(for: scope) == nil)

    synchronizer.commit(fetched, for: scope)
    #expect(synchronizer.checkpoint(for: scope) == checkpoint)
}

@Test
func pendingRequestBuildsGETWithBearer() {
    let client = ReminderAPIClient(config: testConfig)

    let request = client.makePendingRequest()

    #expect(request.url?.absoluteString == "http://localhost:8080/reminders/pending")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
}

@Test
func decodesReminderItemsIgnoringExtraCaptureFields() throws {
    let json = Data(
        """
        [
          {"id":"d2ebedc1-c6b2-40f4-a789-8e48064252a1","rawText":"call the dentist",
           "transcript":null,"remindAt":"2026-06-18T09:00:00Z","createdAt":"2026-06-17T10:00:00Z",
           "mediaType":"text","classifiedAs":"unclassified","source":"web","transcriptionStatus":"none"}
        ]
        """.utf8)

    let items = try JSONDecoder().decode([ReminderItem].self, from: json)

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.id == "d2ebedc1-c6b2-40f4-a789-8e48064252a1")
    #expect(item.summary == "call the dentist")
    #expect(item.remindAt == "2026-06-18T09:00:00Z")
}

@Test
func orphanedServerRemindersTargetsSyncedRemindersMissingFromPending() {
    let soon = Date().addingTimeInterval(3600)
    func record(id: String, serverId: String?) -> LocalCaptureRecord {
        LocalCaptureRecord(
            id: id,
            scope: .testing,
            payload: CapturePayload(rawText: "reminder", remindAt: soon),
            createdAt: Date(), updatedAt: Date(),
            serverId: serverId, syncedAt: serverId == nil ? nil : Date(),
            editRevision: 0, syncedRevision: 0,
            lastError: nil, notifiedAt: nil)
    }

    let local = [
        record(id: "l-alive", serverId: "srv-alive"),  // still on server → keep
        record(id: "l-gone", serverId: "srv-gone"),  // deleted elsewhere → orphan
        record(id: "l-unsynced", serverId: nil),  // never synced → not reconcilable
    ]

    // pending() reported only the still-live reminder, so the deleted one is an
    // orphan and the unsynced one is left alone.
    let orphans = orphanedServerReminders(
        local: local, alivePendingServerIds: ["srv-alive"])

    #expect(
        orphans == [OrphanedReminder(serverId: "srv-gone", notificationId: "rmd-local-l-gone")])
}

@Test
func summaryFallsBackToTranscriptThenGeneric() {
    let withTranscript = ReminderItem(
        id: "1", rawText: nil, transcript: "transcribed receipt",
        remindAt: nil, createdAt: "2026-06-17T10:00:00Z")
    #expect(withTranscript.summary == "transcribed receipt")

    let empty = ReminderItem(
        id: "2", rawText: "", transcript: "",
        remindAt: nil, createdAt: "2026-06-17T10:00:00Z")
    #expect(empty.summary == "A capture is due")
}
