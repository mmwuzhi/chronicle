import Foundation

/// Shared "merge two row sources into one list" logic for browse/recent
/// surfaces: dedup by id keeping the first occurrence (callers pass the
/// higher-priority source as `primary`), then order newest-first with undated
/// rows sinking to the end. Pure and generic so it can be unit-tested here
/// while the UI row types stay in the app target.
public enum RowMerge {
    public static func newestFirst<T>(
        primary: [T],
        secondary: [T],
        id: (T) -> String,
        date: (T) -> Date?,
    ) -> [T] {
        var seen = Set<String>()
        var rows: [T] = []
        for item in primary + secondary where seen.insert(id(item)).inserted {
            rows.append(item)
        }
        return rows.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
    }
}
