import Foundation

/// One GitHub-flavored Markdown task marker backed by its source line.
///
/// Completion is stored in the Capture text as a trailing `✅ YYYY-MM-DD` token.
/// The UI hides that token and exposes it through a native date control instead.
public struct MarkdownTask: Equatable, Identifiable, Sendable {
    public let lineIndex: Int
    public let text: String
    public let isCompleted: Bool
    public let completedOn: String?

    public var id: Int { lineIndex }
}

public enum MarkdownTaskBlock: Equatable, Identifiable, Sendable {
    case text(lineIndex: Int, text: String)
    case task(MarkdownTask)

    public var id: Int {
        switch self {
        case .text(let lineIndex, _): lineIndex
        case .task(let task): task.lineIndex
        }
    }
}

/// Platform-free parsing and source-preserving writes for Markdown task lists.
public enum MarkdownTaskDocument {
    private struct ParsedTask {
        let task: MarkdownTask
        let prefix: String
        let closingBracket: String
        let contentWithoutCompletion: String
        let trailingWhitespace: String
    }

    private struct Fence {
        let character: Character
        let length: Int
    }

    private struct FenceMarker {
        let fence: Fence
        let canClose: Bool
    }

    private static let taskPattern = try! NSRegularExpression(
        pattern: #"^([\t ]*(?:(?:[-+*])|(?:\d+[.)]))[\t ]+\[)([ xX])(\])(?=[\t ]|$)(.*)$"#
    )
    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([\t ]*)((?:[-+*])|(?:\d+[.)]))[\t ]+(.*)$"#
    )
    private static let completionPattern = try! NSRegularExpression(
        pattern: #"[\t ]+✅[\t ]*(\d{4}-\d{2}-\d{2})([\t ]*)$"#
    )
    private static let fencePattern = try! NSRegularExpression(
        pattern: #"^[\t ]{0,3}(`{3,}|~{3,})(.*)$"#
    )

    public static func tasks(in markdown: String) -> [MarkdownTask] {
        parsedLines(in: markdown).compactMap(\.task)
    }

    public static func blocks(in markdown: String) -> [MarkdownTaskBlock] {
        let parsed = parsedLines(in: markdown)
        var blocks: [MarkdownTaskBlock] = []
        var textStart: Int?
        var textLines: [String] = []

        func flushText() {
            guard let start = textStart else { return }
            blocks.append(.text(lineIndex: start, text: textLines.joined(separator: "\n")))
            textStart = nil
            textLines = []
        }

        for line in parsed {
            if let task = line.task {
                flushText()
                blocks.append(.task(task))
            } else {
                if textStart == nil { textStart = line.index }
                textLines.append(line.raw)
            }
        }
        flushText()
        return blocks
    }

    /// Rewrites only the selected task line. Passing nil marks it incomplete and
    /// removes any valid completion suffix; a date marks it complete.
    public static func settingCompletion(
        in markdown: String,
        lineIndex: Int,
        completedOn: String?
    ) -> String {
        guard lineIndex >= 0 else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return markdown }

        let hasCarriageReturn = lines[lineIndex].hasSuffix("\r")
        let source = hasCarriageReturn ? String(lines[lineIndex].dropLast()) : lines[lineIndex]
        guard let parsed = parsedTask(on: source, lineIndex: lineIndex),
              completedOn.map(isCalendarDate) ?? true
        else { return markdown }

        let suffix = completedOn.map { " ✅ \($0)" } ?? ""
        lines[lineIndex] = parsed.prefix
            + (completedOn == nil ? " " : "x")
            + parsed.closingBracket
            + parsed.contentWithoutCompletion
            + suffix
            + parsed.trailingWhitespace
            + (hasCarriageReturn ? "\r" : "")
        return lines.joined(separator: "\n")
    }

    /// Applies a task action to the latest document only when the selected task
    /// still occupies the same source line with the same visible state. Changes
    /// elsewhere in the document are preserved; a changed or moved target returns
    /// nil so callers can refresh instead of editing the wrong line.
    public static func settingCompletion(
        in currentMarkdown: String,
        matchingTaskIn displayedMarkdown: String,
        lineIndex: Int,
        completedOn: String?
    ) -> String? {
        guard let displayed = task(at: lineIndex, in: displayedMarkdown),
              let current = task(at: lineIndex, in: currentMarkdown),
              displayed == current
        else { return nil }
        return settingCompletion(
            in: currentMarkdown,
            lineIndex: lineIndex,
            completedOn: completedOn
        )
    }

    public static func localDateString(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func date(fromCalendarDate value: String, calendar: Calendar = .current) -> Date? {
        guard isCalendarDate(value) else { return nil }
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = 12
        return calendar.date(from: components)
    }

    private struct ParsedLine {
        let index: Int
        let raw: String
        let task: MarkdownTask?
    }

    private static func parsedLines(in markdown: String) -> [ParsedLine] {
        let rawLines = markdown.components(separatedBy: "\n")
        var fence: Fence?
        var quoteDepth = 0
        var result: [ParsedLine] = []

        for (index, rawLine) in rawLines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let quoted = strippingBlockquotePrefix(from: line)
            if quoted.depth != quoteDepth {
                fence = nil
                quoteDepth = quoted.depth
            }

            if let marker = fenceMarker(in: quoted.content) {
                if let active = fence {
                    if marker.canClose,
                       marker.fence.character == active.character,
                       marker.fence.length >= active.length
                    {
                        fence = nil
                    }
                } else {
                    fence = marker.fence
                }
                result.append(ParsedLine(index: index, raw: line, task: nil))
                continue
            }
            guard fence == nil else {
                result.append(ParsedLine(index: index, raw: line, task: nil))
                continue
            }

            let list = listItem(in: quoted.content)
            if let list {
                let task = list.indent >= 4 ? nil : parsedTask(
                    on: quoted.content,
                    lineIndex: index
                )?.task
                result.append(ParsedLine(index: index, raw: line, task: task))
                continue
            }
            result.append(ParsedLine(index: index, raw: line, task: nil))
        }
        return result
    }

    private static func parsedTask(on line: String, lineIndex: Int) -> ParsedTask? {
        let quoted = strippingBlockquotePrefix(from: line)
        let ns = quoted.content as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = taskPattern.firstMatch(in: quoted.content, range: full) else { return nil }
        let prefix = quoted.prefix + ns.substring(with: match.range(at: 1))
        let checked = ns.substring(with: match.range(at: 2)) != " "
        let closing = ns.substring(with: match.range(at: 3))
        let content = ns.substring(with: match.range(at: 4))
        let completion = validCompletion(in: content)
        let visible: String
        let trailingWhitespace: String
        if let completion {
            visible = (content as NSString).substring(to: completion.fullRange.location)
            trailingWhitespace = completion.trailingWhitespace
        } else {
            (visible, trailingWhitespace) = splittingTrailingWhitespace(in: content)
        }
        return ParsedTask(
            task: MarkdownTask(
                lineIndex: lineIndex,
                text: visible.trimmingCharacters(in: .whitespaces),
                isCompleted: checked,
                completedOn: checked ? completion?.date : nil
            ),
            prefix: prefix,
            closingBracket: closing,
            contentWithoutCompletion: visible,
            trailingWhitespace: trailingWhitespace
        )
    }

    private static func task(at lineIndex: Int, in markdown: String) -> MarkdownTask? {
        parsedLines(in: markdown).first { $0.index == lineIndex }?.task
    }

    private static func validCompletion(
        in content: String
    ) -> (fullRange: NSRange, date: String, trailingWhitespace: String)? {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = completionPattern.firstMatch(in: content, range: full) else { return nil }
        let date = ns.substring(with: match.range(at: 1))
        guard isCalendarDate(date) else { return nil }
        return (match.range(at: 0), date, ns.substring(with: match.range(at: 2)))
    }

    private static func splittingTrailingWhitespace(in content: String) -> (String, String) {
        let contentEnd = content.lastIndex { $0 != " " && $0 != "\t" }
            .map { content.index(after: $0) }
            ?? content.startIndex
        return (String(content[..<contentEnd]), String(content[contentEnd...]))
    }

    private static func listItem(in line: String) -> (indent: Int, remainder: String)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = listPattern.firstMatch(in: line, range: full) else { return nil }
        return (
            indentationWidth(of: ns.substring(with: match.range(at: 1))),
            ns.substring(with: match.range(at: 3))
        )
    }

    private static func strippingBlockquotePrefix(
        from line: String
    ) -> (depth: Int, prefix: String, content: String) {
        var content = line[...]
        var depth = 0
        while true {
            var cursor = content.startIndex
            var spaces = 0
            while cursor < content.endIndex, spaces < 3, content[cursor] == " " {
                cursor = content.index(after: cursor)
                spaces += 1
            }
            guard cursor < content.endIndex, content[cursor] == ">" else { break }
            cursor = content.index(after: cursor)
            if cursor < content.endIndex, content[cursor] == " " {
                cursor = content.index(after: cursor)
            }
            content = content[cursor...]
            depth += 1
        }
        let prefix = String(line[..<content.startIndex])
        return (depth, prefix, String(content))
    }

    private static func fenceMarker(in line: String) -> FenceMarker? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = fencePattern.firstMatch(in: line, range: full) else { return nil }
        let marker = ns.substring(with: match.range(at: 1))
        guard let character = marker.first else { return nil }
        let trailing = ns.substring(with: match.range(at: 2))
        return FenceMarker(
            fence: Fence(character: character, length: marker.count),
            canClose: trailing.allSatisfy { $0 == " " || $0 == "\t" }
        )
    }

    private static func indentationWidth(of text: String) -> Int {
        text.prefix { $0 == " " || $0 == "\t" }.reduce(0) { width, character in
            character == "\t" ? width + 4 : width + 1
        }
    }

    private static func isCalendarDate(_ value: String) -> Bool {
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: values[0],
            month: values[1],
            day: values[2]
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == values[0]
            && roundTrip.month == values[1]
            && roundTrip.day == values[2]
    }
}
