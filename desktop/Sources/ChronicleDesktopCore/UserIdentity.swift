import Foundation

/// Minimal authenticated identity returned by `GET /users/me`. The desktop uses
/// only the server-issued user id to establish its on-device account boundary.
public struct ChronicleUserIdentity: Decodable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public final class UserIdentityAPIClient: @unchecked Sendable {
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

    public func makeRequest() -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "users/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func me() async throws -> ChronicleUserIdentity {
        let (data, response) = try await AuthedTransport.send(
            makeRequest(),
            session: session,
            refresher: refresher
        )
        guard let http = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthAPIError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ChronicleUserIdentity.self, from: data)
    }
}
