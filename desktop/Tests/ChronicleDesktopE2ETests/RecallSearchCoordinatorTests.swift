import Foundation
import Testing

@testable import ChronicleDesktop
@testable import ChronicleDesktopCore

private enum RecallSearchTestError: Error {
    case unavailable
}

private actor RecallSearchGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func recallItem(
    _ id: String,
    content: String? = nil,
    snippet: String? = nil,
    dismissed: Bool? = nil
) -> RecallItem {
    RecallItem(
        id: id,
        content: content ?? id,
        snippet: snippet,
        createdAt: "2026-08-16T00:00:00Z",
        modality: "text",
        score: 1,
        lexical: true,
        dismissed: dismissed
    )
}

private func recallRow(
    _ id: String,
    content: String? = nil,
    snippet: String? = nil,
    dismissed: Bool? = nil
) -> RowItem {
    RowItem(recallItem(
        id,
        content: content,
        snippet: snippet,
        dismissed: dismissed
    ))
}

@MainActor
@Suite("Layered recall search")
struct RecallSearchCoordinatorTests {
    @Test("offline search merges literal and semantic rows while honoring dismissals")
    func offlineFallback() async throws {
        let session = CaptureSession()
        let coordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [
                recallRow("literal"),
                recallRow("shared", content: "editable local text"),
                recallRow("hidden"),
            ] },
            cachedDismissedIDs: { _ in ["hidden"] },
            localSemanticSearch: { _ in [
                recallRow("shared", snippet: "semantic evidence"),
                recallRow("semantic"),
                recallRow("hidden"),
            ] },
            remote: { nil }
        ))

        let search = coordinator.start(query: "ramen", includeDismissed: false)
        #expect(search.initial.hits.map(\.id) == ["literal", "shared"])

        let resolved = try #require(await coordinator.resolve(
            search,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(resolved.hits.map(\.id) == ["literal", "shared", "semantic"])
        #expect(resolved.hits[1].content == "editable local text")
        #expect(resolved.hits[1].snippet == "semantic evidence")
        #expect(resolved.hiddenCount == 1)
        #expect(!resolved.degraded)

        let expanded = coordinator.start(query: "ramen", includeDismissed: true)
        let expandedResolved = try #require(await coordinator.resolve(
            expanded,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(expandedResolved.hits.map(\.id) == [
            "literal", "shared", "hidden", "semantic",
        ])
    }

    @Test("online search preserves local edits and layers server ranking before semantic supplements")
    func onlineLayering() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-recall-search-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = LocalCaptureStore(fileURL: storeURL, scope: .testing)

        let unsynced = try store.create(CapturePayload(rawText: "unsynced literal"))
        let dirty = try store.create(CapturePayload(rawText: "old dirty text"))
        try store.markSynced(localId: dirty.id, serverId: "dirty")
        try store.setText(id: "dirty", rawText: "new local edit")
        let clean = try store.create(CapturePayload(rawText: "clean cache"))
        try store.markSynced(localId: clean.id, serverId: "clean")
        let semantic = try store.create(CapturePayload(rawText: "semantic local"))

        let unsyncedRecord = try #require(try store.find(localId: unsynced.id))
        let dirtyRecord = try #require(try store.find(serverId: "dirty"))
        let cleanRecord = try #require(try store.find(serverId: "clean"))
        let semanticRecord = try #require(try store.find(localId: semantic.id))
        let localLiteral = [
            RowItem(unsyncedRecord),
            RowItem(dirtyRecord),
            RowItem(cleanRecord),
        ]
        let localSemantic = [RowItem(semanticRecord)]
        let response = FindResponse(
            items: [
                recallItem("dirty", content: "stale remote", snippet: "server evidence"),
                recallItem("clean", content: "server clean"),
                recallItem("ranked"),
                recallItem("hidden", dismissed: true),
            ],
            degraded: true,
            hiddenCount: 1,
            dismissalsAuthoritative: true
        )
        let session = CaptureSession()
        let coordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in localLiteral },
            cachedDismissedIDs: { _ in ["cached-hidden"] },
            localSemanticSearch: { _ in localSemantic },
            remote: {
                RecallSearchRemote(
                    find: { _, includeDismissed in
                        #expect(includeDismissed)
                        return response
                    },
                    setDismissed: { _, _, _ in }
                )
            }
        ))

        let search = coordinator.start(query: "layered", includeDismissed: false)
        #expect(search.initial.hits.map(\.id) == [unsynced.id, "dirty"])

        let resolved = try #require(await coordinator.resolve(
            search,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(resolved.hits.map(\.id) == [
            unsynced.id, "dirty", "clean", "ranked", semantic.id,
        ])
        #expect(resolved.hits[1].content == "new local edit")
        #expect(resolved.hits[1].snippet == "server evidence")
        #expect(resolved.hiddenCount == 2)
        #expect(resolved.degraded)
    }

    @Test("remote failure retains complete local fallback")
    func remoteFailure() async throws {
        let session = CaptureSession()
        let coordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [recallRow("literal"), recallRow("hidden")] },
            cachedDismissedIDs: { _ in ["hidden"] },
            localSemanticSearch: { _ in [recallRow("semantic")] },
            remote: {
                RecallSearchRemote(
                    find: { _, _ in throw RecallSearchTestError.unavailable },
                    setDismissed: { _, _, _ in }
                )
            }
        ))
        let search = coordinator.start(query: "offline", includeDismissed: false)

        let resolved = try #require(await coordinator.resolve(
            search,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(resolved.hits.map(\.id) == ["literal", "semantic"])
        #expect(resolved.hiddenCount == 1)
        #expect(!resolved.degraded)
    }

    @Test("session changes and cancellation discard stale search results")
    func staleSearches() async {
        let session = CaptureSession()
        let sessionGate = RecallSearchGate()
        let coordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in
                await sessionGate.wait()
                return [recallRow("stale")]
            },
            remote: { nil }
        ))
        let search = coordinator.start(query: "old", includeDismissed: false)
        let generation = session.snapshot()
        let staleTask = Task { @MainActor in
            await coordinator.resolve(
                search,
                sessionGeneration: generation,
                targetIsCurrent: { true }
            )
        }
        while !(await sessionGate.isWaiting()) { await Task.yield() }
        session.advance()
        await sessionGate.open()
        #expect(await staleTask.value == nil)

        let changedQueryCoordinator = RecallSearchCoordinator(
            dependencies: RecallSearchDependencies(
                sessionIsCurrent: { _ in true },
                localSearch: { _ in [] },
                cachedDismissedIDs: { _ in [] },
                localSemanticSearch: { _ in [recallRow("old-query")] },
                remote: { nil }
            )
        )
        let changedQuerySearch = changedQueryCoordinator.start(
            query: "old",
            includeDismissed: false
        )
        #expect(await changedQueryCoordinator.resolve(
            changedQuerySearch,
            sessionGeneration: 0,
            targetIsCurrent: { false }
        ) == nil)

        let cancelGate = RecallSearchGate()
        let cancelCoordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: { _ in true },
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in
                await cancelGate.wait()
                return [recallRow("cancelled")]
            },
            remote: { nil }
        ))
        let cancelSearch = cancelCoordinator.start(query: "cancel", includeDismissed: false)
        let cancelledTask = Task { @MainActor in
            await cancelCoordinator.resolve(
                cancelSearch,
                sessionGeneration: 0,
                targetIsCurrent: { true }
            )
        }
        while !(await cancelGate.isWaiting()) { await Task.yield() }
        cancelledTask.cancel()
        await cancelGate.open()
        #expect(await cancelledTask.value == nil)
    }

    @Test("dismissal mutations are scoped to the current query and session")
    func dismissalMutation() async throws {
        let session = CaptureSession()
        var call: (String, String, Bool)?
        let coordinator = RecallSearchCoordinator(dependencies: RecallSearchDependencies(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in [] },
            remote: {
                RecallSearchRemote(
                    find: { _, _ in FindResponse(items: [], degraded: false) },
                    setDismissed: { query, targetID, dismissed in
                        call = (query, targetID, dismissed)
                    }
                )
            }
        ))
        let generation = session.snapshot()
        let applied = try await coordinator.setDismissed(
            query: "ramen",
            targetID: "capture-1",
            dismissed: true,
            sessionGeneration: generation,
            targetIsCurrent: { true }
        )
        #expect(applied)
        #expect(call?.0 == "ramen")
        #expect(call?.1 == "capture-1")
        #expect(call?.2 == true)

        session.advance()
        let stale = try await coordinator.setDismissed(
            query: "ramen",
            targetID: "capture-1",
            dismissed: false,
            sessionGeneration: generation,
            targetIsCurrent: { true }
        )
        #expect(!stale)
        #expect(call?.2 == true)
    }
}
