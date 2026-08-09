import ChronicleDesktopCore
import Foundation
import Testing

@testable import ChronicleDesktop

private actor RecordingCaptureShareClient: CaptureShareClient {
    private var listed: [CaptureShare]
    private let created: CaptureShare
    private var createdExpiries: [CaptureShareExpiry] = []
    private var createdSnapshots: [String] = []
    private var revokedIDs: [String] = []

    init(listed: [CaptureShare], created: CaptureShare) {
        self.listed = listed
        self.created = created
    }

    func list(cursor _: String?, limit _: Int, captureID _: String?) async throws -> CaptureSharePage {
        CaptureSharePage(items: listed, nextCursor: nil)
    }

    func create(
        captureID _: String,
        expiresIn: CaptureShareExpiry,
        snapshotRawText: String
    ) async throws -> CaptureShare {
        createdExpiries.append(expiresIn)
        createdSnapshots.append(snapshotRawText)
        listed = [created]
        return created
    }

    func revoke(id: String) async throws {
        revokedIDs.append(id)
        listed.removeAll { $0.id == id }
    }

    func recordedCalls() -> (
        created: [CaptureShareExpiry], snapshots: [String], revoked: [String]
    ) {
        (createdExpiries, createdSnapshots, revokedIDs)
    }
}

private actor DelayedCaptureShareClient: CaptureShareClient {
    private var continuation: CheckedContinuation<CaptureSharePage, Error>?

    func list(cursor _: String?, limit _: Int, captureID _: String?) async throws -> CaptureSharePage {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func create(
        captureID _: String,
        expiresIn _: CaptureShareExpiry,
        snapshotRawText _: String
    ) async throws -> CaptureShare {
        fatalError("not used")
    }

    func revoke(id _: String) async throws {}

    func finish(with page: CaptureSharePage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}

@MainActor
@Suite("Capture sharing")
struct CaptureShareViewModelTests {
    @Test("restores the active share when the sheet reopens")
    func restoresActiveShare() async {
        let active = share(
            id: "active",
            captureID: "capture-1",
            snapshotRawText: "Original shared snapshot"
        )
        let expired = share(
            id: "expired",
            captureID: "capture-1",
            expiresAt: "2020-01-01T00:00:00Z"
        )
        let client = RecordingCaptureShareClient(listed: [expired, active], created: active)
        let model = CaptureShareSheetModel(
            capture: row(id: "capture-1"),
            clients: clients(share: client)
        )

        await model.load()

        #expect(model.activeShare?.id == "active")
        #expect(model.displayedPreviewText == "Original shared snapshot")
        #expect(model.error.isEmpty)
    }

    @Test("creates with the selected expiry and revokes the same link")
    func createsAndRevokes() async {
        let created = share(id: "created", captureID: "capture-1")
        let client = RecordingCaptureShareClient(listed: [], created: created)
        let model = CaptureShareSheetModel(
            capture: row(id: "capture-1"),
            clients: clients(share: client)
        )
        model.expiresIn = .thirtyDays

        await model.create()
        #expect(model.activeShare == created)

        await model.revoke()
        #expect(model.activeShare == nil)
        let calls = await client.recordedCalls()
        #expect(calls.created == [.thirtyDays])
        #expect(calls.snapshots == ["Share this exact text"])
        #expect(calls.revoked == ["created"])
    }

    @Test("session change during a list cannot leave shared copies loading")
    func sharedCopiesSessionChangeDoesNotStickLoading() async {
        let oldClient = DelayedCaptureShareClient()
        let freshShare = share(id: "fresh", captureID: "capture-2")
        let newClient = RecordingCaptureShareClient(
            listed: [freshShare],
            created: freshShare
        )
        let session = CaptureSession()
        var currentClient: any CaptureShareClient = oldClient
        let captureClients = clients(session: session, share: { currentClient })
        let model = SharedCopiesSettingsModel(clients: captureClients)

        let staleLoad = Task { await model.reload() }
        while !model.loading { await Task.yield() }

        session.advance()
        currentClient = newClient
        model.sessionDidChange()
        await model.reload()

        #expect(!model.loading)
        #expect(model.loaded)
        #expect(model.shares.map(\.id) == ["fresh"])

        await oldClient.finish(with: CaptureSharePage(items: [], nextCursor: nil))
        await staleLoad.value
        #expect(!model.loading)
        #expect(model.shares.map(\.id) == ["fresh"])
    }

    @Test("signed-out detail opens sign-in without sharing")
    func signedOutDetailOpensSignIn() async {
        var openedSignIn = false
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            share: { nil },
            openSignIn: { openedSignIn = true },
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in }
        )
        let model = CaptureDetailModel(capture: row(id: "capture-1"), clients: clients)

        let ready = await model.prepareForSharing()

        #expect(!ready)
        #expect(openedSignIn)
    }

    @Test("an unsynced Capture never reaches the share client")
    func unsyncedCaptureIsBlocked() async throws {
        let created = share(id: "unused", captureID: "capture-1")
        let client = RecordingCaptureShareClient(listed: [], created: created)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-share-unsynced-\(UUID().uuidString).sqlite")
        let record = try LocalCaptureStore(fileURL: storeURL, scope: .testing)
            .create(CapturePayload(rawText: "not uploaded yet"))
        let model = CaptureDetailModel(
            capture: RowItem(record),
            clients: clients(share: client)
        )

        let ready = await model.prepareForSharing()

        #expect(!ready)
        #expect(model.error == L("Sync this Capture before sharing."))
        let calls = await client.recordedCalls()
        #expect(calls.created.isEmpty)
        #expect(calls.revoked.isEmpty)
    }

    private func clients(share: any CaptureShareClient) -> CaptureClients {
        clients(session: CaptureSession(), share: { share })
    }

    private func clients(
        session: CaptureSession,
        share: @escaping () -> any CaptureShareClient
    ) -> CaptureClients {
        CaptureClients(
            session: session,
            recall: { nil },
            webhook: { nil },
            share: share,
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in }
        )
    }

    private func row(id: String) -> RowItem {
        RowItem(Capture(
            id: id,
            rawText: "Share this exact text",
            transcript: nil,
            mediaType: "text",
            mediaUrl: nil,
            source: "desktop",
            remindAt: nil,
            createdAt: "2026-08-09T10:00:00Z"
        ))
    }

    private func share(
        id: String,
        captureID: String,
        snapshotRawText: String = "Share this exact text",
        expiresAt: String? = "2099-08-16T10:00:00Z"
    ) -> CaptureShare {
        CaptureShare(
            id: id,
            captureId: captureID,
            snapshotRawText: snapshotRawText,
            capturedAt: "2026-08-09T10:00:00Z",
            expiresAt: expiresAt,
            createdAt: "2026-08-09T11:00:00Z",
            secret: "secret-\(id)",
            url: "https://chronicle.example/s/\(id)#secret-\(id)"
        )
    }
}
