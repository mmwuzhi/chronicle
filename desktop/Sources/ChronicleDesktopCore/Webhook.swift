import Foundation

// Capture webhooks: the desktop Settings CRUD surface for the Go /webhooks API.
// A rule fires a templated POST when a capture matches (keyword substring OR
// semantic cosine >= threshold). Matching + delivery happen in the ragsvc
// sidecar; Go owns this rules table. Shapes mirror internal/webhook/handler.go.

public struct WebhookRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var targetUrl: String
    public var keywords: [String]
    public var semanticQuery: String?
    public var semanticThreshold: Double
    public var payloadTemplate: String
    public var enabled: Bool
    public let createdAt: String

    public init(
        id: String, name: String, targetUrl: String, keywords: [String],
        semanticQuery: String?, semanticThreshold: Double, payloadTemplate: String,
        enabled: Bool, createdAt: String
    ) {
        self.id = id
        self.name = name
        self.targetUrl = targetUrl
        self.keywords = keywords
        self.semanticQuery = semanticQuery
        self.semanticThreshold = semanticThreshold
        self.payloadTemplate = payloadTemplate
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

// The writable fields shared by create + update (the API's WebhookFields).
public struct WebhookDraft: Codable, Equatable, Sendable {
    public var name: String
    public var targetUrl: String
    public var keywords: [String]
    public var semanticQuery: String?
    public var semanticThreshold: Double
    public var payloadTemplate: String
    public var enabled: Bool

    public init(
        name: String = "",
        targetUrl: String = "",
        keywords: [String] = [],
        semanticQuery: String? = nil,
        semanticThreshold: Double = 0.6,
        payloadTemplate: String = "{\n  \"text\": \"[capture.text]\"\n}",
        enabled: Bool = true
    ) {
        self.name = name
        self.targetUrl = targetUrl
        self.keywords = keywords
        self.semanticQuery = semanticQuery
        self.semanticThreshold = semanticThreshold
        self.payloadTemplate = payloadTemplate
        self.enabled = enabled
    }

    public init(_ rule: WebhookRule) {
        name = rule.name
        targetUrl = rule.targetUrl
        keywords = rule.keywords
        semanticQuery = rule.semanticQuery
        semanticThreshold = rule.semanticThreshold
        payloadTemplate = rule.payloadTemplate
        enabled = rule.enabled
    }

    // A blank semantic query means "no semantic match"; normalize whitespace-only
    // input to nil so the API stores null rather than an always-false empty rule.
    public var normalizedSemanticQuery: String? {
        let trimmed = semanticQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

public struct WebhookTestResult: Codable, Equatable, Sendable {
    public let matched: Bool
    public let score: Double?

    public init(matched: Bool, score: Double?) {
        self.matched = matched
        self.score = score
    }
}

public final class WebhookAPIClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig, session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func list() async throws -> [WebhookRule] {
        var request = URLRequest(url: config.apiURL.appending(path: "webhooks"))
        request.httpMethod = "GET"
        authorize(&request)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode([WebhookRule].self, from: data)
    }

    @discardableResult
    public func create(_ draft: WebhookDraft) async throws -> WebhookRule {
        var request = URLRequest(url: config.apiURL.appending(path: "webhooks"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeFields(draft)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(WebhookRule.self, from: data)
    }

    @discardableResult
    public func update(id: String, _ draft: WebhookDraft) async throws -> WebhookRule {
        var request = URLRequest(url: webhookURL(id))
        request.httpMethod = "PATCH"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeFields(draft)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(WebhookRule.self, from: data)
    }

    public func delete(id: String) async throws {
        var request = URLRequest(url: webhookURL(id))
        request.httpMethod = "DELETE"
        authorize(&request)
        let (_, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
    }

    public func test(id: String, captureId: String) async throws -> WebhookTestResult {
        var request = URLRequest(url: webhookURL(id).appending(path: "test"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["captureId": captureId])
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(WebhookTestResult.self, from: data)
    }

    // --- helpers ---

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    }

    private func webhookURL(_ id: String) -> URL {
        config.apiURL.appending(path: "webhooks").appending(path: id)
    }

    // The API's WebhookFields omits semanticQuery when empty (a blank query means
    // "no semantic match"); send it as null so the server clears it.
    private func encodeFields(_ draft: WebhookDraft) throws -> Data {
        let body = WebhookFieldsBody(
            name: draft.name,
            targetUrl: draft.targetUrl,
            keywords: draft.keywords,
            semanticQuery: draft.normalizedSemanticQuery,
            semanticThreshold: draft.semanticThreshold,
            payloadTemplate: draft.payloadTemplate,
            enabled: draft.enabled,
        )
        return try JSONEncoder().encode(body)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureAPIError.httpStatus(http.statusCode)
        }
    }
}

private struct WebhookFieldsBody: Encodable {
    let name: String
    let targetUrl: String
    let keywords: [String]
    let semanticQuery: String?
    let semanticThreshold: Double
    let payloadTemplate: String
    let enabled: Bool
}
