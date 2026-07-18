import Foundation
import Testing
@testable import ChronicleDesktop
import ChronicleDesktopCore

@MainActor
@Suite("Capture row text ownership")
struct CaptureRowModelTests {
    @Test("full capture displays transcript but edits only raw text")
    func fullCaptureKeepsDisplayAndEditableTextSeparate() throws {
        let capture = Capture(
            id: "11111111-1111-1111-1111-111111111111",
            rawText: "Customer meeting",
            transcript: "Send the second quote next Wednesday",
            mediaType: "audio",
            mediaUrl: nil,
            source: "web",
            remindAt: nil,
            createdAt: "2026-07-16T09:00:00Z"
        )

        let row = RowItem(capture)
        let draft = try #require(CaptureEditDraft(item: row))

        #expect(row.content == "Send the second quote next Wednesday")
        #expect(row.editableRawText == "Customer meeting")
        #expect(draft.text == "Customer meeting")
        #expect(draft.originalText == "Customer meeting")
    }

    @Test("transcript-only Capture does not create a blank edit draft")
    func transcriptOnlyCaptureIsNotBlankEditableText() {
        let capture = Capture(
            id: "transcript-only",
            rawText: nil,
            transcript: "Recorded meeting transcript",
            mediaType: "audio",
            mediaUrl: nil,
            source: "desktop",
            remindAt: nil,
            createdAt: "2026-07-16T09:00:00Z"
        )

        let row = RowItem(capture)

        #expect(row.displayText == "Recorded meeting transcript")
        #expect(row.editableRawText == nil)
        #expect(CaptureEditDraft(item: row) == nil)
    }

    @Test("search projection cannot become an edit draft")
    func searchProjectionRequiresFullCapture() {
        let hit = RecallItem(
            id: "22222222-2222-2222-2222-222222222222",
            content: "URL plus fetched page text",
            snippet: "fetched page evidence",
            createdAt: "2026-07-16T09:00:00Z",
            modality: "text",
            score: 0.9,
            lexical: false
        )

        let row = RowItem(hit)

        #expect(row.editableRawText == nil)
        #expect(row.content == "URL plus fetched page text")
        #expect(row.displayText == "fetched page evidence")
        #expect(CaptureEditDraft(item: row) == nil)
    }

    @Test("external edit can hydrate a projection before editing")
    func externalEditDoesNotRequireInlineRawText() {
        let row = RowItem(RecallItem(
            id: "search-result",
            content: "Result projection",
            snippet: nil,
            createdAt: "2026-07-19T00:00:00Z",
            modality: "text",
            score: 0.8,
            lexical: true
        ))

        #expect(captureRowCanBeginEditing(
            row,
            hasInlineEdit: false,
            hasExternalBegin: true
        ))
        #expect(!captureRowCanBeginEditing(
            row,
            hasInlineEdit: true,
            hasExternalBegin: false
        ))
    }

    @Test("server evidence enriches a local row without replacing editable text")
    func localRowsKeepEditOwnershipWhenEvidenceArrives() {
        let capture = Capture(
            id: "33333333-3333-3333-3333-333333333333",
            rawText: "Research link",
            transcript: nil,
            mediaType: "text",
            mediaUrl: nil,
            source: "desktop",
            remindAt: nil,
            createdAt: "2026-07-16T09:00:00Z"
        )
        let hit = RecallItem(
            id: capture.id,
            content: "Research link fetched page body",
            snippet: "matching evidence from the fetched page",
            createdAt: capture.createdAt,
            modality: "text",
            score: 0.8,
            lexical: false
        )

        var row = RowItem(capture)
        row.mergeDisplayEvidence(from: RowItem(hit))

        #expect(row.displayText == "matching evidence from the fetched page")
        #expect(row.editableRawText == "Research link")
    }

    @Test("detail editor saves a local Capture in place")
    func detailEditorSavesLocalCapture() throws {
        var saved: (String, String)?
        let clients = CaptureClients(
            recall: { nil },
            webhook: { nil },
            openSignIn: {},
            localSearch: { _ in [] },
            localRecent: { _ in [] },
            localDelete: { _ in },
            localSetText: { id, text in
                saved = (id, text)
                return true
            }
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-detail-edit-\(UUID().uuidString).sqlite")
        let record = try LocalCaptureStore(fileURL: storeURL)
            .create(CapturePayload(rawText: "Before"))
        let row = RowItem(record)
        let model = CaptureDetailModel(capture: row, clients: clients)

        model.beginEditing()
        model.updateEditDraft("After")
        model.commitEditing()

        #expect(saved?.0 == row.id)
        #expect(saved?.1 == "After")
        #expect(model.capture.editableRawText == "After")
        #expect(model.capture.displayText == "After")
        #expect(model.editDraft == nil)
    }
}
