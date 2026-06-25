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
           "createdAt":"2026-06-06T16:33:27+09:00","modality":"text","score":0.87,"lexical":true}
        ],"degraded":true}
        """.utf8)

    let decoded = try JSONDecoder().decode(FindResponse.self, from: json)

    #expect(decoded.degraded == true)
    #expect(decoded.items.count == 1)
    let item = try #require(decoded.items.first)
    #expect(item.id == "d2ebedc1-c6b2-40f4-a789-8e48064252a1")
    #expect(item.content == "alpha capture")
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
