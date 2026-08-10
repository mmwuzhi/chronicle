import Foundation

/// Shared row-merging logic for browse, recent, and layered recall surfaces.
/// Pure and generic so it can be unit-tested here while the UI row types stay
/// in the app target.
public enum RowMerge {
    /// Rows the server cannot safely replace during online recall: unsynced
    /// captures do not exist remotely, while dirty server-backed captures carry
    /// newer local text. Exact-query dismissals may still exclude either row.
    public static func localRecallSupplement<T>(
        _ rows: [T],
        id: KeyPath<T, String>,
        synced: KeyPath<T, Bool>,
        dirty: KeyPath<T, Bool>,
        excludedIDs: Set<String> = [],
    ) -> [T] {
        rows.filter { row in
            (!row[keyPath: synced] || row[keyPath: dirty])
                && !excludedIDs.contains(row[keyPath: id])
        }
    }

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

    /// Append a later-ranked source without disturbing the order already shown.
    /// A duplicate enriches the first existing item instead of replacing it;
    /// Chronicle uses that seam to retain local editable text while adding server
    /// recall evidence.
    public static func preservingOrder<T>(
        existing: [T],
        incoming: [T],
        id: (T) -> String,
        mergeDuplicate: (inout T, T) -> Void,
    ) -> [T] {
        var result = existing
        var positions: [String: Int] = [:]
        for index in result.indices where positions[id(result[index])] == nil {
            positions[id(result[index])] = index
        }
        for item in incoming {
            let itemID = id(item)
            if let index = positions[itemID] {
                mergeDuplicate(&result[index], item)
                continue
            }
            positions[itemID] = result.endIndex
            result.append(item)
        }
        return result
    }
}
