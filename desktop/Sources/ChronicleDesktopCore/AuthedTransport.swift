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
public actor AuthRefresher {
    private let mint: @Sendable () async -> String?
    private var inFlight: Task<String?, Never>?

    public init(mint: @escaping @Sendable () async -> String?) {
        self.mint = mint
    }

    // Returns a freshly minted access token, or nil if refresh failed. Callers
    // racing the same expiry share the one in-flight mint instead of each POSTing
    // /refresh and double-rotating the cookie.
    public func token() async -> String? {
        if let inFlight { return await inFlight.value }
        let task = Task { await mint() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
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
            let refresher, let token = await refresher.token()
        else { return result }
        var retry = request
        retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: retry)
    }
}
