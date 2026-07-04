import Foundation
import Testing

@testable import ChronicleDesktopCore

private struct Row: Equatable {
    let id: String
    let source: String
    let date: Date?
}

private func row(_ id: String, _ source: String, minutesAgo: Int? = nil) -> Row {
    Row(
        id: id,
        source: source,
        date: minutesAgo.map { Date(timeIntervalSinceReferenceDate: 100_000 - Double($0 * 60)) },
    )
}

@Suite struct RowMergeTests {
    @Test func dedupsKeepingThePrimarySource() {
        let merged = RowMerge.newestFirst(
            primary: [row("a", "remote", minutesAgo: 1)],
            secondary: [row("a", "local", minutesAgo: 1), row("b", "local", minutesAgo: 2)],
            id: \.id,
            date: \.date,
        )
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged[0].source == "remote")
    }

    @Test func ordersNewestFirstAcrossSources() {
        let merged = RowMerge.newestFirst(
            primary: [row("old", "remote", minutesAgo: 60), row("new", "remote", minutesAgo: 1)],
            secondary: [row("mid", "local", minutesAgo: 30)],
            id: \.id,
            date: \.date,
        )
        #expect(merged.map(\.id) == ["new", "mid", "old"])
    }

    @Test func undatedRowsSinkToTheEnd() {
        let merged = RowMerge.newestFirst(
            primary: [row("undated", "remote")],
            secondary: [row("dated", "local", minutesAgo: 90)],
            id: \.id,
            date: \.date,
        )
        #expect(merged.map(\.id) == ["dated", "undated"])
    }

    @Test func emptySourcesYieldEmpty() {
        let merged = RowMerge.newestFirst(
            primary: [Row](),
            secondary: [],
            id: \.id,
            date: \.date,
        )
        #expect(merged.isEmpty)
    }
}
