import Foundation

public let desktopQuickCaptureSource = "desktop_quick_capture"

public struct CapturePayload: Codable, Equatable, Sendable {
    public var rawText: String
    public var mediaType: String
    public var source: String
    public var remindAt: Date?
    // Only meaningful with remindAt set. nil (default) → hide until due; false →
    // notify-only (the sticky stays visible and still pings). Encoded only when
    // present, so the server default (hide) applies when it's nil.
    public var remindHide: Bool?

    public init(
        rawText: String,
        mediaType: String = "text",
        source: String = desktopQuickCaptureSource,
        remindAt: Date? = nil,
        remindHide: Bool? = nil
    ) {
        self.rawText = rawText
        self.mediaType = mediaType
        self.source = source
        self.remindAt = remindAt
        self.remindHide = remindHide
    }
}

public struct QueuedCapture: Codable, Equatable {
    public var payload: CapturePayload
    public var queuedAt: Date
    public var reminderLocalId: String?  // local reminder to re-key once uploaded

    public init(payload: CapturePayload, queuedAt: Date = Date(), reminderLocalId: String? = nil) {
        self.payload = payload
        self.queuedAt = queuedAt
        self.reminderLocalId = reminderLocalId
    }
}

public struct ChronicleConfig: Codable, Equatable, Sendable {
    public var apiURL: URL
    public var token: String

    public init(apiURL: URL, token: String) {
        self.apiURL = apiURL
        self.token = token
    }

    public var isUsable: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public protocol CaptureSending {
    // Returns the created capture's server id (used to key the local reminder /
    // its system notification once the capture exists on the server).
    @discardableResult
    func send(_ payload: CapturePayload) async throws -> String
}

/// The two remote operations needed to drain the offline capture store.
/// Keeping this protocol smaller than the full API client makes sync orchestration
/// independently testable without constructing URL sessions or HTTP responses.
public protocol CaptureSyncTransport: Sendable {
    /// Create replay uses the local UUID as a stable remote operation identity.
    func send(_ payload: CapturePayload, idempotencyKey: String) async throws -> String
    func recoverCreate(operationID: String) async throws -> RecoveredCaptureCreate?
    func update(serverId: String, rawText: String) async throws
}

public struct RecoveredCaptureCreate: Equatable, Sendable {
    public let id: String
    public let rawText: String
    public let mediaType: String
    public let source: String

    public init(id: String, rawText: String, mediaType: String, source: String) {
        self.id = id
        self.rawText = rawText
        self.mediaType = mediaType
        self.source = source
    }
}

public extension CaptureSyncTransport {
    func recoverCreate(operationID _: String) async throws -> RecoveredCaptureCreate? {
        nil
    }
}

public final class CaptureAPIClient: CaptureSyncTransport, @unchecked Sendable {
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

    public func makeRequest(
        for payload: CapturePayload,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "captures"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601  // remindAt → RFC3339 the Go API parses
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private struct CreatedCapture: Decodable { let id: String }

    @discardableResult
    public func send(_ payload: CapturePayload) async throws -> String {
        let request = try makeRequest(for: payload)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CaptureAPIError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(CreatedCapture.self, from: data).id
    }

    @discardableResult
    public func send(
        _ payload: CapturePayload,
        idempotencyKey: String
    ) async throws -> String {
        let request = try makeRequest(for: payload, idempotencyKey: idempotencyKey)
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CaptureAPIError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(CreatedCapture.self, from: data).id
    }

    public func recoverCreate(operationID: String) async throws -> RecoveredCaptureCreate? {
        var request = URLRequest(
            url: config.apiURL.appending(path: "captures").appending(path: operationID)
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        guard let http = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureAPIError.httpStatus(http.statusCode)
        }
        struct Body: Decodable {
            let id: String
            let rawText: String?
            let mediaType: String
            let source: String
        }
        let capture = try JSONDecoder().decode(Body.self, from: data)
        guard let rawText = capture.rawText else { return nil }
        return RecoveredCaptureCreate(
            id: capture.id,
            rawText: rawText,
            mediaType: capture.mediaType,
            source: capture.source
        )
    }

    // Push an edited capture's text back (PATCH /captures/{id}). Mirrors
    // RecallAPIClient.update but on the sync client, so the offline queue drains
    // creates (send) and edits (update) through one client. The server re-embeds +
    // re-extracts; the returned body is ignored — the drain only needs success.
    public func update(serverId: String, rawText: String) async throws {
        var request = URLRequest(
            url: config.apiURL.appending(path: "captures").appending(path: serverId))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rawText": rawText])
        let (_, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CaptureAPIError.httpStatus(httpResponse.statusCode)
        }
    }
}

public enum CaptureAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}
