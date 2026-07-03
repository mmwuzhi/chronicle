import Foundation
import Testing

@testable import ChronicleDesktopCore

@Test
func capturePayloadUsesDesktopDefaults() {
    let payload = CapturePayload(rawText: "Follow up on report")

    #expect(payload.mediaType == "text")
    #expect(payload.source == desktopQuickCaptureSource)
}

@Test
func decodesQueuedCaptureFromBeforeTodoFacet() throws {
    // Offline queues serialized by pre-todo-facet builds carry the removed
    // classifiedAs field; replaying them must decode (unknown keys ignored).
    let json = Data(
        """
        {"payload":{"rawText":"queued while offline","mediaType":"text",
         "classifiedAs":"unclassified","source":"desktop_quick_capture"},
         "queuedAt":712345678.0}
        """.utf8)

    let queued = try JSONDecoder().decode(QueuedCapture.self, from: json)

    #expect(queued.payload.rawText == "queued while offline")
    #expect(queued.payload.source == desktopQuickCaptureSource)
}

@Test
func apiClientBuildsCaptureRequest() throws {
    let config = ChronicleConfig(apiURL: URL(string: "http://localhost:8080")!, token: "test-token")
    let client = CaptureAPIClient(config: config)

    let request = try client.makeRequest(for: CapturePayload(rawText: "Quick note"))

    #expect(request.url?.absoluteString == "http://localhost:8080/captures")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(CapturePayload.self, from: body)
    #expect(decoded.rawText == "Quick note")
    #expect(decoded.source == desktopQuickCaptureSource)
}

@Test
func authClientBuildsLoginRequest() throws {
    let client = AuthAPIClient(apiURL: URL(string: "http://localhost:8080")!)

    let request = try client.makeLoginRequest(email: "test@example.com", password: "password")

    #expect(request.url?.absoluteString == "http://localhost:8080/auth/login")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(LoginRequest.self, from: body)
    #expect(decoded.email == "test@example.com")
    #expect(decoded.password == "password")
}

@Test
func hotKeyParserParsesDefaultShortcut() throws {
    let spec = try #require(HotKeyParser.parse("control+option+space"))

    #expect(spec == HotKeyParser.defaultSpec)
    #expect(HotKeyParser.displayString(for: spec) == "control+option+space")
}

@Test
func shortcutParserDefaultsToDoubleControl() throws {
    let spec = try #require(ShortcutParser.parse("Double Control"))

    #expect(spec == ShortcutParser.defaultSpec)
    #expect(ShortcutParser.displayString(for: spec) == "Double Control")
}

@Test
func shortcutParserStillSupportsHotKeys() throws {
    let spec = try #require(ShortcutParser.parse("control+option+space"))

    #expect(ShortcutParser.displayString(for: spec) == "control+option+space")
}

@Test
func hotKeyParserParsesAliases() throws {
    let spec = try #require(HotKeyParser.parse("cmd+shift+k"))

    #expect(HotKeyParser.displayString(for: spec) == "command+shift+k")
}

@Test
func queueAppendsAndLoadsCaptures() throws {
    let queue = CaptureQueue(fileURL: temporaryQueueURL())
    let date = Date(timeIntervalSince1970: 1_800)

    try queue.append(CapturePayload(rawText: "Queue this"), queuedAt: date)

    let captures = try queue.load()
    #expect(captures == [QueuedCapture(payload: CapturePayload(rawText: "Queue this"), queuedAt: date)])
}

@Test
func retryQueueRemovesSentCaptures() async throws {
    let queue = CaptureQueue(fileURL: temporaryQueueURL())
    try queue.append(CapturePayload(rawText: "First"))
    try queue.append(CapturePayload(rawText: "Second"))

    let sender = StubSender(failingTexts: ["Second"])
    let result = try await queue.retry(using: sender)

    #expect(result.sent == 1)
    #expect(result.remaining == 1)
    #expect(try queue.load().map(\.payload.rawText) == ["Second"])
    #expect(result.uploaded == [UploadedCapture(id: "server-First", reminderLocalId: nil)])
}

@Test
func localCaptureStorePersistsPendingCaptureAndReminder() throws {
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let remindAt = Date(timeIntervalSince1970: 2_000)
    let createdAt = Date(timeIntervalSince1970: 1_800)

    let record = try store.create(
        CapturePayload(rawText: "Local first", remindAt: remindAt),
        now: createdAt,
    )

    #expect(record.payload.rawText == "Local first")
    #expect(record.payload.remindAt == remindAt)
    #expect(record.serverId == nil)
    #expect(record.notificationId == "rmd-local-\(record.id)")

    let pending = try store.pendingSync()
    #expect(pending.map(\.id) == [record.id])

    let reminders = try store.upcomingReminders(now: Date(timeIntervalSince1970: 1_900))
    #expect(reminders.map(\.id) == [record.id])
}

@Test
func localCaptureStorePersistsNotifyOnlyAcrossReload() throws {
    // A Keep-visible (notify-only) capture saved offline must round-trip its flag
    // through the local store so a later sync retry still sends hide=false; without
    // persistence it would default to hide and vanish from browse until due.
    let url = temporaryDatabaseURL()
    let notifyOnly = try LocalCaptureStore(fileURL: url).create(
        CapturePayload(rawText: "pinned sticky", remindAt: Date(timeIntervalSince1970: 5_000), remindHide: false),
    )
    let hidden = try LocalCaptureStore(fileURL: url).create(
        CapturePayload(rawText: "resurface later", remindAt: Date(timeIntervalSince1970: 5_000)),
    )

    // Re-open the store (fresh instance) to prove it survives a relaunch, and read
    // through pendingSync — the exact path the offline retry uses.
    let pending = try LocalCaptureStore(fileURL: url).pendingSync()
    let reloadedNotifyOnly = try #require(pending.first { $0.id == notifyOnly.id })
    let reloadedHidden = try #require(pending.first { $0.id == hidden.id })
    #expect(reloadedNotifyOnly.payload.remindHide == false)
    #expect(reloadedHidden.payload.remindHide == nil) // default → server applies hide
}

@Test
func localCaptureStoreMarksCaptureSynced() throws {
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "Sync me"))

    try store.markSynced(localId: record.id, serverId: "server-1", syncedAt: Date(timeIntervalSince1970: 2_100))

    #expect(try store.pendingSync().isEmpty)
    let found = try store.find(serverId: "server-1")
    let synced = try #require(found)
    #expect(synced.id == record.id)
    #expect(synced.isSynced)
}

@Test
func localCaptureStoreUpsertsServerReminderWithoutDuplicating() throws {
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let remindAt = Date(timeIntervalSince1970: 3_000)

    let first = try store.upsertServerReminder(serverId: "server-2", text: "From web", remindAt: remindAt)
    let second = try store.upsertServerReminder(
        serverId: "server-2",
        text: "Updated from web",
        remindAt: remindAt.addingTimeInterval(60),
    )

    #expect(first.id == second.id)
    #expect(second.payload.rawText == "Updated from web")
    #expect(try store.count() == 1)
}

@Test
func localCaptureStoreMarksDueServerReminderNotifiedOnce() throws {
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let remindAt = Date(timeIntervalSince1970: 3_000)

    let first = try store.upsertDueServerReminder(
        serverId: "server-due",
        text: "Already due",
        remindAt: remindAt,
        now: Date(timeIntervalSince1970: 3_100),
    )
    let second = try store.upsertDueServerReminder(
        serverId: "server-due",
        text: "Already due",
        remindAt: remindAt,
        now: Date(timeIntervalSince1970: 3_200),
    )

    #expect(first != nil)
    #expect(first?.notifiedAt == Date(timeIntervalSince1970: 3_100))
    #expect(second == nil)
}

@Test
func localCaptureStoreDoesNotReNotifyLocallyScheduledReminderAfterSync() throws {
    // Regression: a reminder created locally schedules a calendar trigger (which
    // ReminderNotifier marks notified) and then syncs to the server. When the
    // reminder later shows up in the server `due` list, the due path must NOT post
    // a second notification — the local trigger already covers delivery.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    var payload = CapturePayload(rawText: "Local reminder")
    payload.remindAt = Date(timeIntervalSince1970: 3_000)
    let record = try store.create(payload)

    // Calendar trigger scheduled → marked notified, then synced to the server.
    try store.markNotified(localId: record.id, now: Date(timeIntervalSince1970: 2_900))
    try store.markSynced(localId: record.id, serverId: "server-local-1")

    // Server reports the same reminder due on a later launch.
    let dueAgain = try store.upsertDueServerReminder(
        serverId: "server-local-1",
        text: "Local reminder",
        remindAt: Date(timeIntervalSince1970: 3_000),
        now: Date(timeIntervalSince1970: 3_100),
    )

    #expect(dueAgain == nil)         // no duplicate notification
    #expect(try store.count() == 1)  // still the same single row
}

private func temporaryQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "queue.json")
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "chronicle.sqlite3")
}

private final class StubSender: CaptureSending {
    private let failingTexts: Set<String>

    init(failingTexts: Set<String> = []) {
        self.failingTexts = failingTexts
    }

    func send(_ payload: CapturePayload) async throws -> String {
        if failingTexts.contains(payload.rawText) {
            throw CaptureAPIError.httpStatus(500)
        }
        return "server-\(payload.rawText)"
    }
}
