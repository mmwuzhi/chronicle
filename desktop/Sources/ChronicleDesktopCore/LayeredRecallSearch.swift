import Foundation

public struct LayeredRecallSnapshot<Row: Equatable & Sendable>: Equatable, Sendable {
    public let hits: [Row]
    public let hiddenCount: Int
    public let degraded: Bool

    public init(hits: [Row], hiddenCount: Int, degraded: Bool) {
        self.hits = hits
        self.hiddenCount = hiddenCount
        self.degraded = degraded
    }
}

@MainActor
public struct LayeredRecallRemoteResponse<Row: Equatable & Sendable> {
    public let rows: [Row]
    public let degraded: Bool
    public let hiddenCount: Int?

    public init(rows: [Row], degraded: Bool, hiddenCount: Int?) {
        self.rows = rows
        self.degraded = degraded
        self.hiddenCount = hiddenCount
    }
}

@MainActor
public struct LayeredRecallRemote<Row: Equatable & Sendable> {
    fileprivate let find: (String, Bool) async throws -> LayeredRecallRemoteResponse<Row>
    fileprivate let setDismissed: (String, String, Bool) async throws -> Void

    public init(
        find: @escaping (String, Bool) async throws -> LayeredRecallRemoteResponse<Row>,
        setDismissed: @escaping (String, String, Bool) async throws -> Void
    ) {
        self.find = find
        self.setDismissed = setDismissed
    }
}

@MainActor
public struct LayeredRecallDependencies<Row: Equatable & Sendable> {
    fileprivate let sessionIsCurrent: (UInt64) -> Bool
    fileprivate let localSearch: (String) -> [Row]
    fileprivate let cachedDismissedIDs: (String) -> Set<String>
    fileprivate let localSemanticSearch: (String) async -> [Row]
    fileprivate let remote: () -> LayeredRecallRemote<Row>?

    public init(
        sessionIsCurrent: @escaping (UInt64) -> Bool,
        localSearch: @escaping (String) -> [Row],
        cachedDismissedIDs: @escaping (String) -> Set<String>,
        localSemanticSearch: @escaping (String) async -> [Row],
        remote: @escaping () -> LayeredRecallRemote<Row>?
    ) {
        self.sessionIsCurrent = sessionIsCurrent
        self.localSearch = localSearch
        self.cachedDismissedIDs = cachedDismissedIDs
        self.localSemanticSearch = localSemanticSearch
        self.remote = remote
    }
}

@MainActor
public struct LayeredRecallStart<Row: Equatable & Sendable> {
    public let initial: LayeredRecallSnapshot<Row>

    fileprivate let query: String
    fileprivate let includeDismissed: Bool
    fileprivate let localLiteral: [Row]
    fileprivate let remote: LayeredRecallRemote<Row>?
}

/// Platform-free layered recall orchestration shared by Desktop surfaces.
///
/// The app target owns presentation and task storage. This Core coordinator owns
/// source ordering, dismissal filtering, stale-result rejection, evidence merging,
/// and offline fallback without depending on SwiftUI, AppKit, or an app row type.
@MainActor
public struct LayeredRecallCoordinator<Row: Equatable & Sendable> {
    private let dependencies: LayeredRecallDependencies<Row>
    private let id: KeyPath<Row, String>
    private let synced: KeyPath<Row, Bool>
    private let dirty: KeyPath<Row, Bool>
    private let dismissed: WritableKeyPath<Row, Bool>
    private let mergeDuplicate: (inout Row, Row) -> Void

    public init(
        dependencies: LayeredRecallDependencies<Row>,
        id: KeyPath<Row, String>,
        synced: KeyPath<Row, Bool>,
        dirty: KeyPath<Row, Bool>,
        dismissed: WritableKeyPath<Row, Bool>,
        mergeDuplicate: @escaping (inout Row, Row) -> Void
    ) {
        self.dependencies = dependencies
        self.id = id
        self.synced = synced
        self.dirty = dirty
        self.dismissed = dismissed
        self.mergeDuplicate = mergeDuplicate
    }

    public func start(query: String, includeDismissed: Bool) -> LayeredRecallStart<Row> {
        let remote = dependencies.remote()
        let localLiteral = dependencies.localSearch(query)
        let excludedIDs = includeDismissed
            ? Set<String>()
            : dependencies.cachedDismissedIDs(query)
        let initialHits = if remote == nil {
            localLiteral.filter { !excludedIDs.contains($0[keyPath: id]) }
        } else {
            RowMerge.localRecallSupplement(
                localLiteral,
                id: id,
                synced: synced,
                dirty: dirty,
                excludedIDs: excludedIDs
            )
        }
        return LayeredRecallStart(
            initial: LayeredRecallSnapshot(
                hits: initialHits,
                hiddenCount: 0,
                degraded: false
            ),
            query: query,
            includeDismissed: includeDismissed,
            localLiteral: localLiteral,
            remote: remote
        )
    }

    public func resolve(
        _ search: LayeredRecallStart<Row>,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async -> LayeredRecallSnapshot<Row>? {
        func searchIsCurrent() -> Bool {
            !Task.isCancelled
                && dependencies.sessionIsCurrent(sessionGeneration)
                && targetIsCurrent()
        }

        guard searchIsCurrent() else { return nil }
        let semantic = await dependencies.localSemanticSearch(search.query)
        guard searchIsCurrent() else { return nil }

        guard let remote = search.remote else {
            return fallbackSnapshot(
                query: search.query,
                includeDismissed: search.includeDismissed,
                localLiteral: search.localLiteral,
                semantic: semantic
            )
        }

        do {
            let response = try await remote.find(search.query, true)
            guard searchIsCurrent() else { return nil }
            return onlineSnapshot(
                query: search.query,
                includeDismissed: search.includeDismissed,
                localLiteral: search.localLiteral,
                semantic: semantic,
                response: response
            )
        } catch {
            guard searchIsCurrent() else { return nil }
            return fallbackSnapshot(
                query: search.query,
                includeDismissed: search.includeDismissed,
                localLiteral: search.localLiteral,
                semantic: semantic
            )
        }
    }

    public func setDismissed(
        query: String,
        targetID: String,
        dismissed: Bool,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async throws -> Bool {
        func mutationIsCurrent() -> Bool {
            !Task.isCancelled
                && dependencies.sessionIsCurrent(sessionGeneration)
                && targetIsCurrent()
        }

        guard mutationIsCurrent(), let remote = dependencies.remote() else {
            return false
        }
        do {
            try await remote.setDismissed(query, targetID, dismissed)
        } catch {
            guard mutationIsCurrent() else { return false }
            throw error
        }
        return mutationIsCurrent()
    }

    private func onlineSnapshot(
        query: String,
        includeDismissed: Bool,
        localLiteral: [Row],
        semantic: [Row],
        response: LayeredRecallRemoteResponse<Row>
    ) -> LayeredRecallSnapshot<Row> {
        let serverDismissedRows = response.rows.filter { $0[keyPath: dismissed] }
        let dismissedIDs = dependencies.cachedDismissedIDs(query).union(
            serverDismissedRows.map { $0[keyPath: id] }
        )
        let excludedIDs = includeDismissed ? Set<String>() : dismissedIDs
        let visibleServerRows = RowMerge.visibleRecallResults(
            response.rows,
            includeDismissed: includeDismissed,
            id: id,
            dismissed: dismissed,
            excludedIDs: dismissedIDs
        )
        var hits = RowMerge.localRecallSupplement(
            localLiteral,
            id: id,
            synced: synced,
            dirty: dirty,
            excludedIDs: excludedIDs
        )
        hits = merging(hits, with: visibleServerRows)
        hits = merging(
            hits,
            with: RowMerge.localRecallSupplement(
                semantic,
                id: id,
                synced: synced,
                dirty: dirty,
                excludedIDs: excludedIDs
            )
        )
        return LayeredRecallSnapshot(
            hits: hits,
            hiddenCount: max(
                response.hiddenCount ?? serverDismissedRows.count,
                dismissedIDs.count
            ),
            degraded: response.degraded
        )
    }

    private func fallbackSnapshot(
        query: String,
        includeDismissed: Bool,
        localLiteral: [Row],
        semantic: [Row]
    ) -> LayeredRecallSnapshot<Row> {
        let dismissedIDs = dependencies.cachedDismissedIDs(query)
        let excludedIDs = includeDismissed ? Set<String>() : dismissedIDs
        var hits = localLiteral.filter { !excludedIDs.contains($0[keyPath: id]) }
        hits = merging(
            hits,
            with: semantic.filter { !excludedIDs.contains($0[keyPath: id]) }
        )
        return LayeredRecallSnapshot(
            hits: hits,
            hiddenCount: dismissedIDs.count,
            degraded: false
        )
    }

    private func merging(_ existing: [Row], with incoming: [Row]) -> [Row] {
        RowMerge.preservingOrder(
            existing: existing,
            incoming: incoming,
            id: { $0[keyPath: id] },
            mergeDuplicate: mergeDuplicate
        )
    }
}
