import Foundation

public enum CaptureSyncStatus: Equatable, Sendable {
    case completed
    case inProgress
    case failed
}

public struct CaptureSyncSummary: Equatable, Sendable {
    public let createsSent: Int
    public let updatesPushed: Int
    public let pendingCreates: Int
    public let pendingUpdates: Int
    public let status: CaptureSyncStatus

    public init(
        createsSent: Int = 0,
        updatesPushed: Int = 0,
        pendingCreates: Int = 0,
        pendingUpdates: Int = 0,
        status: CaptureSyncStatus = .completed
    ) {
        self.createsSent = createsSent
        self.updatesPushed = updatesPushed
        self.pendingCreates = pendingCreates
        self.pendingUpdates = pendingUpdates
        self.status = status
    }

    public var syncedCount: Int {
        createsSent + updatesPushed
    }

    public var remaining: Int {
        pendingCreates + pendingUpdates
    }

    public var changed: Bool {
        syncedCount > 0
    }
}

public enum CaptureSyncOutcome: Equatable, Sendable {
    case synced
    case alreadyInFlight
    case failed
}

/// Owns the offline create/update drain and its concurrency invariants.
///
/// UI feedback deliberately stays with the caller. This type advances only the
/// local source of truth and reports what changed, so it can run from launch,
/// manual retry, or an optimistic edit without depending on AppKit.
public final class CaptureSyncCoordinator: @unchecked Sendable {
    private let store: LocalCaptureStore
    private let createGate: CaptureSyncGate
    private let updateDrainGate = CaptureUpdateDrainGate()

    public convenience init(store: LocalCaptureStore) {
        self.init(store: store, createGate: CaptureSyncGate())
    }

    // Internal injection keeps the concurrency primitive out of the public API
    // while still allowing Core tests to exercise the already-in-flight path.
    init(store: LocalCaptureStore, createGate: CaptureSyncGate) {
        self.store = store
        self.createGate = createGate
    }

    /// Drain never-created captures, then replay edits to server-backed rows.
    /// The update pass runs after creates so an edit racing an in-flight create is
    /// PATCHed immediately when `markCreateSynced` leaves that row dirty.
    public func syncPending(using transport: any CaptureSyncTransport) async -> CaptureSyncSummary {
        let pending: [LocalCaptureRecord]
        do {
            pending = try store.pendingSync(limit: 1000)
        } catch {
            return summary(status: .failed)
        }

        var createsSent = 0
        var createStatus = CaptureSyncStatus.completed
        for record in pending {
            switch await syncCreate(record, using: transport).outcome {
            case .synced:
                createsSent += 1
            case .alreadyInFlight:
                if createStatus == .completed {
                    createStatus = .inProgress
                }
            case .failed:
                createStatus = .failed
            }
        }

        let updateResult = await drainPendingUpdates(using: transport)
        return summary(
            createsSent: createsSent,
            updatesPushed: updateResult.pushed,
            status: combinedStatus(createStatus, updateResult.status)
        )
    }

    /// Replay server-backed rows edited since their last successful sync.
    ///
    /// Only one update drain runs at a time. A concurrent request asks the active
    /// drain for another pass, which closes the race between its final store read
    /// and releasing the gate. Each row is also re-read after PATCH so an edit
    /// made during the request is sent next instead of being overwritten by an
    /// older response that finishes later.
    @discardableResult
    public func pushPendingUpdates(
        using transport: any CaptureSyncTransport
    ) async -> CaptureSyncSummary {
        let result = await drainPendingUpdates(using: transport)
        return summary(updatesPushed: result.pushed, status: result.status)
    }

    /// Sync one local create at most once concurrently.
    @discardableResult
    public func sync(
        _ record: LocalCaptureRecord,
        using transport: any CaptureSyncTransport
    ) async -> CaptureSyncOutcome {
        let create = await syncCreate(record, using: transport)
        if create.needsUpdatePush {
            _ = await drainPendingUpdates(using: transport)
        }
        return create.outcome
    }

    private func syncCreate(
        _ record: LocalCaptureRecord,
        using transport: any CaptureSyncTransport
    ) async -> CreateSyncResult {
        guard createGate.begin(record.id) else {
            return CreateSyncResult(outcome: .alreadyInFlight, needsUpdatePush: false)
        }
        defer { createGate.end(record.id) }

        do {
            let serverID = try await transport.send(record.payload)
            let needsUpdatePush = try store.markCreateSynced(
                localId: record.id,
                serverId: serverID,
                sentText: record.payload.rawText,
            )
            return CreateSyncResult(outcome: .synced, needsUpdatePush: needsUpdatePush)
        } catch {
            try? store.markFailed(localId: record.id, error: error)
            return CreateSyncResult(outcome: .failed, needsUpdatePush: false)
        }
    }

    private func drainPendingUpdates(
        using transport: any CaptureSyncTransport
    ) async -> UpdateDrainResult {
        guard updateDrainGate.beginOrRequestAnotherPass() else {
            return UpdateDrainResult(pushed: 0, status: .inProgress)
        }

        var pushed = 0
        var failed = false
        var runAnotherPass = true
        while runAnotherPass {
            let pass = await pushUpdatePass(using: transport)
            pushed += pass.pushed
            failed = failed || pass.failed
            runAnotherPass = updateDrainGate.finishPass()
        }

        return UpdateDrainResult(
            pushed: pushed,
            status: failed ? .failed : .completed
        )
    }

    private func pushUpdatePass(
        using transport: any CaptureSyncTransport
    ) async -> (pushed: Int, failed: Bool) {
        let dirty: [LocalCaptureRecord]
        do {
            dirty = try store.pendingUpdates(limit: 1000)
        } catch {
            return (0, true)
        }

        var pushed = 0
        var failed = false
        for record in dirty {
            let result = await pushLatestUpdates(
                localID: record.id,
                using: transport
            )
            pushed += result.pushed
            failed = failed || result.failed
        }
        return (pushed, failed)
    }

    private func pushLatestUpdates(
        localID: String,
        using transport: any CaptureSyncTransport
    ) async -> (pushed: Int, failed: Bool) {
        var pushed = 0
        while true {
            let record: LocalCaptureRecord
            do {
                guard let current = try store.find(localId: localID), current.needsUpdatePush else {
                    return (pushed, false)
                }
                record = current
            } catch {
                return (pushed, true)
            }

            guard let serverID = record.serverId else {
                return (pushed, true)
            }
            do {
                try await transport.update(
                    serverId: serverID,
                    rawText: record.payload.rawText,
                )
                try store.markUpdatePushed(
                    localId: record.id,
                    syncedAt: record.updatedAt,
                )
                pushed += 1
            } catch {
                try? store.markFailed(localId: record.id, error: error)
                return (pushed, true)
            }
        }
    }

    private func summary(
        createsSent: Int = 0,
        updatesPushed: Int = 0,
        status: CaptureSyncStatus
    ) -> CaptureSyncSummary {
        do {
            let backlog = try store.syncBacklog()
            return CaptureSyncSummary(
                createsSent: createsSent,
                updatesPushed: updatesPushed,
                pendingCreates: backlog.pendingCreates,
                pendingUpdates: backlog.pendingUpdates,
                status: status
            )
        } catch {
            return CaptureSyncSummary(
                createsSent: createsSent,
                updatesPushed: updatesPushed,
                status: .failed
            )
        }
    }

    private func combinedStatus(
        _ lhs: CaptureSyncStatus,
        _ rhs: CaptureSyncStatus
    ) -> CaptureSyncStatus {
        if lhs == .failed || rhs == .failed { return .failed }
        if lhs == .inProgress || rhs == .inProgress { return .inProgress }
        return .completed
    }
}

private extension LocalCaptureRecord {
    var needsUpdatePush: Bool {
        guard serverId != nil else { return false }
        guard let syncedAt else { return true }
        return updatedAt > syncedAt
    }
}

private struct UpdateDrainResult {
    let pushed: Int
    let status: CaptureSyncStatus
}

private struct CreateSyncResult {
    let outcome: CaptureSyncOutcome
    let needsUpdatePush: Bool
}

/// Coalesces concurrent update-drain requests without losing a request made as
/// the active drain is finishing its last pass.
private final class CaptureUpdateDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var anotherPassRequested = false

    func beginOrRequestAnotherPass() -> Bool {
        lock.withLock {
            guard !isRunning else {
                anotherPassRequested = true
                return false
            }
            isRunning = true
            return true
        }
    }

    /// Atomically either keeps ownership for a requested pass or releases it.
    func finishPass() -> Bool {
        lock.withLock {
            guard anotherPassRequested else {
                isRunning = false
                return false
            }
            anotherPassRequested = false
            return true
        }
    }
}
