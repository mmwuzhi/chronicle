import Testing

@testable import ChronicleDesktopCore

private enum LayeredRecallTestError: Error {
    case unavailable
}

private struct RecallTestRow: Equatable, Sendable {
    let id: String
    var content: String
    var snippet: String?
    let synced: Bool
    let dirty: Bool
    var dismissed: Bool
}

private func row(
    _ id: String,
    content: String? = nil,
    snippet: String? = nil,
    synced: Bool = true,
    dirty: Bool = false,
    dismissed: Bool = false
) -> RecallTestRow {
    RecallTestRow(
        id: id,
        content: content ?? id,
        snippet: snippet,
        synced: synced,
        dirty: dirty,
        dismissed: dismissed
    )
}

@MainActor
private final class RecallTestSession {
    private var generation: UInt64 = 0

    func snapshot() -> UInt64 { generation }
    func isCurrent(_ snapshot: UInt64) -> Bool { generation == snapshot }
    func advance() { generation &+= 1 }
}

private actor RecallTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func isWaiting() -> Bool { continuation != nil }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func coordinator(
    sessionIsCurrent: @escaping (UInt64) -> Bool,
    localSearch: @escaping (String) -> [RecallTestRow],
    cachedDismissedIDs: @escaping (String) -> Set<String>,
    localSemanticSearch: @escaping (String) async -> [RecallTestRow],
    remote: @escaping () -> LayeredRecallRemote<RecallTestRow>?
) -> LayeredRecallCoordinator<RecallTestRow> {
    LayeredRecallCoordinator(
        dependencies: LayeredRecallDependencies(
            sessionIsCurrent: sessionIsCurrent,
            localSearch: localSearch,
            cachedDismissedIDs: cachedDismissedIDs,
            localSemanticSearch: localSemanticSearch,
            remote: remote
        ),
        id: \.id,
        synced: \.synced,
        dirty: \.dirty,
        dismissed: \.dismissed,
        mergeDuplicate: { current, incoming in
            guard current.snippet?.isEmpty != false,
                  let evidence = incoming.snippet,
                  !evidence.isEmpty
            else { return }
            current.snippet = evidence
        }
    )
}

@MainActor
@Suite("Layered recall search")
struct LayeredRecallSearchTests {
    @Test("offline search merges literal and semantic rows while honoring dismissals")
    func offlineFallback() async throws {
        let session = RecallTestSession()
        let searchCoordinator = coordinator(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [
                row("literal"),
                row("shared", content: "editable local text"),
                row("hidden"),
            ] },
            cachedDismissedIDs: { _ in ["hidden"] },
            localSemanticSearch: { _ in [
                row("shared", snippet: "semantic evidence"),
                row("semantic"),
                row("hidden"),
            ] },
            remote: { nil }
        )

        let search = searchCoordinator.start(query: "ramen", includeDismissed: false)
        #expect(search.initial.hits.map(\.id) == ["literal", "shared"])

        let resolved = try #require(await searchCoordinator.resolve(
            search,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(resolved.hits.map(\.id) == ["literal", "shared", "semantic"])
        #expect(resolved.hits[1].content == "editable local text")
        #expect(resolved.hits[1].snippet == "semantic evidence")
        #expect(resolved.hiddenCount == 1)
        #expect(!resolved.degraded)

        let expanded = searchCoordinator.start(query: "ramen", includeDismissed: true)
        let expandedResolved = try #require(await searchCoordinator.resolve(
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
        let localLiteral = [
            row("unsynced", synced: false),
            row("dirty", content: "new local edit", dirty: true),
            row("clean"),
        ]
        let localSemantic = [row("semantic", synced: false)]
        let session = RecallTestSession()
        let searchCoordinator = coordinator(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in localLiteral },
            cachedDismissedIDs: { _ in ["cached-hidden"] },
            localSemanticSearch: { _ in localSemantic },
            remote: {
                LayeredRecallRemote(
                    find: { _, includeDismissed in
                        #expect(includeDismissed)
                        return LayeredRecallRemoteResponse(
                            rows: [
                                row("dirty", content: "stale remote", snippet: "server evidence"),
                                row("clean", content: "server clean"),
                                row("ranked"),
                                row("hidden", dismissed: true),
                            ],
                            degraded: true,
                            hiddenCount: 1
                        )
                    },
                    setDismissed: { _, _, _ in }
                )
            }
        )

        let search = searchCoordinator.start(query: "layered", includeDismissed: false)
        #expect(search.initial.hits.map(\.id) == ["unsynced", "dirty"])

        let resolved = try #require(await searchCoordinator.resolve(
            search,
            sessionGeneration: session.snapshot(),
            targetIsCurrent: { true }
        ))
        #expect(resolved.hits.map(\.id) == [
            "unsynced", "dirty", "clean", "ranked", "semantic",
        ])
        #expect(resolved.hits[1].content == "new local edit")
        #expect(resolved.hits[1].snippet == "server evidence")
        #expect(resolved.hiddenCount == 2)
        #expect(resolved.degraded)
    }

    @Test("remote failure retains complete local fallback")
    func remoteFailure() async throws {
        let session = RecallTestSession()
        let searchCoordinator = coordinator(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [row("literal"), row("hidden")] },
            cachedDismissedIDs: { _ in ["hidden"] },
            localSemanticSearch: { _ in [row("semantic")] },
            remote: {
                LayeredRecallRemote(
                    find: { _, _ in throw LayeredRecallTestError.unavailable },
                    setDismissed: { _, _, _ in }
                )
            }
        )
        let search = searchCoordinator.start(query: "offline", includeDismissed: false)

        let resolved = try #require(await searchCoordinator.resolve(
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
        let session = RecallTestSession()
        let sessionGate = RecallTestGate()
        let searchCoordinator = coordinator(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in
                await sessionGate.wait()
                return [row("stale")]
            },
            remote: { nil }
        )
        let search = searchCoordinator.start(query: "old", includeDismissed: false)
        let generation = session.snapshot()
        let staleTask = Task { @MainActor in
            await searchCoordinator.resolve(
                search,
                sessionGeneration: generation,
                targetIsCurrent: { true }
            )
        }
        while !(await sessionGate.isWaiting()) { await Task.yield() }
        session.advance()
        await sessionGate.open()
        #expect(await staleTask.value == nil)

        let changedQueryCoordinator = coordinator(
            sessionIsCurrent: { _ in true },
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in [row("old-query")] },
            remote: { nil }
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

        let cancelGate = RecallTestGate()
        let cancelCoordinator = coordinator(
            sessionIsCurrent: { _ in true },
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in
                await cancelGate.wait()
                return [row("cancelled")]
            },
            remote: { nil }
        )
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
        let session = RecallTestSession()
        var call: (String, String, Bool)?
        let searchCoordinator = coordinator(
            sessionIsCurrent: session.isCurrent,
            localSearch: { _ in [] },
            cachedDismissedIDs: { _ in [] },
            localSemanticSearch: { _ in [] },
            remote: {
                LayeredRecallRemote(
                    find: { _, _ in LayeredRecallRemoteResponse(
                        rows: [],
                        degraded: false,
                        hiddenCount: nil
                    ) },
                    setDismissed: { query, targetID, dismissed in
                        call = (query, targetID, dismissed)
                    }
                )
            }
        )
        let generation = session.snapshot()
        let applied = try await searchCoordinator.setDismissed(
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
        let stale = try await searchCoordinator.setDismissed(
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
