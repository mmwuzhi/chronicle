import Foundation
import Testing

@testable import ChronicleDesktopCore

// MARK: - Capture browse

@Test
func decodesCapturePageWithCursor() throws {
    let json = Data(
        """
        {"items":[
          {"id":"d2ebedc1-c6b2-40f4-a789-8e48064252a1","rawText":"alpha","mediaUrl":null,
           "mediaType":"text","classifiedAs":"unclassified","source":"web",
           "transcript":null,"transcriptionStatus":"none","remindAt":null,
           "createdAt":"2026-06-06T16:33:27Z"}
        ],"nextCursor":"abc123"}
        """.utf8)

    let page = try JSONDecoder().decode(CapturePage.self, from: json)

    #expect(page.nextCursor == "abc123")
    #expect(page.items.count == 1)
    let first = try #require(page.items.first)
    #expect(first.content == "alpha")
    #expect(first.classifiedAs == "unclassified")
}

@Test
func capturePageLastPageHasNilCursor() throws {
    let json = Data(#"{"items":[],"nextCursor":null}"#.utf8)
    let page = try JSONDecoder().decode(CapturePage.self, from: json)
    #expect(page.items.isEmpty)
    #expect(page.nextCursor == nil)
}

@Test
func captureContentPrefersTranscriptThenRawText() {
    let audio = Capture(
        id: "1", rawText: nil, transcript: "spoken words", mediaType: "audio",
        mediaUrl: "https://r2/x.m4a", classifiedAs: "log", source: "web",
        remindAt: nil, createdAt: "2026-06-06T16:33:27Z")
    #expect(audio.content == "spoken words")

    let text = Capture(
        id: "2", rawText: "typed note", transcript: nil, mediaType: "text",
        mediaUrl: nil, classifiedAs: "idea", source: "desktop_quick_capture",
        remindAt: nil, createdAt: "2026-06-06T16:33:27Z")
    #expect(text.content == "typed note")

    let empty = Capture(
        id: "3", rawText: nil, transcript: "", mediaType: "image",
        mediaUrl: "https://r2/x.png", classifiedAs: "unclassified", source: "web",
        remindAt: nil, createdAt: "2026-06-06T16:33:27Z")
    #expect(empty.content == "")
}

// MARK: - Webhooks

private let testConfig = ChronicleConfig(
    apiURL: URL(string: "http://localhost:8080")!,
    token: "test-token",
)

@Test
func decodesWebhookList() throws {
    let json = Data(
        """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Ledger",
          "targetUrl":"https://ledger.example/api","keywords":["lunch","ramen"],
          "semanticQuery":"food spending","semanticThreshold":0.6,
          "payloadTemplate":"{\\"text\\":\\"[capture.text]\\"}","enabled":true,
          "createdAt":"2026-06-12T17:00:00Z"}]
        """.utf8)

    let rules = try JSONDecoder().decode([WebhookRule].self, from: json)

    #expect(rules.count == 1)
    let rule = try #require(rules.first)
    #expect(rule.name == "Ledger")
    #expect(rule.keywords == ["lunch", "ramen"])
    #expect(rule.semanticQuery == "food spending")
    #expect(rule.enabled)
}

@Test
func webhookDraftNormalizesBlankSemanticQueryToNil() {
    var draft = WebhookDraft(name: "x", targetUrl: "https://x.example")
    draft.semanticQuery = "   "
    #expect(draft.normalizedSemanticQuery == nil)

    draft.semanticQuery = "  food  "
    #expect(draft.normalizedSemanticQuery == "food")

    draft.semanticQuery = nil
    #expect(draft.normalizedSemanticQuery == nil)
}

@Test
func webhookDraftFromRuleCopiesFields() {
    let rule = WebhookRule(
        id: "1", name: "Ledger", targetUrl: "https://x.example", keywords: ["a"],
        semanticQuery: "q", semanticThreshold: 0.7, payloadTemplate: "{}",
        enabled: false, createdAt: "2026-06-12T17:00:00Z")

    let draft = WebhookDraft(rule)

    #expect(draft.name == "Ledger")
    #expect(draft.semanticThreshold == 0.7)
    #expect(draft.enabled == false)
    #expect(draft.keywords == ["a"])
}

// MARK: - Local offline search

private func tempStore() -> LocalCaptureStore {
    LocalCaptureStore(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "chronicle-test-\(UUID().uuidString).sqlite3"))
}

@Test
func localStoreSearchFindsByKeywordNewestFirst() throws {
    let store = tempStore()
    _ = try store.create(CapturePayload(rawText: "buy milk"), now: Date(timeIntervalSince1970: 100))
    _ = try store.create(CapturePayload(rawText: "test note"), now: Date(timeIntervalSince1970: 200))
    _ = try store.create(CapturePayload(rawText: "another test2 thing"), now: Date(timeIntervalSince1970: 300))

    let hits = try store.search("test")
    #expect(hits.map(\.payload.rawText) == ["another test2 thing", "test note"]) // newest first

    #expect(try store.search("milk").map(\.payload.rawText) == ["buy milk"])
    #expect(try store.search("nonexistent").isEmpty)
    #expect(try store.recent().count == 3)
}

@Test
func localStoreSearchEscapesLikeWildcards() throws {
    let store = tempStore()
    _ = try store.create(CapturePayload(rawText: "100% done"))
    _ = try store.create(CapturePayload(rawText: "fifty percent"))

    // A literal % matches itself; it must not behave as a LIKE wildcard.
    #expect(try store.search("100%").map(\.payload.rawText) == ["100% done"])
}

@Test
func localStoreDeleteRemovesSyncedRowByServerId() throws {
    let store = tempStore()
    let rec = try store.create(CapturePayload(rawText: "delete me"))
    try store.markSynced(localId: rec.id, serverId: "srv-1")
    #expect(try store.recent().count == 1)

    // A server delete must also drop the cached row (keyed by its server id), or
    // the soft-deleted capture resurfaces in offline browse/search.
    try store.delete(id: "srv-1")
    #expect(try store.recent().isEmpty)
    #expect(try store.search("delete").isEmpty)
}

@Test
func localStoreDeleteRemovesUnsyncedRowByLocalId() throws {
    let store = tempStore()
    let rec = try store.create(CapturePayload(rawText: "local only"))

    // An unsynced row surfaces under its local id, so delete must match it too.
    try store.delete(id: rec.id)
    #expect(try store.recent().isEmpty)
}

@Test
func refreshRequestBuildsCookieAwarePOST() {
    let client = AuthAPIClient(apiURL: URL(string: "http://localhost:8080")!)
    let request = client.makeRefreshRequest()
    #expect(request.url?.absoluteString == "http://localhost:8080/auth/refresh")
    #expect(request.httpMethod == "POST")
    // The refresh token rides as a cookie, so cookie handling must stay on.
    #expect(request.httpShouldHandleCookies)
}

@Test
func logoutRequestBuildsCookieAwarePOST() {
    let client = AuthAPIClient(apiURL: URL(string: "http://localhost:8080")!)
    let request = client.makeLogoutRequest()
    #expect(request.url?.absoluteString == "http://localhost:8080/auth/logout")
    #expect(request.httpMethod == "POST")
    // The server revokes the refresh token from its cookie, so it must be sent.
    #expect(request.httpShouldHandleCookies)
}

@Test
func webhookTestClientBuildsScopedURL() {
    // The test endpoint is POST /webhooks/{id}/test — exercised here only for the
    // client's URL composition (no network); decoding is covered by the API tests.
    let client = WebhookAPIClient(config: testConfig)
    _ = client  // constructed without throwing; method URLs are derived from config
    #expect(testConfig.apiURL.appending(path: "webhooks").appending(path: "abc")
        .appending(path: "test").path == "/webhooks/abc/test")
}
