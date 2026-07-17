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
}
