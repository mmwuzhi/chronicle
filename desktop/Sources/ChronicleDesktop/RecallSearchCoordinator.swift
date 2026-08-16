import ChronicleDesktopCore
import Foundation

typealias RecallSearchSnapshot = LayeredRecallSnapshot<RowItem>
typealias RecallSearchStart = LayeredRecallStart<RowItem>

/// Adapts app clients and row projections to the platform-free Core policy.
@MainActor
struct RecallSearchCoordinator {
    private let core: LayeredRecallCoordinator<RowItem>

    init(clients: CaptureClients) {
        core = LayeredRecallCoordinator(
            dependencies: LayeredRecallDependencies(
                sessionIsCurrent: clients.session.isCurrent,
                localSearch: clients.localSearch,
                cachedDismissedIDs: clients.cachedFindDismissedIDs,
                localSemanticSearch: clients.localSemanticSearch,
                remote: {
                    guard let client = clients.recall() else { return nil }
                    return LayeredRecallRemote(
                        find: { query, includeDismissed in
                            let response = try await client.find(
                                q: query,
                                includeDismissed: includeDismissed
                            )
                            return LayeredRecallRemoteResponse(
                                rows: response.items.map(RowItem.init),
                                degraded: response.degraded,
                                hiddenCount: response.hiddenCount
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
            ),
            id: \.id,
            synced: \.synced,
            dirty: \.dirty,
            dismissed: \.dismissed,
            mergeDuplicate: { current, incoming in
                current.mergeDisplayEvidence(from: incoming)
            }
        )
    }

    func start(query: String, includeDismissed: Bool) -> RecallSearchStart {
        core.start(query: query, includeDismissed: includeDismissed)
    }

    func resolve(
        _ search: RecallSearchStart,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async -> RecallSearchSnapshot? {
        await core.resolve(
            search,
            sessionGeneration: sessionGeneration,
            targetIsCurrent: targetIsCurrent
        )
    }

    func setDismissed(
        query: String,
        targetID: String,
        dismissed: Bool,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async throws -> Bool {
        try await core.setDismissed(
            query: query,
            targetID: targetID,
            dismissed: dismissed,
            sessionGeneration: sessionGeneration,
            targetIsCurrent: targetIsCurrent
        )
    }
}
