import Foundation
import Testing

@testable import ChronicleDesktopCore

// Thread-safe sink for the `@Sendable` onChange callback so tests can record
// fires without tripping Swift's concurrent-capture check.
private final class HealthRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _fires: [SessionHealth] = []

    func record(_ h: SessionHealth) {
        lock.lock()
        _fires.append(h)
        lock.unlock()
    }

    var fires: [SessionHealth] {
        lock.lock()
        defer { lock.unlock() }
        return _fires
    }
}

@Suite struct SessionMonitorTests {
    // MARK: - Refresh-result classification (the "offline ≠ sign-out" rule)

    @Test func successClassifiesActive() {
        #expect(sessionSignal(forRefreshResult: .success("tok")) == .active)
    }

    @Test func http401ClassifiesExpired() {
        let r = Result<String, Error>.failure(AuthAPIError.httpStatus(401))
        #expect(sessionSignal(forRefreshResult: r) == .expired)
    }

    @Test func networkErrorIsInconclusive() {
        let r = Result<String, Error>.failure(URLError(.notConnectedToInternet))
        #expect(sessionSignal(forRefreshResult: r) == nil)
    }

    @Test func serverErrorIsInconclusive() {
        let r = Result<String, Error>.failure(AuthAPIError.httpStatus(503))
        #expect(sessionSignal(forRefreshResult: r) == nil)
    }

    // MARK: - State machine + change notification

    @Test func startsUnknownAndSilent() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        #expect(monitor.health == .unknown)
        #expect(rec.fires.isEmpty)
    }

    @Test func firesOnceOnExpiry() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        monitor.noteExpired()
        #expect(monitor.health == .expired)
        #expect(rec.fires == [.expired])
    }

    @Test func dedupesRepeatedExpiry() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        monitor.noteExpired()
        monitor.noteExpired()
        monitor.noteExpired()
        #expect(rec.fires == [.expired])
    }

    @Test func healsOnSignIn() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        monitor.noteExpired()
        monitor.noteActive()
        #expect(monitor.health == .active)
        #expect(rec.fires == [.expired, .active])
    }

    // A dropped connection while signed out must not flip the UI back to "OK":
    // an inconclusive signal is a no-op until a real 200/401 updates the status.
    @Test func inconclusiveSignalDoesNotChangeState() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        monitor.noteExpired()
        monitor.apply(nil)
        monitor.apply(sessionSignal(forRefreshResult: .failure(URLError(.timedOut))))
        #expect(monitor.health == .expired)
        #expect(rec.fires == [.expired])
    }

    @Test func applyRoutesSignalsThroughTheStateMachine() {
        let rec = HealthRecorder()
        let monitor = SessionMonitor { rec.record($0) }
        monitor.apply(.expired)
        monitor.apply(.active)
        monitor.apply(.active)
        #expect(rec.fires == [.expired, .active])
    }
}
