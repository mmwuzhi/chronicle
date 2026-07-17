import Foundation
import Testing
@testable import ChronicleDesktopCore

@Suite("Todo tag")
struct TodoTagTests {
    private struct Fixture: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let desc: String
        let text: String
        let present: Bool
        let done: Bool
    }

    @Test func parsesOpenAndDoneForms() {
        #expect(CaptureTodoTag.state(in: "buy milk #todo") == .open)
        #expect(CaptureTodoTag.state(in: "#todo(done) buy milk") == .done)
        #expect(
            CaptureTodoTag.state(in: "#todo(done:2026-07-16) buy milk")
                == .done
        )
        #expect(CaptureTodoTag.state(in: "#todoodle") == nil)
    }

    @Test func stripsOnlyTheFirstAuthoritativeTagForDisplay() {
        #expect(
            CaptureTodoTag.displayText(from: "#todo write release notes")
                == "write release notes"
        )
        #expect(
            CaptureTodoTag.displayText(from: "write #todo(done) notes")
                == "write notes"
        )
    }

    @Test func completesTrailingSuggestion() {
        #expect(CaptureTodoTag.offersSuggestion(for: "remember #to"))
        #expect(
            CaptureTodoTag.completingSuggestion(in: "remember #to")
                == "remember #todo "
        )
        #expect(!CaptureTodoTag.offersSuggestion(for: "remember #todo"))
    }

    @Test func matchesTheSharedGoAndWebGrammarFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../shared/fixtures/todo-tag.json")
            .standardizedFileURL
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(!fixture.cases.isEmpty)
        for testCase in fixture.cases {
            let state = CaptureTodoTag.state(in: testCase.text)
            #expect(
                (state != nil) == testCase.present,
                Comment(rawValue: testCase.desc)
            )
            #expect(
                (state == .done) == testCase.done,
                Comment(rawValue: testCase.desc)
            )
        }
    }
}
