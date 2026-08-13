import Foundation
import Testing
@testable import ChronicleDesktopCore

@Suite("Markdown tasks")
struct MarkdownTaskTests {
    @Test("parses open, checked, ordered, and quoted tasks")
    func parsesTaskForms() {
        let markdown = """
        - [ ] open task
        - [x] checked task ✅ 2026-08-12
        1. [X] ordered task ✅ 2026-08-11
        > - [ ] quoted task
        """

        let tasks = MarkdownTaskDocument.tasks(in: markdown)

        #expect(tasks.map(\.lineIndex) == [0, 1, 2, 3])
        #expect(tasks.map(\.text) == ["open task", "checked task", "ordered task", "quoted task"])
        #expect(tasks.map(\.isCompleted) == [false, true, true, false])
        #expect(tasks.map(\.completedOn) == [nil, "2026-08-12", "2026-08-11", nil])
    }

    @Test("ignores fenced and standalone indented code samples")
    func ignoresCodeBlocks() {
        let markdown = """
        ```md
        - [ ] fenced sample
        ```

            - [ ] indented sample
          - [ ] two-space nested task
        """

        let tasks = MarkdownTaskDocument.tasks(in: markdown)

        #expect(tasks.count == 1)
        #expect(tasks.first?.lineIndex == 5)
        #expect(tasks.first?.text == "two-space nested task")
    }

    @Test("an opening-looking fence line cannot close an active code fence")
    func requiresWhitespaceAfterClosingFence() {
        let markdown = """
        ```md
        ```swift
        - [ ] still a code sample
        ```
        - [ ] real task
        """

        let tasks = MarkdownTaskDocument.tasks(in: markdown)

        #expect(tasks.map(\.lineIndex) == [4])
        #expect(tasks.map(\.text) == ["real task"])
    }

    @Test("a blockquote fence cannot swallow tasks after the quote ends")
    func scopesFencesToBlockquoteDepth() {
        let markdown = """
        > ```md
        > - [ ] quoted code sample
        - [ ] outside task
        """

        let tasks = MarkdownTaskDocument.tasks(in: markdown)

        #expect(tasks.map(\.lineIndex) == [2])
        #expect(tasks.map(\.text) == ["outside task"])
    }

    @Test("does not manufacture a task by removing a leading todo facet")
    func todoFacetBeforeMarkerIsNotATask() {
        #expect(MarkdownTaskDocument.tasks(in: "#todo - [ ] plain text").isEmpty)
        #expect(MarkdownTaskDocument.tasks(in: "- [ ] real task #todo").count == 1)
    }

    @Test("checking, changing the date, and unchecking preserve surrounding source")
    func rewritesOnlyTheSelectedLine() {
        let original = "Intro\r\n> - [ ] **ship it**  \r\nOutro"

        let checked = MarkdownTaskDocument.settingCompletion(
            in: original,
            lineIndex: 1,
            completedOn: "2026-08-13"
        )
        #expect(checked == "Intro\r\n> - [x] **ship it**   ✅ 2026-08-13\r\nOutro")

        let dated = MarkdownTaskDocument.settingCompletion(
            in: checked,
            lineIndex: 1,
            completedOn: "2026-08-12"
        )
        #expect(dated == "Intro\r\n> - [x] **ship it** ✅ 2026-08-12\r\nOutro")

        let unchecked = MarkdownTaskDocument.settingCompletion(
            in: dated,
            lineIndex: 1,
            completedOn: nil
        )
        #expect(unchecked == "Intro\r\n> - [ ] **ship it**\r\nOutro")
    }

    @Test("rebases a task change onto current text without overwriting sibling edits")
    func rebasesOnlyWhenTheSelectedTaskStillMatches() {
        let displayed = "- [ ] Task A\n- [ ] Task B"
        let current = "- [x] Task A ✅ 2026-08-12\n- [ ] Task B"

        let rebased = MarkdownTaskDocument.settingCompletion(
            in: current,
            matchingTaskIn: displayed,
            lineIndex: 1,
            completedOn: "2026-08-13"
        )
        #expect(rebased == "- [x] Task A ✅ 2026-08-12\n- [x] Task B ✅ 2026-08-13")

        let changedTarget = "- [x] Task A ✅ 2026-08-12\n- [ ] Renamed task"
        #expect(MarkdownTaskDocument.settingCompletion(
            in: changedTarget,
            matchingTaskIn: displayed,
            lineIndex: 1,
            completedOn: "2026-08-13"
        ) == nil)
    }

    @Test("invalid completion dates remain visible and cannot be written")
    func validatesCalendarDates() {
        let markdown = "- [x] legacy ✅ 2026-02-30"
        let task = MarkdownTaskDocument.tasks(in: markdown).first

        #expect(task?.text == "legacy ✅ 2026-02-30")
        #expect(task?.completedOn == nil)
        #expect(MarkdownTaskDocument.settingCompletion(
            in: markdown,
            lineIndex: 0,
            completedOn: "2026-02-30"
        ) == markdown)
    }

    @Test("local date formatting follows the supplied calendar")
    func formatsLocalDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-08-12T15:30:00Z"))

        #expect(MarkdownTaskDocument.localDateString(date, calendar: calendar) == "2026-08-13")
        #expect(MarkdownTaskDocument.date(fromCalendarDate: "2026-08-13", calendar: calendar) != nil)
    }
}
