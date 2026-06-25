import Foundation

// Retrieval surface for the desktop app: hybrid search (/find) and query-time
// analysis (/ask), both served by the same Go API that authenticates the user
// and proxies the Python RAG sidecar. Shapes mirror the Go handlers in
// api/internal/search/recall.go — capture ids are String UUIDs and /find wraps
// its hits in an {items, degraded} envelope (degraded = keyword FTS fallback).

public struct RecallItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let createdAt: String
    public let modality: String
    public let score: Double
    public let lexical: Bool

    public init(
        id: String, content: String, createdAt: String,
        modality: String, score: Double, lexical: Bool
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.modality = modality
        self.score = score
        self.lexical = lexical
    }
}

public struct FindResponse: Codable, Equatable, Sendable {
    public let items: [RecallItem]
    public let degraded: Bool

    public init(items: [RecallItem], degraded: Bool) {
        self.items = items
        self.degraded = degraded
    }
}

// A capture as the browse/manage surfaces see it (subset of the API's CaptureBody;
// unknown JSON keys are ignored). `content` is what the row renders.
public struct Capture: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let rawText: String?
    public let transcript: String?
    public let mediaType: String
    public let mediaUrl: String?
    public let classifiedAs: String
    public let source: String
    public let remindAt: String?
    public let createdAt: String

    public init(
        id: String, rawText: String?, transcript: String?, mediaType: String,
        mediaUrl: String?, classifiedAs: String, source: String,
        remindAt: String?, createdAt: String
    ) {
        self.id = id
        self.rawText = rawText
        self.transcript = transcript
        self.mediaType = mediaType
        self.mediaUrl = mediaUrl
        self.classifiedAs = classifiedAs
        self.source = source
        self.remindAt = remindAt
        self.createdAt = createdAt
    }

    // Transcript wins (audio/image), else raw text, else empty (media-only).
    public var content: String {
        if let transcript, !transcript.isEmpty { return transcript }
        return rawText ?? ""
    }
}

// One semantic neighbour from GET /captures/{id}/related. Same shape as a search
// hit minus the `lexical` flag (related results are always vector-ranked), so it
// needs its own type rather than reusing RecallItem's decoder.
public struct RelatedCapture: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let createdAt: String
    public let modality: String
    public let score: Double

    public init(id: String, content: String, createdAt: String, modality: String, score: Double) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.modality = modality
        self.score = score
    }
}

public struct CapturePage: Codable, Equatable, Sendable {
    public let items: [Capture]
    public let nextCursor: String?

    public init(items: [Capture], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct AskSource: Codable, Equatable, Identifiable, Sendable {
    public let n: Int
    public let id: String
    public let content: String
    public let createdAt: String

    public init(n: Int, id: String, content: String, createdAt: String) {
        self.n = n
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

public struct AskResponse: Codable, Equatable, Sendable {
    public let answer: String
    public let sources: [AskSource]

    public init(answer: String, sources: [AskSource]) {
        self.answer = answer
        self.sources = sources
    }
}

struct AskRequestBody: Codable, Equatable {
    let question: String
}

public final class RecallAPIClient: @unchecked Sendable {
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

    public func makeFindRequest(q: String, limit: Int = 10) -> URLRequest {
        var components = URLComponents(
            url: config.apiURL.appending(path: "find"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func find(q: String, limit: Int = 10) async throws -> FindResponse {
        let request = makeFindRequest(q: q, limit: limit)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(FindResponse.self, from: data)
    }

    public func makeAskRequest(question: String) throws -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "ask"))
        request.httpMethod = "POST"
        // Query-time analysis runs claude -p and can take ~20s; keep the client
        // patient (Go bounds its own deadline below this).
        request.timeoutInterval = 120
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AskRequestBody(question: question))
        return request
    }

    public func ask(question: String) async throws -> AskResponse {
        let request = try makeAskRequest(question: question)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(AskResponse.self, from: data)
    }

    // MARK: - Browse / edit / delete (capture management for the main window)

    // A cursor-paginated page of the user's captures, newest first. Empty query =
    // "show everything" in the main window; this is the GET /captures/page surface.
    public func recent(cursor: String? = nil, limit: Int = 30) async throws -> CapturePage {
        var components = URLComponents(
            url: config.apiURL.appending(path: "captures/page"),
            resolvingAgainstBaseURL: false,
        )!
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(CapturePage.self, from: data)
    }

    // Edit a capture's text (PATCH /captures/{id}); the server re-embeds + re-extracts.
    public func update(id: String, rawText: String) async throws -> Capture {
        var request = URLRequest(url: captureURL(id))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rawText": rawText])
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(Capture.self, from: data)
    }

    // Soft delete (DELETE /captures/{id}); the server sets deleted_at, never removes.
    public func delete(id: String) async throws {
        var request = URLRequest(url: captureURL(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
    }

    // Semantic neighbours of a capture (GET /captures/{id}/related). The server
    // already excludes the capture itself and anything explicitly linked, and
    // returns an empty list (not an error) when embeddings are off or the capture
    // has no indexable text.
    public func makeRelatedRequest(id: String, limit: Int = 10) -> URLRequest {
        var components = URLComponents(
            url: captureURL(id).appending(path: "related"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func related(id: String, limit: Int = 10) async throws -> [RelatedCapture] {
        let request = makeRelatedRequest(id: id, limit: limit)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode([RelatedCapture].self, from: data)
    }

    private func captureURL(_ id: String) -> URL {
        config.apiURL.appending(path: "captures").appending(path: id)
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
