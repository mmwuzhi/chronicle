import Foundation

public let desktopQuickCaptureSource = "desktop_quick_capture"

public struct CapturePayload: Codable, Equatable {
    public var rawText: String
    public var mediaType: String
    public var classifiedAs: String
    public var source: String

    public init(
        rawText: String,
        mediaType: String = "text",
        classifiedAs: String = "unclassified",
        source: String = desktopQuickCaptureSource
    ) {
        self.rawText = rawText
        self.mediaType = mediaType
        self.classifiedAs = classifiedAs
        self.source = source
    }
}

public struct QueuedCapture: Codable, Equatable {
    public var payload: CapturePayload
    public var queuedAt: Date

    public init(payload: CapturePayload, queuedAt: Date = Date()) {
        self.payload = payload
        self.queuedAt = queuedAt
    }
}

public struct ChronicleConfig: Codable, Equatable {
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
    func send(_ payload: CapturePayload) async throws
}

public final class CaptureAPIClient: CaptureSending {
    private let config: ChronicleConfig
    private let session: URLSession

    public init(config: ChronicleConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func makeRequest(for payload: CapturePayload) throws -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "captures"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    public func send(_ payload: CapturePayload) async throws {
        let request = try makeRequest(for: payload)
        let (_, response) = try await session.data(for: request)
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
