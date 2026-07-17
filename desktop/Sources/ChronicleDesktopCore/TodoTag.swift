import Foundation

/// Desktop mirror of the API/web `#todo` grammar. Text remains the source of
/// truth; these helpers only derive display state and composer suggestions.
public enum CaptureTodoTag {
    private static let expression = try! NSRegularExpression(
        pattern: #"(^|\s)(#todo(\(done(?::\d{4}-\d{2}-\d{2})?\))?)(?=[^\p{L}\p{N}_(-]|$)"#
    )

    public static func state(in text: String) -> CaptureTodoState? {
        guard let match = firstMatch(in: text) else { return nil }
        return match.range(at: 3).location == NSNotFound ? .open : .done
    }

    public static func displayText(from text: String) -> String {
        guard let match = firstMatch(in: text),
              let tokenRange = Range(match.range(at: 2), in: text)
        else {
            return text
        }
        var result = text
        result.removeSubrange(tokenRange)
        return result
            .replacingOccurrences(
                of: #"[ \t]{2,}"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }
}
