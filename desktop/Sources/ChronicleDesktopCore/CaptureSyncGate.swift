import Foundation

/// Prevents two retry paths from POSTing the same local capture concurrently.
/// Callers must pair every successful `begin` with `end`.
public final class CaptureSyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    public init() {}

    public func begin(_ localID: String) -> Bool {
        lock.withLock {
            inFlight.insert(localID).inserted
        }
    }

    public func end(_ localID: String) {
        _ = lock.withLock {
            inFlight.remove(localID)
        }
    }
}
