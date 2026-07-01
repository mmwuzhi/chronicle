import Foundation

public let desktopQuickCaptureSource = "desktop_quick_capture"

public struct CapturePayload: Codable, Equatable, Sendable {
    public var rawText: String
    public var mediaType: String
    public var classifiedAs: String
    public var source: String
    public var remindAt: Date?
    // Only meaningful with remindAt set. nil (default) → hide until due; false →
    // notify-only (the sticky stays visible and still pings). Encoded only when
    // present, so the server default (hide) applies when it's nil.
    public var remindHide: Bool?

    public init(
        rawText: String,
        mediaType: String = "text",
        classifiedAs: String = "unclassified",
        source: String = desktopQuickCaptureSource,
        remindAt: Date? = nil,
        remindHide: Bool? = nil
    ) {
        self.rawText = rawText
        self.mediaType = mediaType
        self.classifiedAs = classifiedAs
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

public final class CaptureAPIClient: CaptureSending, @unchecked Sendable {
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

    public func makeRequest(for payload: CapturePayload) throws -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "captures"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
}

public enum CaptureAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}
