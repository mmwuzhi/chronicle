import CryptoKit
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

public struct RefreshResponse: Codable, Equatable {
    public var accessToken: String?

    public init(accessToken: String? = nil) {
        self.accessToken = accessToken
    }
}

public enum OAuthProvider: String, CaseIterable, Sendable {
    case google
    case github
}

public struct DesktopOAuthExchangeRequest: Codable, Equatable {
    public var code: String
    public var codeVerifier: String

    public init(code: String, codeVerifier: String) {
        self.code = code
        self.codeVerifier = codeVerifier
    }
}

public struct DesktopOAuthPKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public static func generate() -> DesktopOAuthPKCE {
        var generator = SystemRandomNumberGenerator()
        let random = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let verifier = base64URL(random)
        return DesktopOAuthPKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

    public func desktopOAuthStartURL(provider: OAuthProvider, codeChallenge: String) throws -> URL {
        let endpoint = apiURL.appending(path: "auth/\(provider.rawValue)")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AuthAPIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "desktop"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw AuthAPIError.invalidResponse }
        return url
    }

    public func makeDesktopOAuthExchangeRequest(code: String, codeVerifier: String) throws -> URLRequest {
        var request = URLRequest(url: apiURL.appending(path: "auth/oauth/desktop/exchange"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DesktopOAuthExchangeRequest(code: code, codeVerifier: codeVerifier),
        )
        return request
    }

    public func exchangeDesktopOAuthCode(_ code: String, codeVerifier: String) async throws -> String {
        let request = try makeDesktopOAuthExchangeRequest(code: code, codeVerifier: codeVerifier)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthAPIError.httpStatus(httpResponse.statusCode)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        guard let token = decoded.accessToken, !token.isEmpty else {
            throw AuthAPIError.missingAccessToken
        }
        return token
    }

    public func makeRefreshRequest() -> URLRequest {
        var request = URLRequest(url: apiURL.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        // The refresh token rides as an httpOnly cookie set at login; URLSession's
        // shared cookie store persists it (30-day TTL) and attaches it here, so the
        // desktop never has to hold the refresh token itself.
        request.httpShouldHandleCookies = true
        return request
    }

    // Exchange the stored refresh cookie for a fresh short-lived access token.
    // Throws httpStatus(401) when there is no valid refresh cookie (signed out).
    public func refresh() async throws -> String {
        let request = makeRefreshRequest()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthAPIError.httpStatus(httpResponse.statusCode)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        guard let token = decoded.accessToken, !token.isEmpty else {
            throw AuthAPIError.missingAccessToken
        }
        return token
    }

    public func makeLogoutRequest() -> URLRequest {
        var request = URLRequest(url: apiURL.appending(path: "auth/logout"))
        request.httpMethod = "POST"
        // /auth/logout reads the refresh token from its httpOnly cookie (not an
        // Authorization header), so the cookie must ride along to be revoked.
        request.httpShouldHandleCookies = true
        return request
    }

    // Best-effort server-side sign-out: revoke the refresh token and clear its
    // cookie. Throws on a non-2xx so callers can decide to ignore failures.
    // `cookies` lets a caller that has already cleared the shared cookie store
    // (so a crash mid-logout can't leave a re-authenticating cookie behind) still
    // present the captured refresh cookie explicitly; empty falls back to the
    // shared store, the original behavior.
    public func logout(cookies: [HTTPCookie] = []) async throws {
        var request = makeLogoutRequest()
        if !cookies.isEmpty {
            request.httpShouldHandleCookies = false
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthAPIError.httpStatus(httpResponse.statusCode)
        }
    }
}

public enum AuthAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case missingAccessToken
    case mfaRequired
}
