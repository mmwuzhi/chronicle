import Foundation

// Single-flight access-token refresher shared by every desktop API client.
//
// The 15-minute access token (ChronicleConfig.token) is only minted at sign-in
// and at launch, so a window left open past 15 minutes would otherwise 401 on
// every request — capture sync, browse, recall, reminders — until the user
// relaunches or signs in again, despite a valid 30-day refresh cookie. This is
// the desktop counterpart to the web client's axios refresh interceptor.
//
// `mint` is supplied by the app layer (Core has no SettingsStore): it trades the
// refresh cookie for a fresh access token via AuthAPIClient.refresh(), persists
// it, and returns it. Concurrent 401s from independent clients coalesce onto one
// in-flight mint so the rotating refresh cookie is never spent twice at once.
public struct AuthRefreshResult: Equatable, Sendable {
    public let token: String
    public let sessionGeneration: UInt64

    public init(token: String, sessionGeneration: UInt64) {
        self.token = token
        self.sessionGeneration = sessionGeneration
    }
}

public actor AuthRefresher {
    private let mint: @Sendable (String) async -> AuthRefreshResult?
    private let permitsRetry: @Sendable (String, AuthRefreshResult) async -> Bool
    private var inFlight: (
        id: UUID,
        requestToken: String,
        task: Task<AuthRefreshResult?, Never>
    )?

    public init(
        mint: @escaping @Sendable (String) async -> AuthRefreshResult?,
        permitsRetry: @escaping @Sendable (String, AuthRefreshResult) async -> Bool
    ) {
        self.mint = mint
        self.permitsRetry = permitsRetry
    }

    // Returns a freshly minted access token, or nil if refresh failed. Callers
    // racing the same expiry share the one in-flight mint instead of each POSTing
    // /refresh and double-rotating the cookie.
    public func token(refreshing requestToken: String) async -> AuthRefreshResult? {
        if let existing = inFlight {
            let value = await existing.task.value
            if inFlight?.id == existing.id { inFlight = nil }
            if existing.requestToken == requestToken { return value }
            // A new account/session arrived while the old refresh was in flight.
            // Let the old cookie rotation settle, then mint specifically for the
            // new request instead of sharing its credential or rotating twice.
            return await token(refreshing: requestToken)
        }
        let id = UUID()
        let task = Task { await mint(requestToken) }
        inFlight = (id, requestToken, task)
        let value = await task.value
        if inFlight?.id == id { inFlight = nil }
        return value
    }

    public func mayRetry(from requestToken: String, with result: AuthRefreshResult) async -> Bool {
        await permitsRetry(requestToken, result)
    }
}

enum AuthedTransport {
    // Sends an authed request; on HTTP 401 it trades the refresh cookie for a new
    // access token via `refresher`, re-stamps the Authorization header, and retries
    // exactly once. No refresher (the default for tests / one-shot clients) or a
    // failed refresh returns the original 401 unchanged, so callers still surface
    // "session expired". Every non-401 response passes straight through.
    static func send(
        _ request: URLRequest, session: URLSession, refresher: AuthRefresher?
    ) async throws -> (Data, URLResponse) {
        let result = try await session.data(for: request)
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 401,
              let refresher,
              let requestToken = bearerToken(in: request),
              let refresh = await refresher.token(refreshing: requestToken),
              await refresher.mayRetry(from: requestToken, with: refresh)
        else { return result }
        var retry = request
        retry.setValue("Bearer \(refresh.token)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: retry)
    }

    private static func bearerToken(in request: URLRequest) -> String? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ")
        else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }
}
