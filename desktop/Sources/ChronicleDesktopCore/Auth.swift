import Foundation

public struct LoginRequest: Codable, Equatable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public struct LoginResponse: Codable, Equatable {
    public var accessToken: String?
    public var mfaRequired: Bool?
    public var mfaToken: String?

    public init(accessToken: String? = nil, mfaRequired: Bool? = nil, mfaToken: String? = nil) {
        self.accessToken = accessToken
        self.mfaRequired = mfaRequired
        self.mfaToken = mfaToken
    }
}

public final class AuthAPIClient {
    private let apiURL: URL
    private let session: URLSession

    public init(apiURL: URL, session: URLSession = .shared) {
        self.apiURL = apiURL
        self.session = session
    }

    public func makeLoginRequest(email: String, password: String) throws -> URLRequest {
        var request = URLRequest(url: apiURL.appending(path: "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(email: email, password: password))
        return request
    }

    public func login(email: String, password: String) async throws -> LoginResponse {
        let request = try makeLoginRequest(email: email, password: password)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthAPIError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }
}

public enum AuthAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case missingAccessToken
    case mfaRequired
}
