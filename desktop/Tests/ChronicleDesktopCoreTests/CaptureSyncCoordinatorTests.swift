import Foundation
import Testing

@testable import ChronicleDesktopCore

@Test
func captureSyncCoordinatorDrainsCreatesBeforeDirtyUpdates() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let pending = try store.create(CapturePayload(rawText: "new capture"))
    let edited = try store.create(CapturePayload(rawText: "original"))
    try store.markSynced(
        localId: edited.id,
        serverId: "server-existing",
        syncedAt: Date(timeIntervalSince1970: 1_000),
    )
    try store.setText(
        id: "server-existing",
        rawText: "edited offline",
        now: Date(timeIntervalSince1970: 2_000),
    )
    let transport = StubCaptureSyncTransport()
    let coordinator = CaptureSyncCoordinator(store: store)

    let summary = await coordinator.syncPending(using: transport)

    #expect(summary == CaptureSyncSummary(createsSent: 1, updatesPushed: 1))
    #expect(summary.changed)
    let calls = await transport.calls()
    #expect(calls.creates == ["new capture"])
    #expect(calls.updates == [
        StubCaptureUpdate(serverID: "server-existing", rawText: "edited offline"),
    ])
    #expect(try store.pendingSync().isEmpty)
    #expect(try store.pendingUpdates().isEmpty)
    #expect(try store.find(localId: pending.id)?.serverId == "server-new capture")
}

@Test
func captureSyncCoordinatorReplaysEditThatRacesCreate() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "typo"))
    let transport = StubCaptureSyncTransport { payload in
        try store.setText(
            id: record.id,
            rawText: "fixed",
            now: Date().addingTimeInterval(1),
        )
        return "server-raced"
    }
    let coordinator = CaptureSyncCoordinator(store: store)

    let summary = await coordinator.syncPending(using: transport)

    #expect(summary == CaptureSyncSummary(createsSent: 1, updatesPushed: 1))
    let calls = await transport.calls()
    #expect(calls.creates == ["typo"])
    #expect(calls.updates == [
        StubCaptureUpdate(serverID: "server-raced", rawText: "fixed"),
    ])
    #expect(try store.pendingUpdates().isEmpty)
    #expect(try store.find(localId: record.id)?.payload.rawText == "fixed")
}

@Test
func captureSyncCoordinatorImmediatelyReplaysEditThatRacesSingleCreate() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "typo"))
    let transport = StubCaptureSyncTransport { _ in
        try store.setText(
            id: record.id,
            rawText: "fixed before create completed",
            now: Date().addingTimeInterval(1),
        )
        return "server-single-race"
    }
    let coordinator = CaptureSyncCoordinator(store: store)

    let outcome = await coordinator.sync(record, using: transport)

    #expect(outcome == .synced)
    let calls = await transport.calls()
    #expect(calls.creates == ["typo"])
    #expect(calls.updates == [
        StubCaptureUpdate(
            serverID: "server-single-race",
            rawText: "fixed before create completed"
        ),
    ])
    #expect(try store.pendingUpdates().isEmpty)
}

@Test
func captureSyncCoordinatorLeavesFailedCreatePending() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "retry later"))
    let transport = StubCaptureSyncTransport(failingCreateTexts: ["retry later"])
    let coordinator = CaptureSyncCoordinator(store: store)

    let summary = await coordinator.syncPending(using: transport)

    #expect(summary == CaptureSyncSummary(pendingCreates: 1, status: .failed))
    #expect(!summary.changed)
    let failed = try #require(try store.find(localId: record.id))
    #expect(failed.serverId == nil)
    #expect(failed.lastError != nil)
}

@Test
func captureSyncCoordinatorLeavesFailedUpdateDirty() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "original"))
    try store.markSynced(
        localId: record.id,
        serverId: "server-update-fails",
        syncedAt: Date(timeIntervalSince1970: 1_000),
    )
    try store.setText(
        id: "server-update-fails",
        rawText: "edited offline",
        now: Date(timeIntervalSince1970: 2_000),
    )
    let transport = StubCaptureSyncTransport(
        failingUpdateIDs: ["server-update-fails"],
    )
    let coordinator = CaptureSyncCoordinator(store: store)

    let summary = await coordinator.pushPendingUpdates(using: transport)

    #expect(summary == CaptureSyncSummary(pendingUpdates: 1, status: .failed))
    let dirty = try #require(try store.pendingUpdates().first)
    #expect(dirty.serverId == "server-update-fails")
    #expect(dirty.payload.rawText == "edited offline")
    #expect(dirty.lastError != nil)
}

@Test
func captureSyncCoordinatorReportsAlreadyInFlight() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "only once"))
    let gate = CaptureSyncGate()
    #expect(gate.begin(record.id))
    defer { gate.end(record.id) }
    let coordinator = CaptureSyncCoordinator(store: store, createGate: gate)

    let outcome = await coordinator.sync(record, using: StubCaptureSyncTransport())

    #expect(outcome == .alreadyInFlight)
    #expect(try store.pendingSync().map(\.id) == [record.id])
}

@Test
func captureSyncCoordinatorSerializesAndReplaysRacingUpdates() async throws {
    let store = LocalCaptureStore(fileURL: syncTemporaryDatabaseURL())
    let record = try store.create(CapturePayload(rawText: "original"))
    try store.markSynced(
        localId: record.id,
        serverId: "server-racing-update",
        syncedAt: Date(timeIntervalSince1970: 1_000),
    )
    try store.setText(
        id: record.id,
        rawText: "first edit",
        now: Date(timeIntervalSince1970: 2_000),
    )
    let transport = BlockingUpdateTransport()
    let coordinator = CaptureSyncCoordinator(store: store)

    let firstDrain = Task {
        await coordinator.pushPendingUpdates(using: transport)
    }
    await transport.waitForFirstUpdate()

    try store.setText(
        id: record.id,
        rawText: "second edit",
        now: Date(timeIntervalSince1970: 3_000),
    )
    let coalesced = await coordinator.pushPendingUpdates(using: transport)

    #expect(coalesced.status == .inProgress)
    #expect(coalesced.pendingUpdates == 1)
    await transport.releaseFirstUpdate()

    let completed = await firstDrain.value
    #expect(completed == CaptureSyncSummary(updatesPushed: 2))
    #expect(await transport.updates() == [
        StubCaptureUpdate(serverID: "server-racing-update", rawText: "first edit"),
        StubCaptureUpdate(serverID: "server-racing-update", rawText: "second edit"),
    ])
    #expect(try store.pendingUpdates().isEmpty)
}

@Test
func captureSyncCoordinatorSurfacesStoreReadFailure() async throws {
    let parentFile = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try Data().write(to: parentFile)
    defer { try? FileManager.default.removeItem(at: parentFile) }
    let store = LocalCaptureStore(fileURL: parentFile.appending(path: "sync.sqlite3"))
    let coordinator = CaptureSyncCoordinator(store: store)

    let summary = await coordinator.syncPending(using: StubCaptureSyncTransport())

    #expect(summary == CaptureSyncSummary(status: .failed))
}

private struct StubCaptureUpdate: Equatable, Sendable {
    let serverID: String
    let rawText: String
}

private enum StubCaptureSyncError: Error {
    case failed
}

private actor StubCaptureSyncTransport: CaptureSyncTransport {
    private let failingCreateTexts: Set<String>
    private let failingUpdateIDs: Set<String>
    private let sendHandler: @Sendable (CapturePayload) throws -> String
    private var creates: [String] = []
    private var updates: [StubCaptureUpdate] = []

    init(
        failingCreateTexts: Set<String> = [],
        failingUpdateIDs: Set<String> = [],
        sendHandler: @escaping @Sendable (CapturePayload) throws -> String = {
            "server-\($0.rawText)"
        }
    ) {
        self.failingCreateTexts = failingCreateTexts
        self.failingUpdateIDs = failingUpdateIDs
        self.sendHandler = sendHandler
    }

    func send(_ payload: CapturePayload) async throws -> String {
        creates.append(payload.rawText)
        if failingCreateTexts.contains(payload.rawText) {
            throw StubCaptureSyncError.failed
        }
        return try sendHandler(payload)
    }

    func update(serverId: String, rawText: String) async throws {
        updates.append(StubCaptureUpdate(serverID: serverId, rawText: rawText))
        if failingUpdateIDs.contains(serverId) {
            throw StubCaptureSyncError.failed
        }
    }

    func calls() -> (creates: [String], updates: [StubCaptureUpdate]) {
        (creates, updates)
    }
}

private actor BlockingUpdateTransport: CaptureSyncTransport {
    private var recordedUpdates: [StubCaptureUpdate] = []
    private var firstUpdateStarted: CheckedContinuation<Void, Never>?
    private var firstUpdateRelease: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func send(_ payload: CapturePayload) async throws -> String {
        "unused"
    }

    func update(serverId: String, rawText: String) async throws {
        recordedUpdates.append(StubCaptureUpdate(serverID: serverId, rawText: rawText))
        guard recordedUpdates.count == 1 else { return }

        firstUpdateStarted?.resume()
        firstUpdateStarted = nil
        guard !releaseRequested else { return }
        await withCheckedContinuation { continuation in
            firstUpdateRelease = continuation
        }
    }

    func waitForFirstUpdate() async {
        guard recordedUpdates.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstUpdateStarted = continuation
        }
    }

    func releaseFirstUpdate() {
        releaseRequested = true
        firstUpdateRelease?.resume()
        firstUpdateRelease = nil
    }

    func updates() -> [StubCaptureUpdate] {
        recordedUpdates
    }
}

private func syncTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "capture-sync.sqlite3")
}
