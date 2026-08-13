import Foundation

/// Desktop mirror of the API/web `#todo` grammar. Text remains the source of
/// truth; these helpers only derive display state and composer suggestions.
public enum CaptureTodoTag {
    private static let expression = try! NSRegularExpression(
        pattern: #"(^|\s)(#todo(\(done(?::(\d{4}-\d{2}-\d{2}))?\))?)(?=[^\p{L}\p{N}_(-]|$)"#
    )

    public static func state(in text: String) -> CaptureTodoState? {
        guard let match = firstMatch(in: text) else { return nil }
        return match.range(at: 3).location == NSNotFound ? .open : .done
    }

    public static func displayText(from text: String) -> String {
        displayTextPreservingLines(from: text)
            .replacingOccurrences(
                of: #"[ \t]{2,}"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes the facet token without trimming leading or trailing newlines.
    /// Interactive Markdown controls use source line numbers for writes, so their
    /// display projection must keep every original line in place.
    public static func displayTextPreservingLines(from text: String) -> String {
        guard let match = firstMatch(in: text),
              let tokenRange = Range(match.range(at: 2), in: text)
        else {
            return text
        }
        var result = text
        result.removeSubrange(tokenRange)
        return result
    }

    /// The trailing hash token currently being typed, e.g. "#", "#t".
    public static func trailingSuggestionToken(in text: String) -> String? {
        let start = text.lastIndex(where: { $0.isWhitespace }).map {
            text.index(after: $0)
        } ?? text.startIndex
        let suffix = text[start...]
        guard suffix.first == "#", !suffix.dropFirst().contains("#") else {
            return nil
        }
        return String(suffix)
    }

    public static func offersSuggestion(for text: String) -> Bool {
        guard let token = trailingSuggestionToken(in: text) else { return false }
        return token != "#todo" && "#todo".hasPrefix(token)
    }

    public static func completingSuggestion(in text: String) -> String {
        guard let token = trailingSuggestionToken(in: text),
              "#todo".hasPrefix(token)
        else {
            return text
        }
        return String(text.dropLast(token.count)) + "#todo "
    }

    private static func firstMatch(in text: String) -> NSTextCheckingResult? {
        guard let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) else { return nil }
        guard match.range(at: 4).location != NSNotFound,
              let dateRange = Range(match.range(at: 4), in: text)
        else { return match }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: String(text[dateRange])) == nil ? nil : match
    }
}
