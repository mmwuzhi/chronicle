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
func apiEndpointRequiresHTTPSExceptForLoopback() {
    #expect(ChronicleAPIEndpoint.validated("https://api.example.com") != nil)
    #expect(ChronicleAPIEndpoint.validated("http://localhost:8080") != nil)
    #expect(ChronicleAPIEndpoint.validated("http://127.0.0.2:8080") != nil)
    #expect(ChronicleAPIEndpoint.validated("http://[::1]:8080") != nil)

    #expect(ChronicleAPIEndpoint.validated("http://api.example.com") == nil)
    #expect(ChronicleAPIEndpoint.validated("http://192.168.1.10:8080") == nil)
    #expect(ChronicleAPIEndpoint.validated("http://127.evil.example:8080") == nil)
    #expect(ChronicleAPIEndpoint.validated("http://127.0.0.1.evil.example:8080") == nil)
    #expect(ChronicleAPIEndpoint.validated("ftp://localhost") == nil)
    #expect(ChronicleAPIEndpoint.validated("https://user:secret@example.com") == nil)
    #expect(ChronicleAPIEndpoint.validated("https:missing-host") == nil)
}

@Test
func captureSyncGateSingleFlightsEachLocalCapture() {
    let gate = CaptureSyncGate()

    #expect(gate.begin("capture-1"))
    #expect(!gate.begin("capture-1"))
    #expect(gate.begin("capture-2"))

    gate.end("capture-1")
    #expect(gate.begin("capture-1"))
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
func localCaptureStoreFindsByLocalIdBeforeAndAfterSync() throws {
    // The local id is what a reminder notification's userInfo carries; it must
    // resolve the same row both while the capture is still local-only and after
    // markSynced rekeys it with a server id (the notification may fire days later).
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "Find me"))

    let beforeSync = try #require(try store.find(localId: record.id))
    #expect(beforeSync.payload.rawText == "Find me")

    try store.markSynced(localId: record.id, serverId: "server-9")
    let afterSync = try #require(try store.find(localId: record.id))
    #expect(afterSync.serverId == "server-9")

    #expect(try store.find(localId: "missing") == nil)
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

@Test
func localCaptureStoreEditFlagsSyncedRowDirtyForPush() throws {
    // Editing an already-synced row must surface it in pendingUpdates (an offline
    // PATCH-back) with the new text — never back in pendingSync, which is only for
    // rows that were never created on the server.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "original"))
    try store.markSynced(
        localId: record.id, serverId: "server-e1", syncedAt: Date(timeIntervalSince1970: 1_000))

    // Freshly synced: updated_at == synced_at, so nothing is dirty yet.
    #expect(try store.pendingUpdates().isEmpty)

    let changed = try store.setText(
        id: "server-e1", rawText: "edited offline", now: Date(timeIntervalSince1970: 2_000))
    #expect(changed == 1)

    let dirty = try store.pendingUpdates()
    #expect(dirty.map(\.serverId) == ["server-e1"])
    #expect(dirty.first?.payload.rawText == "edited offline")
    #expect(try store.pendingSync().isEmpty) // an edit is not a create
}

@Test
func localCaptureStoreEditOnUnsyncedRowStaysInCreateQueue() throws {
    // Editing a not-yet-synced row must carry the new text into its eventual create
    // (pendingSync), not appear as a separate update — it has no server id to PATCH.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "draft"))

    let changed = try store.setText(id: record.id, rawText: "draft revised")
    #expect(changed == 1)

    let pending = try store.pendingSync()
    #expect(pending.map(\.payload.rawText) == ["draft revised"])
    #expect(try store.pendingUpdates().isEmpty)
}

@Test
func localCaptureStoreSetTextReturnsZeroForUnknownRow() throws {
    // A server-only browse fragment isn't in the local cache; setText must report
    // 0 changes so the caller falls back to editing directly against the server.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    #expect(try store.setText(id: "not-cached", rawText: "x") == 0)
}

@Test
func localCaptureStoreMarkUpdatePushedClearsDirtyOnlyWhenNothingChangedMeanwhile() throws {
    // markUpdatePushed advances synced_at to the pushed updated_at. When no re-edit
    // raced the PATCH the row goes clean; when one did (updated_at moved past the
    // pushed value), it stays dirty so the concurrent edit is re-pushed, never lost.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "v0"))
    try store.markSynced(
        localId: record.id, serverId: "server-race", syncedAt: Date(timeIntervalSince1970: 1_000))

    // Edit 1 — the drain reads this row's updated_at (t2) before PATCHing.
    try store.setText(id: "server-race", rawText: "v1", now: Date(timeIntervalSince1970: 2_000))
    let pushed = try #require(try store.pendingUpdates().first)
    #expect(pushed.updatedAt == Date(timeIntervalSince1970: 2_000))

    // Edit 2 lands during the round-trip, bumping updated_at to t3.
    try store.setText(id: "server-race", rawText: "v2", now: Date(timeIntervalSince1970: 3_000))

    // PATCH of v1 completes: synced_at only advances to t2, not to "now".
    try store.markUpdatePushed(localId: record.id, syncedAt: pushed.updatedAt)

    // updated_at (t3) still exceeds synced_at (t2) → still dirty, v2 re-pushes.
    let stillDirty = try store.pendingUpdates()
    #expect(stillDirty.map(\.serverId) == ["server-race"])
    #expect(stillDirty.first?.payload.rawText == "v2")

    // Pushing v2 with its own updated_at finally clears the dirty flag.
    try store.markUpdatePushed(localId: record.id, syncedAt: Date(timeIntervalSince1970: 3_000))
    #expect(try store.pendingUpdates().isEmpty)
}

@Test
func localCaptureStoreEditClearsStaleEmbedding() throws {
    // On-device semantic search ranks the cached vector, which indexed the *old*
    // text. Editing must drop that vector (rowsNeedingEmbedding only re-embeds a
    // missing/different-model one) or semantic recall keeps matching stale content.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "ramen shop"))
    try store.setEmbedding(id: record.id, model: "bge-m3", vector: [0.1, 0.2, 0.3])
    #expect(try store.rowsNeedingEmbedding(model: "bge-m3").isEmpty) // indexed

    try store.setText(id: record.id, rawText: "sushi bar")

    #expect(try store.rowsNeedingEmbedding(model: "bge-m3").map(\.id) == [record.id])
    #expect(try store.embeddedRows(model: "bge-m3").isEmpty) // stale vector dropped
}

@Test
func localCaptureStoreMarkCreateSyncedRePushesEditThatRacedTheCreate() throws {
    // Regression: an edit made while a capture's create POST is in flight must not
    // be lost to the stale create payload. markCreateSynced compares the just-sent
    // text against the stored text and keeps the row dirty when they diverge.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())

    // No concurrent edit: the create's own text is what synced → row goes clean.
    let clean = try store.create(CapturePayload(rawText: "as sent"))
    let dirtyAfterClean = try store.markCreateSynced(
        localId: clean.id, serverId: "srv-clean", sentText: "as sent",
        syncedAt: Date(timeIntervalSince1970: 1_000))
    #expect(dirtyAfterClean == false)
    #expect(try store.pendingUpdates().isEmpty)

    // Edit landed during the in-flight create (stored "fixed" ≠ sent "typo"): the
    // row must stay dirty carrying the NEW text so the drain re-PATCHes it.
    let raced = try store.create(CapturePayload(rawText: "typo"))
    try store.setText(id: raced.id, rawText: "fixed", now: Date(timeIntervalSince1970: 2_000))
    let dirtyAfterRace = try store.markCreateSynced(
        localId: raced.id, serverId: "srv-raced", sentText: "typo",
        syncedAt: Date(timeIntervalSince1970: 2_500),
        reeditStamp: Date(timeIntervalSince1970: 3_000))
    #expect(dirtyAfterRace == true)
    let dirty = try store.pendingUpdates()
    #expect(dirty.map(\.serverId) == ["srv-raced"])
    #expect(dirty.first?.payload.rawText == "fixed")
}

@Test
func localCaptureStoreMarkNotifiedDoesNotQueueAnEditPush() throws {
    // Regression: firing a reminder's local notification is bookkeeping, not a text
    // edit, so it must NOT surface the row in pendingUpdates. Otherwise the drain
    // PATCHes /captures/{id} with the cached text — and for a server-sourced
    // reminder that text is the reminder *summary*, corrupting the capture body.
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())
    // server_id set, raw_text = the reminder summary; synced_at == updated_at (clean).
    let reminder = try store.upsertServerReminder(
        serverId: "srv-reminder", text: "reminder summary",
        remindAt: Date(timeIntervalSince1970: 9_000),
        now: Date(timeIntervalSince1970: 5_000))
    #expect(try store.pendingUpdates().isEmpty)

    // Notify LATER than synced_at — the exact case ReminderNotifier hits (default
    // now = real time). Bumping updated_at here would falsely flag the row dirty.
    try store.markNotified(localId: reminder.id, now: Date(timeIntervalSince1970: 6_000))

    #expect(try store.pendingUpdates().isEmpty)
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
