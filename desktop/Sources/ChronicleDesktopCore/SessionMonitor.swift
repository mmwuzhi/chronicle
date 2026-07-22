import Foundation

// Server-session health, derived only from token-exchange outcomes.
//
// The desktop sat signed out for weeks once, silently queuing captures locally,
// because nothing surfaced that the session had lapsed. `SessionHealth` is the
// state the menu bar tooltip and sign-in surfaces read from.
//
// `.unknown` is the launch default and the offline state: we have not *proven*
// the session is dead, so the UI must not accuse the user of being signed out —
// a network error is not a sign-out (offline-first). `.active` means a token
// exchange just succeeded. `.expired` means the refresh cookie was explicitly
// rejected (HTTP 401): the user is signed out and any new capture will queue
// until they sign in again.
public enum SessionHealth: Sendable, Equatable {
    case unknown
    case active
    case expired
}

// What a refresh attempt tells us about the session. Kept separate from the
// state so the classification rule is a pure function, unit-testable without a
// live server: only an explicit 401 is a sign-out; any other failure (network,
// 5xx, decode) is inconclusive and leaves health unchanged.
public enum SessionSignal: Sendable, Equatable {
    case active
    case expired
}

// Maps a `AuthAPIClient.refresh()` outcome to a session signal, or nil when the
// outcome says nothing about session validity. This is where "network error ≠
// sign-out" lives: a URLError, a 5xx, or a decode failure returns nil so the UI
// stays put; only `AuthAPIError.httpStatus(401)` — the server rejecting the
// refresh cookie — flips to `.expired`.
public func sessionSignal(forRefreshResult result: Result<String, Error>) -> SessionSignal? {
    switch result {
    case .success:
        return .active
    case .failure(let error):
        if case AuthAPIError.httpStatus(401) = error { return .expired }
        return nil
    }
}

/// Tracks server-session health and notifies once per actual change.
///
/// Platform-free and thread-safe so it can be driven from the app's MainActor
/// sign-in paths and from async refresh callers alike. `onChange` fires only
/// when the health actually transitions, so the app can rebuild the menu bar
/// tooltip and sign-in surfaces idempotently without re-rendering on every mint.
public final class SessionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _health: SessionHealth
    private let onChange: @Sendable (SessionHealth) -> Void

    public init(
        initial: SessionHealth = .unknown,
        onChange: @escaping @Sendable (SessionHealth) -> Void
    ) {
        self._health = initial
        self.onChange = onChange
    }

    public var health: SessionHealth {
        lock.lock()
        defer { lock.unlock() }
        return _health
    }

    /// Feed a refresh outcome. A nil signal (network error, 5xx) is a no-op, so
    /// going offline never trips the signed-out UI.
    public func apply(_ signal: SessionSignal?) {
        switch signal {
        case .active: transition(to: .active)
        case .expired: transition(to: .expired)
        case nil: break
        }
    }

    /// A token exchange (launch refresh, mid-session mint, or a fresh sign-in)
    /// succeeded — the session is live.
    public func noteActive() { transition(to: .active) }

    /// The refresh cookie was rejected (HTTP 401) — the user is signed out.
    public func noteExpired() { transition(to: .expired) }

    private func transition(to next: SessionHealth) {
        lock.lock()
        guard _health != next else {
            lock.unlock()
            return
        }
        _health = next
        lock.unlock()
        onChange(next)
    }
}
