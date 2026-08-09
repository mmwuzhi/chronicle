import Foundation

public enum CaptureShareExpiry: String, CaseIterable, Codable, Sendable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case never
}

public struct CaptureShare: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let captureId: String
    public let snapshotRawText: String
    public let capturedAt: String
    public let expiresAt: String?
    public let createdAt: String
    public let secret: String
    public let url: String

    public init(
        id: String,
        captureId: String,
        snapshotRawText: String,
        capturedAt: String,
        expiresAt: String?,
        createdAt: String,
        secret: String,
        url: String
    ) {
        self.id = id
        self.captureId = captureId
        self.snapshotRawText = snapshotRawText
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.secret = secret
        self.url = url
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt, let expiry = CaptureShareDate.parse(expiresAt) else { return false }
        return expiry <= date
    }
}

public struct CaptureSharePage: Codable, Equatable, Sendable {
    public let items: [CaptureShare]
    public let nextCursor: String?

    public init(items: [CaptureShare], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

private enum CaptureShareDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }
}

public protocol CaptureShareClient: Sendable {
    func list(cursor: String?, limit: Int, captureID: String?) async throws -> CaptureSharePage
    func create(
        captureID: String,
        expiresIn: CaptureShareExpiry,
        snapshotRawText: String
    ) async throws -> CaptureShare
    func revoke(id: String) async throws
}

public final class CaptureShareAPIClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig,
        session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func makeListRequest(
        cursor: String? = nil,
        limit: Int = 50,
        captureID: String? = nil
    ) -> URLRequest {
        let endpoint = config.apiURL.appending(path: "shares")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            captureID.map { URLQueryItem(name: "captureId", value: $0) },
            cursor.map { URLQueryItem(name: "cursor", value: $0) },
            URLQueryItem(name: "limit", value: String(limit)),
        ].compactMap { $0 }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        authorize(&request)
        return request
    }

    public func list(
        cursor: String?,
        limit: Int,
        captureID: String?
    ) async throws -> CaptureSharePage {
        let (data, response) = try await AuthedTransport.send(
            makeListRequest(cursor: cursor, limit: limit, captureID: captureID),
            session: session,
            refresher: refresher
        )
        try Self.validate(response)
        return try JSONDecoder().decode(CaptureSharePage.self, from: data)
    }

    public func makeCreateRequest(
        captureID: String,
        expiresIn: CaptureShareExpiry,
        snapshotRawText: String
    ) throws -> URLRequest {
        var request = URLRequest(
            url: config.apiURL
                .appending(path: "captures")
                .appending(path: captureID)
                .appending(path: "shares")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(
            CaptureShareCreateRequest(
                expiresIn: expiresIn.rawValue,
                snapshotRawText: snapshotRawText
            )
        )
        return request
    }

    public func create(
        captureID: String,
        expiresIn: CaptureShareExpiry,
        snapshotRawText: String
    ) async throws -> CaptureShare {
        let request = try makeCreateRequest(
            captureID: captureID,
            expiresIn: expiresIn,
            snapshotRawText: snapshotRawText
        )
        let (data, response) = try await AuthedTransport.send(
            request, session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode(CaptureShare.self, from: data)
    }

    public func makeRevokeRequest(id: String) -> URLRequest {
        var request = URLRequest(
            url: config.apiURL.appending(path: "shares").appending(path: id)
        )
        request.httpMethod = "DELETE"
        authorize(&request)
        return request
    }

    public func revoke(id: String) async throws {
        let (_, response) = try await AuthedTransport.send(
            makeRevokeRequest(id: id), session: session, refresher: refresher)
        try Self.validate(response)
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
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

private struct CaptureShareCreateRequest: Encodable {
    let expiresIn: String
    let snapshotRawText: String
}

extension CaptureShareAPIClient: CaptureShareClient {}
