import Foundation
import Testing

@testable import ChronicleDesktopCore

private let testConfig = ChronicleConfig(
    apiURL: URL(string: "http://localhost:8080")!,
    token: "test-token",
)

@Test
func findRequestBuildsGETWithBearerAndQuery() throws {
    let client = RecallAPIClient(config: testConfig)

    let request = client.makeFindRequest(q: "ramen 1200", limit: 5)

    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/find")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "q", value: "ramen 1200")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "5")))
}

@Test
func askRequestBuildsPOSTWithBearerAndBody() throws {
    let client = RecallAPIClient(config: testConfig)

    let request = try client.makeAskRequest(question: "what did I spend on food?")

    #expect(request.url?.absoluteString == "http://localhost:8080/ask")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(AskRequestBody.self, from: body)
    #expect(decoded.question == "what did I spend on food?")
}

@Test
func reviewTodayRequestBuildsGETWithBearerAndTimezone() throws {
    let client = RecallAPIClient(config: testConfig)

    let request = client.makeReviewTodayRequest(timezoneOffsetMinutes: -540)

    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/review/today")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(components.queryItems == [
        URLQueryItem(name: "timezoneOffsetMinutes", value: "-540"),
    ])
}

@Test
func decodesReviewTodayBuckets() throws {
    let json = Data(
        """
        {
          "onThisDay":[
            {"id":"11111111-1111-1111-1111-111111111111","rawText":"same day",
             "transcript":null,"mediaType":"text","mediaUrl":null,"source":"web",
             "remindAt":null,"createdAt":"2024-07-19T09:00:00+09:00"}
          ],
          "rediscover":[
            {"id":"22222222-2222-2222-2222-222222222222","rawText":"older memory",
             "transcript":null,"mediaType":"text","mediaUrl":null,"source":"desktop",
             "remindAt":null,"createdAt":"2025-04-03T17:30:00+09:00"}
          ]
        }
        """.utf8)

    let decoded = try JSONDecoder().decode(ReviewTodayResponse.self, from: json)

    #expect(decoded.onThisDay.map(\.content) == ["same day"])
    #expect(decoded.rediscover.map(\.content) == ["older memory"])
}

@Test
func relatedRequestBuildsGETWithBearerAndLimit() throws {
    let client = RecallAPIClient(config: testConfig)

    let request = client.makeRelatedRequest(
        id: "d2ebedc1-c6b2-40f4-a789-8e48064252a1", limit: 8)

    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/captures/d2ebedc1-c6b2-40f4-a789-8e48064252a1/related")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "limit", value: "8")))
}

@Test
func decodesRelatedCaptures() throws {
    // GET /captures/{id}/related returns a bare array, with no `lexical` flag.
    let json = Data(
        """
        [
          {"id":"11111111-1111-1111-1111-111111111111","content":"neighbour one",
           "createdAt":"2026-06-06T16:33:27+09:00","modality":"text","score":0.91}
        ]
        """.utf8)

    let decoded = try JSONDecoder().decode([RelatedCapture].self, from: json)

    #expect(decoded.count == 1)
    let item = try #require(decoded.first)
    #expect(item.id == "11111111-1111-1111-1111-111111111111")
    #expect(item.content == "neighbour one")
    #expect(item.modality == "text")
    #expect(item.score == 0.91)
}

@Test
func decodesFindResponse() throws {
    let json = Data(
        """
        {"items":[
          {"id":"d2ebedc1-c6b2-40f4-a789-8e48064252a1","content":"alpha capture",
           "snippet":"…matched evidence…",
           "createdAt":"2026-06-06T16:33:27+09:00","modality":"text","score":0.87,"lexical":true}
        ],"degraded":true}
        """.utf8)

    let decoded = try JSONDecoder().decode(FindResponse.self, from: json)

    #expect(decoded.degraded == true)
    #expect(decoded.items.count == 1)
    let item = try #require(decoded.items.first)
    #expect(item.id == "d2ebedc1-c6b2-40f4-a789-8e48064252a1")
    #expect(item.content == "alpha capture")
    #expect(item.snippet == "…matched evidence…")
    #expect(item.score == 0.87)
    #expect(item.lexical == true)
}

@Test
func decodesAskResponse() throws {
    let json = Data(
        """
        {"answer":"You logged four things [1][2].","sources":[
          {"n":1,"id":"11111111-1111-1111-1111-111111111111","content":"first","createdAt":"2026-06-10T12:00:00+09:00"},
          {"n":2,"id":"22222222-2222-2222-2222-222222222222","content":"second","createdAt":"2026-06-11T19:00:00+09:00"}
        ]}
        """.utf8)

    let decoded = try JSONDecoder().decode(AskResponse.self, from: json)

    #expect(decoded.answer.contains("[1][2]"))
    #expect(decoded.sources.count == 2)
    #expect(decoded.sources.first?.n == 1)
    #expect(decoded.sources.last?.id == "22222222-2222-2222-2222-222222222222")
}

@Test
func decodesTrashedCaptureWithDeletedAtAndRemindHide() throws {
    // GET /captures/trash returns CaptureBody rows carrying deletedAt; a notify-only
    // capture carries remindHide=false. Both new fields must decode.
    let json = Data(
        """
        [
          {"id":"33333333-3333-3333-3333-333333333333","rawText":"deleted note",
           "transcript":null,"mediaType":"text","mediaUrl":null,
           "source":"web","remindAt":null,
           "remindHide":true,"createdAt":"2026-06-06T16:33:27+09:00",
           "deletedAt":"2026-06-30T09:00:00+09:00"},
          {"id":"44444444-4444-4444-4444-444444444444","rawText":"pinned sticky",
           "transcript":null,"mediaType":"text","mediaUrl":null,
           "source":"web",
           "remindAt":"2026-07-05T09:00:00+09:00","remindHide":false,
           "createdAt":"2026-06-06T16:33:27+09:00","deletedAt":null}
        ]
        """.utf8)

    let decoded = try JSONDecoder().decode([Capture].self, from: json)

    #expect(decoded.count == 2)
    let trashed = try #require(decoded.first)
    #expect(trashed.deletedAt == "2026-06-30T09:00:00+09:00")
    #expect(trashed.remindHide == true)
    let notifyOnly = decoded[1]
    #expect(notifyOnly.remindHide == false)
    #expect(notifyOnly.deletedAt == nil)
}

@Test
func decodesTodoFacetIntoState() throws {
    // CaptureBody carries todoAt/doneAt; rows from endpoints without the facet
    // (search hits, related) omit them and must read as plain captures.
    let json = Data(
        """
        [
          {"id":"55555555-5555-5555-5555-555555555555","rawText":"open todo",
           "transcript":null,"mediaType":"text","mediaUrl":null,"source":"web",
           "remindAt":null,"createdAt":"2026-07-01T09:00:00+09:00",
           "todoAt":"2026-07-02T09:00:00+09:00","doneAt":null},
          {"id":"66666666-6666-6666-6666-666666666666","rawText":"done todo",
           "transcript":null,"mediaType":"text","mediaUrl":null,"source":"web",
           "remindAt":null,"createdAt":"2026-07-01T09:00:00+09:00",
           "todoAt":"2026-07-02T09:00:00+09:00","doneAt":"2026-07-03T09:00:00+09:00"},
          {"id":"77777777-7777-7777-7777-777777777777","rawText":"plain capture",
           "transcript":null,"mediaType":"text","mediaUrl":null,"source":"web",
           "remindAt":null,"createdAt":"2026-07-01T09:00:00+09:00"}
        ]
        """.utf8)

    let decoded = try JSONDecoder().decode([Capture].self, from: json)

    #expect(decoded.count == 3)
    #expect(decoded[0].todoState == .open)
    #expect(decoded[1].todoState == .done)
    #expect(decoded[2].todoState == nil)
}
