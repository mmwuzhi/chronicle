import Darwin
import Foundation
import SQLite3
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
func localCaptureScopeCanonicalizesOriginIndependentOfPathAndDefaultPort() {
    let withPath = LocalCaptureScope(
        apiURL: URL(string: "https://API.Example.com/v1")!,
        userID: "user-1"
    )
    let explicitPort = LocalCaptureScope(
        apiURL: URL(string: "https://api.example.com:443/v2")!,
        userID: "user-1"
    )
    let ipv6 = LocalCaptureScope(
        apiURL: URL(string: "http://[::1]:8080/api")!,
        userID: "user-1"
    )

    #expect(withPath == explicitPort)
    #expect(ipv6?.apiOrigin == "http://[::1]:8080")
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

    let request = try client.makeRequest(
        for: CapturePayload(rawText: "Quick note"),
        idempotencyKey: "stable-local-uuid"
    )

    #expect(request.url?.absoluteString == "http://localhost:8080/captures")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "stable-local-uuid")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(CapturePayload.self, from: body)
    #expect(decoded.rawText == "Quick note")
    #expect(decoded.source == desktopQuickCaptureSource)
}

@Test
func mediaUploadClientBuildsCaptureMultipartRequest() throws {
    let config = ChronicleConfig(apiURL: URL(string: "https://api.example.com/v1")!, token: "test-token")
    let client = CaptureMediaUploadClient(config: config)
    let request = try client.makeRequest(
        for: CaptureMediaUpload(
            operationId: "e71dc14c-90c1-4d04-b9ee-4fd209da7916",
            data: Data("audio-bytes".utf8),
            filename: "memo\r\nX-Injected: yes.m4a",
            mimeType: "audio/mp4",
            text: "remember this #todo",
            durationSeconds: 12,
            remindAt: Date(timeIntervalSince1970: 1_700_000_000),
            remindHide: false
        ),
        boundary: "test-boundary"
    )

    #expect(request.url?.absoluteString == "https://api.example.com/v1/captures/upload")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "e71dc14c-90c1-4d04-b9ee-4fd209da7916")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary")
    let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(body.contains("name=\"file\"; filename=\"memo__X-Injected: yes.m4a\""))
    #expect(!body.contains("\r\nX-Injected: yes"))
    #expect(body.contains("name=\"createCapture\"\r\n\r\ntrue"))
    #expect(body.contains("name=\"source\"\r\n\r\ndesktop_quick_capture"))
    #expect(body.contains("name=\"text\"\r\n\r\nremember this #todo"))
    #expect(body.contains("name=\"durationSec\"\r\n\r\n12"))
    #expect(body.contains("name=\"remindHide\"\r\n\r\nfalse"))
}

@Test
func mediaUploadClientRejectsOversizedFilesBeforeSending() {
    let config = ChronicleConfig(apiURL: URL(string: "https://api.example.com")!, token: "test-token")
    let client = CaptureMediaUploadClient(config: config)
    let upload = CaptureMediaUpload(
        data: Data(repeating: 0, count: directCaptureUploadMaxBytes + 1),
        filename: "large.png",
        mimeType: "image/png"
    )

    #expect(throws: CaptureMediaUploadError.fileTooLarge) {
        try client.makeRequest(for: upload)
    }
}

@Test
func attachmentClientBuildsCloudReferenceRequest() throws {
    let config = ChronicleConfig(apiURL: URL(string: "https://api.example.com")!, token: "test-token")
    let client = CaptureAttachmentAPIClient(config: config)
    let attachment = CloudAttachmentDraft(
        provider: "google_drive",
        providerFileId: "drive-file-1",
        name: "reference.pdf",
        mimeType: "application/pdf",
        sizeBytes: 42,
        webUrl: "https://drive.google.com/file/d/drive-file-1/view"
    )

    let request = try client.makeAddRequest(captureId: "capture-1", attachment: attachment)

    #expect(request.url?.absoluteString == "https://api.example.com/captures/capture-1/attachments")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(try JSONDecoder().decode(CloudAttachmentDraft.self, from: #require(request.httpBody)) == attachment)
}

@Test
func googleDriveOAuthUsesDriveFileScopeAndPKCE() throws {
    let url = try GoogleDriveOAuth.authorizationURL(
        clientID: "desktop-client",
        redirectURI: "http://127.0.0.1:49152/oauth/callback",
        state: "state-1",
        codeChallenge: "challenge-1"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items: [String: String] = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(items["scope"] == googleDriveFileScope)
    #expect(items["state"] == "state-1")
    #expect(items["code_challenge"] == "challenge-1")
    #expect(items["code_challenge_method"] == "S256")

    let tokenRequest = GoogleDriveOAuth.tokenRequest(
        clientID: "desktop-client",
        redirectURI: "http://127.0.0.1:49152/oauth/callback",
        code: "code-1",
        codeVerifier: "verifier-1"
    )
    let tokenBody = try #require(tokenRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(tokenRequest.url?.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(tokenBody.contains("code_verifier=verifier-1"))
    #expect(tokenBody.contains("grant_type=authorization_code"))
}

@Test
func googleDriveOAuthCallbackWaitsForCompleteValidatedRequest() {
    let partial = Data("GET /oauth/callback?code=ok&state=expected HTTP/1.1\r\nHost: localhost\r\n".utf8)
    #expect(
        GoogleDriveOAuthCallback.parse(
            partial,
            expectedPath: "/oauth/callback",
            expectedState: "expected"
        ) == .incomplete
    )

    func parse(_ target: String) -> GoogleDriveOAuthCallbackResult {
        GoogleDriveOAuthCallback.parse(
            Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
            expectedPath: "/oauth/callback",
            expectedState: "expected"
        )
    }

    #expect(parse("/favicon.ico") == .ignored)
    #expect(parse("/oauth/callback?code=ok&state=wrong") == .ignored)
    #expect(parse("/oauth/callback?code=one&code=two&state=expected") == .ignored)
    #expect(parse("/oauth/callback?error=access_denied&state=expected") == .denied)
    #expect(parse("/oauth/callback?code=authorization-code&state=expected") == .accepted("authorization-code"))
}

@Test
func secureCaptureFileRejectsSpecialPathsAndStagesStableSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: SecureCaptureFileError.notRegularFile) {
        try inspectCaptureFile(at: URL(fileURLWithPath: "/dev/zero"), maxBytes: 1024)
    }

    let regular = directory.appending(path: "capture.png")
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    try bytes.write(to: regular)
    let link = directory.appending(path: "capture-link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    #expect(throws: SecureCaptureFileError.notRegularFile) {
        try inspectCaptureFile(at: link, maxBytes: 1024)
    }

    let fifo = directory.appending(path: "capture.pipe")
    #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
    #expect(throws: SecureCaptureFileError.notRegularFile) {
        try inspectCaptureFile(at: fifo, maxBytes: 1024)
    }

    let snapshot = try inspectCaptureFile(at: regular, maxBytes: 1024)
    #expect(snapshot.mediaMimeType == "image/png")
    let staged = try stageCaptureFile(at: regular, expected: snapshot.identity, maxBytes: 1024)
    defer { removeStagedCaptureFile(staged) }
    #expect(try Data(contentsOf: staged) == bytes)

    let wrongIdentity = CaptureFileIdentity(
        device: snapshot.identity.device,
        inode: snapshot.identity.inode &+ 1,
        sizeBytes: snapshot.identity.sizeBytes
    )
    #expect(throws: SecureCaptureFileError.fileChanged) {
        try stageCaptureFile(at: regular, expected: wrongIdentity, maxBytes: 1024)
    }
}

@Test
func captureWithAttachmentRequestCarriesStableOperationAndReminder() throws {
    let config = ChronicleConfig(apiURL: URL(string: "https://api.example.com")!, token: "token")
    let client = CaptureWithAttachmentAPIClient(config: config)
    let attachment = CloudAttachmentDraft(
        provider: "google_drive",
        providerFileId: "file-1",
        name: "archive.zip",
        mimeType: "application/zip",
        sizeBytes: 123,
        webUrl: "https://drive.google.com/file/d/file-1/view"
    )
    let request = try client.makeRequest(
        operationId: "88aadf7b-355e-41e9-a992-b99188dd5f89",
        text: "Reference",
        remindAt: Date(timeIntervalSince1970: 1_700_000_000),
        remindHide: false,
        attachment: attachment
    )
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(request.url?.path == "/captures/with-attachment")
    #expect(json["operationId"] as? String == "88aadf7b-355e-41e9-a992-b99188dd5f89")
    #expect(json["source"] as? String == desktopQuickCaptureSource)
    #expect(json["remindHide"] as? Bool == false)
    #expect((json["attachment"] as? [String: Any])?["providerFileId"] as? String == "file-1")
}

@Test
func captureDecodesEmbeddedAttachments() throws {
    let capture = try JSONDecoder().decode(
        Capture.self,
        from: Data(
            """
            {"id":"capture-1","rawText":"Reference","transcript":null,"mediaType":"text",\
             "mediaUrl":null,"source":"desktop_quick_capture","remindAt":null,"remindHide":false,\
             "deletedAt":null,"createdAt":"2026-07-23T00:00:00Z","todoAt":null,"doneAt":null,\
             "attachments":[{"id":"attachment-1","captureId":"capture-1","provider":"google_drive",\
             "providerFileId":"file-1","name":"reference.pdf","mimeType":"application/pdf",\
             "sizeBytes":42,"webUrl":"https://drive.google.com/file/d/file-1/view",\
             "createdAt":"2026-07-23T00:00:01Z"}]}
            """.utf8
        )
    )
    #expect(capture.attachments?.count == 1)
    #expect(capture.attachments?.first?.name == "reference.pdf")
}

@Test
func serverCreatedCaptureCacheNeverEntersPendingSync() throws {
    let store = temporaryStore()
    let payload = CapturePayload(rawText: "uploaded image", mediaType: "image")

    let record = try store.cacheServerCapture(serverId: "server-media-1", payload: payload)

    #expect(record.serverId == "server-media-1")
    #expect(record.isSynced)
    #expect(try store.pendingSync().isEmpty)
    #expect(try store.syncBacklog().total == 0)
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
func authClientCanCrossActorBoundaries() {
    func requireSendable<T: Sendable>(_: T) {}

    requireSendable(AuthAPIClient(apiURL: URL(string: "https://api.example.com/v1")!))
}

@Test
func userIdentityClientBuildsAuthenticatedMeRequest() {
    let client = UserIdentityAPIClient(config: ChronicleConfig(
        apiURL: URL(string: "https://api.example.com/v1")!,
        token: "candidate-token"
    ))

    let request = client.makeRequest()

    #expect(request.url?.absoluteString == "https://api.example.com/v1/users/me")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer candidate-token")
}

@Test
func authClientBuildsDesktopOAuthFlowRequests() throws {
    let client = AuthAPIClient(apiURL: URL(string: "https://api.example.com/v1")!)
    let verifier = "0123456789012345678901234567890123456789012"
    let challenge = DesktopOAuthPKCE.challenge(for: verifier)

    let startURL = try client.desktopOAuthStartURL(provider: .google, codeChallenge: challenge)
    let exchange = try client.makeDesktopOAuthExchangeRequest(
        code: "one-time-code",
        codeVerifier: verifier,
    )

    #expect(startURL.absoluteString == "https://api.example.com/v1/auth/google?client=desktop&code_challenge=_RpfHqw8pAZIomzVUE7sjRmHSM543WVdC4o-Kc4_3C0&code_challenge_method=S256")
    #expect(exchange.url?.absoluteString == "https://api.example.com/v1/auth/oauth/desktop/exchange")
    #expect(exchange.httpMethod == "POST")
    #expect(exchange.httpShouldHandleCookies)
    let body = try #require(exchange.httpBody)
    let decoded = try JSONDecoder().decode(DesktopOAuthExchangeRequest.self, from: body)
    #expect(decoded.code == "one-time-code")
    #expect(decoded.codeVerifier == verifier)

    let generated = DesktopOAuthPKCE.generate()
    #expect(generated.verifier.count == 43)
    #expect(generated.challenge == DesktopOAuthPKCE.challenge(for: generated.verifier))
}

@Test
func authClientBuildsMFAVerificationRequest() throws {
    let client = AuthAPIClient(apiURL: URL(string: "https://api.example.com/v1")!)

    let request = try client.makeMFAVerifyRequest(
        mfaToken: "short-lived-mfa-token",
        code: "123456",
    )

    #expect(request.url?.absoluteString == "https://api.example.com/v1/auth/mfa/verify")
    #expect(request.httpMethod == "POST")
    #expect(request.httpShouldHandleCookies)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(MFAVerifyRequest.self, from: body)
    #expect(decoded.mfaToken == "short-lived-mfa-token")
    #expect(decoded.code == "123456")
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
    let store = temporaryStore()
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
    let notifyOnly = try LocalCaptureStore(fileURL: url, scope: .testing).create(
        CapturePayload(rawText: "pinned sticky", remindAt: Date(timeIntervalSince1970: 5_000), remindHide: false),
    )
    let hidden = try LocalCaptureStore(fileURL: url, scope: .testing).create(
        CapturePayload(rawText: "resurface later", remindAt: Date(timeIntervalSince1970: 5_000)),
    )

    // Re-open the store (fresh instance) to prove it survives a relaunch, and read
    // through pendingSync — the exact path the offline retry uses.
    let pending = try LocalCaptureStore(fileURL: url, scope: .testing).pendingSync()
    let reloadedNotifyOnly = try #require(pending.first { $0.id == notifyOnly.id })
    let reloadedHidden = try #require(pending.first { $0.id == hidden.id })
    #expect(reloadedNotifyOnly.payload.remindHide == false)
    #expect(reloadedHidden.payload.remindHide == nil) // default → server applies hide
}

@Test
func localCaptureStoreMarksCaptureSynced() throws {
    let store = temporaryStore()
    let record = try store.create(CapturePayload(rawText: "Sync me"))

    try store.markSynced(localId: record.id, serverId: "server-1", syncedAt: Date(timeIntervalSince1970: 2_100))

    #expect(try store.pendingSync().isEmpty)
    let found = try store.find(serverId: "server-1")
    let synced = try #require(found)
    #expect(synced.id == record.id)
    #expect(synced.isSynced)
}

@Test
func localCaptureStoreSyncBacklogCountsEveryPendingRecordExactly() throws {
    let store = temporaryStore()

    // The old implementation decoded a page capped at 1,000 records, so a
    // larger offline queue silently under-reported the user-visible backlog.
    for index in 0..<1_001 {
        _ = try store.create(CapturePayload(rawText: "pending-\(index)"))
    }

    let dirty = try store.create(CapturePayload(rawText: "dirty"))
    try store.markSynced(
        localId: dirty.id,
        serverId: "server-dirty",
        syncedAt: Date(timeIntervalSince1970: 1_000)
    )
    try store.setText(
        id: "server-dirty",
        rawText: "dirty edit",
        now: Date(timeIntervalSince1970: 2_000)
    )

    let clean = try store.create(CapturePayload(rawText: "clean"))
    try store.markSynced(
        localId: clean.id,
        serverId: "server-clean",
        syncedAt: Date(timeIntervalSince1970: 3_000)
    )

    #expect(
        try store.syncBacklog()
            == LocalCaptureSyncBacklog(pendingCreates: 1_001, pendingUpdates: 1)
    )
}

@Test
func localCaptureStoreFindsByLocalIdBeforeAndAfterSync() throws {
    // The local id is what a reminder notification's userInfo carries; it must
    // resolve the same row both while the capture is still local-only and after
    // markSynced rekeys it with a server id (the notification may fire days later).
    let store = temporaryStore()
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
    let store = temporaryStore()
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
func localCaptureStoreKeepsDueReminderRetryableUntilDeliveryIsMarked() throws {
    let store = temporaryStore()
    let remindAt = Date(timeIntervalSince1970: 3_000)

    let first = try store.upsertDueServerReminder(
        serverId: "server-due",
        text: "Already due",
        remindAt: remindAt,
        now: Date(timeIntervalSince1970: 3_100),
    )
    // Simulate UNUserNotificationCenter.add failing: without markNotified, the
    // same stable server reminder remains eligible on the next sync.
    let retryAfterDeliveryFailure = try store.upsertDueServerReminder(
        serverId: "server-due",
        text: "Already due",
        remindAt: remindAt,
        now: Date(timeIntervalSince1970: 3_200),
    )
    let delivered = try #require(retryAfterDeliveryFailure)
    try store.markNotified(
        localId: delivered.id,
        now: Date(timeIntervalSince1970: 3_300))
    let afterDelivery = try store.upsertDueServerReminder(
        serverId: "server-due",
        text: "Already due",
        remindAt: remindAt,
        now: Date(timeIntervalSince1970: 3_400),
    )

    #expect(first != nil)
    #expect(first?.notifiedAt == nil)
    #expect(retryAfterDeliveryFailure?.id == first?.id)
    #expect(afterDelivery == nil)
}

@Test
func localCaptureStoreDoesNotReNotifyLocallyScheduledReminderAfterSync() throws {
    // Regression: a reminder created locally schedules a calendar trigger (which
    // ReminderNotifier marks notified) and then syncs to the server. When the
    // reminder later shows up in the server `due` list, the due path must NOT post
    // a second notification — the local trigger already covers delivery.
    let store = temporaryStore()
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
    let store = temporaryStore()
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
func localCaptureStoreQueuesEditEvenWhenWallClockMovesBackward() throws {
    let store = temporaryStore()
    let record = try store.create(CapturePayload(rawText: "before rollback"))
    try store.markSynced(
        localId: record.id,
        serverId: "server-clock-rollback",
        syncedAt: Date(timeIntervalSince1970: 5_000)
    )

    try store.setText(
        id: record.id,
        rawText: "edited after rollback",
        now: Date(timeIntervalSince1970: 1_000)
    )

    let dirty = try #require(try store.pendingUpdates().first)
    #expect(dirty.updatedAt < dirty.syncedAt!)
    #expect(dirty.hasPendingUpdate)
    #expect(dirty.payload.rawText == "edited after rollback")
}

@Test
func localCaptureStoreEditOnUnsyncedRowStaysInCreateQueue() throws {
    // Editing a not-yet-synced row must carry the new text into its eventual create
    // (pendingSync), not appear as a separate update — it has no server id to PATCH.
    let store = temporaryStore()
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
    let store = temporaryStore()
    #expect(try store.setText(id: "not-cached", rawText: "x") == 0)
}

@Test
func localCaptureStoreMarkUpdatePushedClearsDirtyOnlyWhenNothingChangedMeanwhile() throws {
    // markUpdatePushed acknowledges the exact edit revision that was sent. When no
    // re-edit raced the PATCH the row goes clean; a newer revision stays dirty.
    let store = temporaryStore()
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
    try store.markUpdatePushed(
        localId: record.id,
        syncedRevision: pushed.editRevision,
        syncedAt: pushed.updatedAt
    )

    // updated_at (t3) still exceeds synced_at (t2) → still dirty, v2 re-pushes.
    let stillDirty = try store.pendingUpdates()
    #expect(stillDirty.map(\.serverId) == ["server-race"])
    #expect(stillDirty.first?.payload.rawText == "v2")

    // Pushing v2 with its own updated_at finally clears the dirty flag.
    let latest = try #require(try store.pendingUpdates().first)
    try store.markUpdatePushed(
        localId: record.id,
        syncedRevision: latest.editRevision,
        syncedAt: latest.updatedAt
    )
    #expect(try store.pendingUpdates().isEmpty)
}

@Test
func localCaptureStoreEditClearsStaleEmbedding() throws {
    // On-device semantic search ranks the cached vector, which indexed the *old*
    // text. Editing must drop that vector (rowsNeedingEmbedding only re-embeds a
    // missing/different-model one) or semantic recall keeps matching stale content.
    let store = temporaryStore()
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
    let store = temporaryStore()

    // No concurrent edit: the create's own text is what synced → row goes clean.
    let clean = try store.create(CapturePayload(rawText: "as sent"))
    let dirtyAfterClean = try store.markCreateSynced(
        localId: clean.id, serverId: "srv-clean", sentText: "as sent",
        sentRevision: clean.editRevision,
        syncedAt: Date(timeIntervalSince1970: 1_000))
    #expect(dirtyAfterClean == false)
    #expect(try store.pendingUpdates().isEmpty)

    // Edit landed during the in-flight create (stored "fixed" ≠ sent "typo"): the
    // row must stay dirty carrying the NEW text so the drain re-PATCHes it.
    let raced = try store.create(CapturePayload(rawText: "typo"))
    try store.setText(id: raced.id, rawText: "fixed", now: Date(timeIntervalSince1970: 2_000))
    let dirtyAfterRace = try store.markCreateSynced(
        localId: raced.id, serverId: "srv-raced", sentText: "typo",
        sentRevision: 0,
        syncedAt: Date(timeIntervalSince1970: 2_500))
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
    let store = temporaryStore()
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

@Test
func localCaptureStoreScopesEveryOfflineSurfaceByVerifiedOriginAndUser() throws {
    let url = temporaryDatabaseURL()
    let scopeA = try #require(LocalCaptureScope(
        apiURL: URL(string: "https://api.example.com/v1")!,
        userID: "user-a"
    ))
    let scopeB = try #require(LocalCaptureScope(
        apiURL: URL(string: "https://api.example.com/v2")!,
        userID: "user-b"
    ))
    let otherOrigin = try #require(LocalCaptureScope(
        apiURL: URL(string: "https://other.example.com")!,
        userID: "user-a"
    ))
    let store = LocalCaptureStore(fileURL: url, scope: scopeA)
    let a = try store.create(CapturePayload(
        rawText: "A private pending capture",
        remindAt: Date().addingTimeInterval(3_600)
    ))
    try store.setEmbedding(id: a.id, model: "test-model", vector: [1, 0])

    store.activate(scopeB)
    #expect(try store.recent().isEmpty)
    #expect(try store.search("private").isEmpty)
    #expect(try store.pendingSync().isEmpty)
    #expect(try store.upcomingReminders().isEmpty)
    #expect(try store.embeddedRows(model: "test-model").isEmpty)
    _ = try store.create(CapturePayload(rawText: "B capture"))

    store.activate(otherOrigin)
    #expect(try store.recent().isEmpty)

    store.activate(scopeA)
    #expect(try store.recent().map(\.payload.rawText) == ["A private pending capture"])
    #expect(try store.pendingSync().map(\.id) == [a.id])
}

@Test
func localCaptureStoreQuarantinesRowsWrittenBeforeAccountScoping() throws {
    let url = temporaryDatabaseURL()
    let store = LocalCaptureStore(fileURL: url, scope: .testing)
    let legacy = try store.create(CapturePayload(rawText: "unknown legacy owner"))

    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = "UPDATE local_captures SET account_scope = NULL WHERE id = '\(legacy.id)'"
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

    #expect(try store.recent().isEmpty)
    #expect(try store.pendingSync().isEmpty)
    #expect(try store.syncBacklog().total == 0)
}

@Test
func scopedSchemaUpgradeLetsVerifiedRowReuseLegacyServerID() throws {
    let url = temporaryDatabaseURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var db: OpaquePointer?
    try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
    let oldSchema = """
        CREATE TABLE local_captures (
            id TEXT PRIMARY KEY,
            server_id TEXT UNIQUE,
            raw_text TEXT NOT NULL,
            media_type TEXT NOT NULL,
            classified_as TEXT NOT NULL,
            source TEXT NOT NULL,
            remind_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            synced_at TEXT,
            last_error TEXT,
            notified_at TEXT,
            remind_hide INTEGER
        );
        INSERT INTO local_captures (
            id, server_id, raw_text, media_type, classified_as, source,
            created_at, updated_at, synced_at
        ) VALUES (
            'legacy-local', 'same-server-id', 'legacy unknown owner', 'text',
            'unclassified', 'desktop_quick_capture',
            '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z',
            '2026-01-01T00:00:00.000Z'
        );
        """
    try #require(sqlite3_exec(db, oldSchema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    db = nil

    let store = LocalCaptureStore(fileURL: url, scope: .testing)
    let scoped = try store.cacheServerCapture(
        serverId: "same-server-id",
        payload: CapturePayload(rawText: "verified owner")
    )

    #expect(scoped.payload.rawText == "verified owner")
    #expect(try store.count() == 1)
    #expect(try store.find(serverId: "same-server-id")?.id == scoped.id)
}

@Test
func localCaptureStoreRejectsAccessWithoutAnExplicitIdentityScope() {
    let store = LocalCaptureStore(fileURL: temporaryDatabaseURL())

    #expect(throws: LocalCaptureStoreError.scopeUnavailable) {
        try store.create(CapturePayload(rawText: "must not become unowned"))
    }
    #expect(throws: LocalCaptureStoreError.scopeUnavailable) {
        try store.recent()
    }
}

@Test
func reminderRefreshPreservesDirtyOfflineTextAndUpdateClock() throws {
    let store = temporaryStore()
    let initial = try store.upsertServerReminder(
        serverId: "srv-dirty-reminder",
        text: "server summary",
        remindAt: Date(timeIntervalSince1970: 8_000),
        now: Date(timeIntervalSince1970: 1_000)
    )
    try store.setText(
        id: initial.id,
        rawText: "my offline edit",
        now: Date(timeIntervalSince1970: 2_000)
    )
    let dirtyBefore = try #require(try store.pendingUpdates().first)

    _ = try store.upsertServerReminder(
        serverId: "srv-dirty-reminder",
        text: "new server summary",
        remindAt: Date(timeIntervalSince1970: 9_000),
        now: Date(timeIntervalSince1970: 3_000)
    )
    let dirtyAfterPending = try #require(try store.pendingUpdates().first)
    #expect(dirtyAfterPending.payload.rawText == "my offline edit")
    #expect(dirtyAfterPending.updatedAt == dirtyBefore.updatedAt)
    #expect(dirtyAfterPending.syncedAt == dirtyBefore.syncedAt)
    #expect(dirtyAfterPending.payload.remindAt == Date(timeIntervalSince1970: 9_000))

    _ = try store.upsertDueServerReminder(
        serverId: "srv-dirty-reminder",
        text: "due server summary",
        remindAt: Date(timeIntervalSince1970: 9_500),
        now: Date(timeIntervalSince1970: 4_000)
    )
    let dirtyAfterDue = try #require(try store.pendingUpdates().first)
    #expect(dirtyAfterDue.payload.rawText == "my offline edit")
    #expect(dirtyAfterDue.updatedAt == dirtyBefore.updatedAt)
    #expect(dirtyAfterDue.syncedAt == dirtyBefore.syncedAt)
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

private func temporaryStore() -> LocalCaptureStore {
    LocalCaptureStore(fileURL: temporaryDatabaseURL(), scope: .testing)
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
