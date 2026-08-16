import ChronicleDesktopCore
import Foundation

struct RecallSearchSnapshot: Equatable {
    let hits: [RowItem]
    let hiddenCount: Int
    let degraded: Bool
}

struct RecallSearchStart {
    let initial: RecallSearchSnapshot

    fileprivate let query: String
    fileprivate let includeDismissed: Bool
    fileprivate let localLiteral: [RowItem]
    fileprivate let remote: RecallSearchRemote?
}

struct RecallSearchRemote {
    let find: (String, Bool) async throws -> FindResponse
    let setDismissed: (String, String, Bool) async throws -> Void
}

@MainActor
struct RecallSearchDependencies {
    let sessionIsCurrent: (UInt64) -> Bool
    let localSearch: (String) -> [RowItem]
    let cachedDismissedIDs: (String) -> Set<String>
    let localSemanticSearch: (String) async -> [RowItem]
    let remote: () -> RecallSearchRemote?
}

/// Runs the shared Desktop recall policy without owning either surface's UI
/// lifecycle. MainView and the quick panel keep their own task cancellation and
/// presentation state, while this coordinator keeps layered search ordering,
/// dismissal filtering, and offline fallback identical.
@MainActor
struct RecallSearchCoordinator {
    private let dependencies: RecallSearchDependencies

    init(clients: CaptureClients) {
        dependencies = RecallSearchDependencies(
            sessionIsCurrent: clients.session.isCurrent,
            localSearch: clients.localSearch,
            cachedDismissedIDs: clients.cachedFindDismissedIDs,
            localSemanticSearch: clients.localSemanticSearch,
            remote: {
                guard let client = clients.recall() else { return nil }
                return RecallSearchRemote(
                    find: { query, includeDismissed in
                        try await client.find(
                            q: query,
                            includeDismissed: includeDismissed
                        )
                    },
                    setDismissed: { query, targetID, dismissed in
                        try await client.setFindResultDismissed(
                            q: query,
                            targetId: targetID,
                            dismissed: dismissed
                        )
                    }
                )
            }
        )
    }

    init(dependencies: RecallSearchDependencies) {
        self.dependencies = dependencies
    }

    func start(query: String, includeDismissed: Bool) -> RecallSearchStart {
        let remote = dependencies.remote()
        let localLiteral = dependencies.localSearch(query)
        let excludedIDs = includeDismissed
            ? Set<String>()
            : dependencies.cachedDismissedIDs(query)
        let initialHits = if remote == nil {
            localLiteral.filter { !excludedIDs.contains($0.id) }
        } else {
            RowMerge.localRecallSupplement(
                localLiteral,
                id: \.id,
                synced: \.synced,
                dirty: \.dirty,
                excludedIDs: excludedIDs
            )
        }
        return RecallSearchStart(
            initial: RecallSearchSnapshot(
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

    func resolve(
        _ search: RecallSearchStart,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async -> RecallSearchSnapshot? {
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
            // A cancelled or stale remote request must not replace newer UI state
            // with its local fallback. A current failure still degrades cleanly.
            guard searchIsCurrent() else { return nil }
            return fallbackSnapshot(
                query: search.query,
                includeDismissed: search.includeDismissed,
                localLiteral: search.localLiteral,
                semantic: semantic
            )
        }
    }

    func setDismissed(
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
        localLiteral: [RowItem],
        semantic: [RowItem],
        response: FindResponse
    ) -> RecallSearchSnapshot {
        let serverRows = response.items.map(RowItem.init)
        let dismissedIDs = dependencies.cachedDismissedIDs(query).union(
            serverRows.filter(\.dismissed).map(\.id)
        )
        let excludedIDs = includeDismissed ? Set<String>() : dismissedIDs
        let visibleServerRows = RowMerge.visibleRecallResults(
            serverRows,
            includeDismissed: includeDismissed,
            id: \.id,
            dismissed: \.dismissed,
            excludedIDs: dismissedIDs
        )
        var hits = RowMerge.localRecallSupplement(
            localLiteral,
            id: \.id,
            synced: \.synced,
            dirty: \.dirty,
            excludedIDs: excludedIDs
        )
        hits = merging(hits, with: visibleServerRows)
        hits = merging(
            hits,
            with: RowMerge.localRecallSupplement(
                semantic,
                id: \.id,
                synced: \.synced,
                dirty: \.dirty,
                excludedIDs: excludedIDs
            )
        )
        return RecallSearchSnapshot(
            hits: hits,
            hiddenCount: max(
                response.hiddenCount ?? serverRows.filter(\.dismissed).count,
                dismissedIDs.count
            ),
            degraded: response.degraded
        )
    }

    private func fallbackSnapshot(
        query: String,
        includeDismissed: Bool,
        localLiteral: [RowItem],
        semantic: [RowItem]
    ) -> RecallSearchSnapshot {
        let dismissedIDs = dependencies.cachedDismissedIDs(query)
        let excludedIDs = includeDismissed ? Set<String>() : dismissedIDs
        var hits = localLiteral.filter { !excludedIDs.contains($0.id) }
        hits = merging(
            hits,
            with: semantic.filter { !excludedIDs.contains($0.id) }
        )
        return RecallSearchSnapshot(
            hits: hits,
            hiddenCount: dismissedIDs.count,
            degraded: false
        )
    }

    private func merging(_ existing: [RowItem], with incoming: [RowItem]) -> [RowItem] {
        RowMerge.preservingOrder(
            existing: existing,
            incoming: incoming,
            id: \.id
        ) { current, incoming in
            current.mergeDisplayEvidence(from: incoming)
        }
    }
}
