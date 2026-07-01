import Foundation
import SQLite3

public struct LocalCaptureRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var payload: CapturePayload
    public var createdAt: Date
    public var updatedAt: Date
    public var serverId: String?
    public var syncedAt: Date?
    public var lastError: String?
    public var notifiedAt: Date?

    public var notificationId: String {
        "rmd-local-\(id)"
    }

    public var isSynced: Bool {
        serverId != nil && syncedAt != nil
    }
}

public enum LocalCaptureStoreError: Error, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

public final class LocalCaptureStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    public func create(_ payload: CapturePayload, now: Date = Date()) throws -> LocalCaptureRecord {
        let id = UUID().uuidString
        let record = LocalCaptureRecord(
            id: id,
            payload: payload,
            createdAt: now,
            updatedAt: now,
            serverId: nil,
            syncedAt: nil,
            lastError: nil,
            notifiedAt: nil,
        )
        try withDatabase { db in
            let sql = """
                INSERT INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                    remind_hide
                ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?)
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, record.id)
                bindText(stmt, 2, payload.rawText)
                bindText(stmt, 3, payload.mediaType)
                bindText(stmt, 4, payload.classifiedAs)
                bindText(stmt, 5, payload.source)
                bindOptionalDate(stmt, 6, payload.remindAt)
                bindDate(stmt, 7, record.createdAt)
                bindDate(stmt, 8, record.updatedAt)
                bindOptionalBool(stmt, 9, payload.remindHide)
            }
        }
        return record
    }

    // Offline-first keyword search over the local store. The desktop searches
    // what it already holds with no login and no server round-trip; server
    // semantic results (when signed in) are merged on top by the caller.
    public func search(_ q: String, limit: Int = 50) throws -> [LocalCaptureRecord] {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Escape LIKE metacharacters so a literal % or _ in the query matches itself.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            WHERE raw_text LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC
            LIMIT ?
            """,
        ) { stmt in
            bindText(stmt, 1, "%\(escaped)%")
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    // MARK: - On-device semantic index (offline vector search)

    // Rows whose embedding is missing or came from a different model, newest
    // first. Media-only captures (no indexable text) are skipped — there is
    // nothing to embed. Caller embeds these and writes back via setEmbedding.
    public func rowsNeedingEmbedding(model: String, limit: Int = 200) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            WHERE trim(raw_text) <> ''
              AND (embedding IS NULL OR embed_model IS NOT ?)
            ORDER BY created_at DESC
            LIMIT ?
            """,
        ) { stmt in
            bindText(stmt, 1, model)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    // Cache one capture's embedding (raw float32 bytes) and its producing model.
    public func setEmbedding(id: String, model: String, vector: [Float]) throws {
        let data = vector.withUnsafeBytes { Data($0) }
        try withDatabase { db in
            try executeStatement(
                db, "UPDATE local_captures SET embedding = ?, embed_model = ? WHERE id = ?"
            ) { stmt in
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(data.count), sqliteTransient)
                }
                bindText(stmt, 2, model)
                bindText(stmt, 3, id)
            }
        }
    }

    // Every locally-cached capture with a current-model embedding, paired with its
    // vector — the corpus the caller ranks a query against. Small by nature (the
    // on-device store), so loading all vectors and ranking in memory is fine.
    public func embeddedRows(model: String) throws -> [(record: LocalCaptureRecord, vector: [Float])] {
        try withDatabase { db in
            let sql = """
                SELECT id, server_id, raw_text, media_type, classified_as, source,
                       remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                       remind_hide, embedding
                FROM local_captures
                WHERE embed_model = ? AND embedding IS NOT NULL
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, model)

            var rows: [(record: LocalCaptureRecord, vector: [Float])] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else {
                    throw LocalCaptureStoreError.stepFailed(lastError(db))
                }
                let vector = columnFloatArray(stmt, 13)
                if !vector.isEmpty {
                    rows.append((try decodeRecord(stmt), vector))
                }
            }
        }
    }

    // All local captures, newest first — the offline browse list.
    public func recent(limit: Int = 50, offset: Int = 0) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
        }
    }

    public func pendingSync(limit: Int = 50) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            WHERE server_id IS NULL
            ORDER BY created_at
            LIMIT ?
            """,
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
    }

    public func upcomingReminders(now: Date = Date()) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            WHERE remind_at IS NOT NULL AND remind_at > ?
            ORDER BY remind_at
            """,
        ) { stmt in
            bindDate(stmt, 1, now)
        }
    }

    public func markSynced(localId: String, serverId: String, syncedAt: Date = Date()) throws {
        try withDatabase { db in
            try executeStatement(db, "DELETE FROM local_captures WHERE server_id = ? AND id <> ?") { stmt in
                bindText(stmt, 1, serverId)
                bindText(stmt, 2, localId)
            }
            let sql = """
                UPDATE local_captures
                SET server_id = ?, synced_at = ?, updated_at = ?, last_error = NULL
                WHERE id = ?
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, serverId)
                bindDate(stmt, 2, syncedAt)
                bindDate(stmt, 3, syncedAt)
                bindText(stmt, 4, localId)
            }
        }
    }

    // Drop a capture's local row once it is deleted on the server, so it stops
    // resurfacing in offline browse/search (the cache would otherwise outlive the
    // server-side soft delete). `id` may be the server id (synced rows surface
    // under it) or the local id (a row deleted before it ever synced), so match
    // both. Hard delete is correct here — this is the on-device cache, not the
    // server's soft-delete-only user data.
    public func delete(id: String) throws {
        try withDatabase { db in
            try executeStatement(
                db, "DELETE FROM local_captures WHERE server_id = ? OR id = ?"
            ) { stmt in
                bindText(stmt, 1, id)
                bindText(stmt, 2, id)
            }
        }
    }

    public func markFailed(localId: String, error: Error, now: Date = Date()) throws {
        try withDatabase { db in
            let sql = """
                UPDATE local_captures
                SET last_error = ?, updated_at = ?
                WHERE id = ?
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, String(describing: error))
                bindDate(stmt, 2, now)
                bindText(stmt, 3, localId)
            }
        }
    }

    @discardableResult
    public func upsertServerReminder(
        serverId: String,
        text: String,
        remindAt: Date,
        now: Date = Date()
    ) throws -> LocalCaptureRecord {
        try withDatabase { db in
            let sql = """
                INSERT INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at
                ) VALUES (?, ?, ?, 'text', 'unclassified', 'server', ?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(server_id) DO UPDATE SET
                    raw_text = excluded.raw_text,
                    remind_at = excluded.remind_at,
                    updated_at = excluded.updated_at,
                    synced_at = excluded.synced_at,
                    last_error = NULL,
                    notified_at = NULL
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, UUID().uuidString)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, text)
                bindDate(stmt, 4, remindAt)
                bindDate(stmt, 5, now)
                bindDate(stmt, 6, now)
                bindDate(stmt, 7, now)
            }
        }
        if let existing = try find(serverId: serverId) {
            return existing
        }
        throw LocalCaptureStoreError.stepFailed("server reminder upsert did not return a row")
    }

    public func find(serverId: String) throws -> LocalCaptureRecord? {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide
            FROM local_captures
            WHERE server_id = ?
            LIMIT 1
            """,
        ) { stmt in
            bindText(stmt, 1, serverId)
        }.first
    }

    public func count() throws -> Int {
        try withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM local_captures", -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw LocalCaptureStoreError.stepFailed(lastError(db))
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    public func markNotified(localId: String, now: Date = Date()) throws {
        try withDatabase { db in
            let sql = """
                UPDATE local_captures
                SET notified_at = ?, updated_at = ?
                WHERE id = ?
                """
            try executeStatement(db, sql) { stmt in
                bindDate(stmt, 1, now)
                bindDate(stmt, 2, now)
                bindText(stmt, 3, localId)
            }
        }
    }

    public func upsertDueServerReminder(
        serverId: String,
        text: String,
        remindAt: Date,
        now: Date = Date()
    ) throws -> LocalCaptureRecord? {
        try withDatabase { db in
            let sql = """
                INSERT INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at
                ) VALUES (?, ?, ?, 'text', 'unclassified', 'server', ?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(server_id) DO UPDATE SET
                    raw_text = excluded.raw_text,
                    remind_at = excluded.remind_at,
                    updated_at = excluded.updated_at,
                    synced_at = excluded.synced_at,
                    last_error = NULL
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, UUID().uuidString)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, text)
                bindDate(stmt, 4, remindAt)
                bindDate(stmt, 5, now)
                bindDate(stmt, 6, now)
                bindDate(stmt, 7, now)
            }
        }
        guard let record = try find(serverId: serverId), record.notifiedAt == nil else {
            return nil
        }
        try markNotified(localId: record.id, now: now)
        return try find(serverId: serverId)
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> [LocalCaptureRecord] {
        try withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)

            var rows: [LocalCaptureRecord] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE {
                    return rows
                }
                guard result == SQLITE_ROW else {
                    throw LocalCaptureStoreError.stepFailed(lastError(db))
                }
                rows.append(try decodeRecord(stmt))
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        var db: OpaquePointer?
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
            let message = db.map(lastError) ?? "unknown sqlite open error"
            sqlite3_close(db)
            throw LocalCaptureStoreError.openFailed(message)
        }
        defer { sqlite3_close(db) }

        try migrate(db)
        return try body(db)
    }

    private func migrate(_ db: OpaquePointer?) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS local_captures (
                id TEXT PRIMARY KEY,
                server_id TEXT UNIQUE,
                raw_text TEXT NOT NULL,
                media_type TEXT NOT NULL,
                classified_as TEXT NOT NULL,
                source TEXT NOT NULL,
                remind_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                synced_at TEXT,
                last_error TEXT,
                notified_at TEXT,
                remind_hide INTEGER
            );
            CREATE INDEX IF NOT EXISTS local_captures_pending_sync_idx
                ON local_captures(created_at)
                WHERE server_id IS NULL;
            CREATE INDEX IF NOT EXISTS local_captures_remind_at_idx
                ON local_captures(remind_at)
                WHERE remind_at IS NOT NULL;
            """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw LocalCaptureStoreError.execFailed(lastError(db))
        }
        try ensureColumn(db, table: "local_captures", column: "notified_at", definition: "TEXT")
        // notify-only flag for offline-first captures: without it, a Keep-visible
        // capture saved offline would sync later with the hide default and vanish
        // from browse until due. NULL = unknown → server default (hide).
        try ensureColumn(db, table: "local_captures", column: "remind_hide", definition: "INTEGER")
        // On-device semantic search cache: the capture's embedding (raw float32
        // bytes) and the model that produced it. embed_model lets a model swap
        // invalidate stale vectors (rowsNeedingEmbedding re-embeds them).
        try ensureColumn(db, table: "local_captures", column: "embedding", definition: "BLOB")
        try ensureColumn(db, table: "local_captures", column: "embed_model", definition: "TEXT")
    }

    private func ensureColumn(
        _ db: OpaquePointer?,
        table: String,
        column: String,
        definition: String
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            throw LocalCaptureStoreError.prepareFailed(lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column {
                return
            }
        }
        if sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", nil, nil, nil) != SQLITE_OK {
            throw LocalCaptureStoreError.execFailed(lastError(db))
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func executeStatement(
    _ db: OpaquePointer?,
    _ sql: String,
    bind: (OpaquePointer?) -> Void
) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw LocalCaptureStoreError.prepareFailed(lastError(db))
    }
    defer { sqlite3_finalize(stmt) }
    bind(stmt)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw LocalCaptureStoreError.stepFailed(lastError(db))
    }
}

private func decodeRecord(_ stmt: OpaquePointer?) throws -> LocalCaptureRecord {
    let rawText = columnText(stmt, 2) ?? ""
    let remindAt = try columnDate(stmt, 6)
    // Column 12 across every decode SELECT (embeddedRows keeps its embedding blob
    // at 13). NULL for rows written before this column existed or by the
    // server-reminder path → nil → the server's hide default applies.
    let payload = CapturePayload(
        rawText: rawText,
        mediaType: columnText(stmt, 3) ?? "text",
        classifiedAs: columnText(stmt, 4) ?? "unclassified",
        source: columnText(stmt, 5) ?? desktopQuickCaptureSource,
        remindAt: remindAt,
        remindHide: columnOptionalBool(stmt, 12),
    )
    return LocalCaptureRecord(
        id: columnText(stmt, 0) ?? "",
        payload: payload,
        createdAt: try columnDate(stmt, 7) ?? Date(timeIntervalSince1970: 0),
        updatedAt: try columnDate(stmt, 8) ?? Date(timeIntervalSince1970: 0),
        serverId: columnText(stmt, 1),
        syncedAt: try columnDate(stmt, 9),
        lastError: columnText(stmt, 10),
        notifiedAt: try columnDate(stmt, 11),
    )
}

private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
}

private func bindDate(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date) {
    bindText(stmt, index, DateCodec.string(from: value))
}

private func bindOptionalDate(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date?) {
    guard let value else {
        sqlite3_bind_null(stmt, index)
        return
    }
    bindDate(stmt, index, value)
}

private func bindOptionalBool(_ stmt: OpaquePointer?, _ index: Int32, _ value: Bool?) {
    guard let value else {
        sqlite3_bind_null(stmt, index)
        return
    }
    sqlite3_bind_int(stmt, index, value ? 1 : 0)
}

private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
          let text = sqlite3_column_text(stmt, index)
    else {
        return nil
    }
    return String(cString: text)
}

private func columnDate(_ stmt: OpaquePointer?, _ index: Int32) throws -> Date? {
    guard let text = columnText(stmt, index) else { return nil }
    return DateCodec.date(from: text)
}

private func columnOptionalBool(_ stmt: OpaquePointer?, _ index: Int32) -> Bool? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int(stmt, index) != 0
}

// Decode a BLOB column of raw float32 bytes back into [Float]. Empty when the
// column is NULL/non-blob or its length is not a whole number of floats (a
// corrupt cache row is skipped, not crashed on).
private func columnFloatArray(_ stmt: OpaquePointer?, _ index: Int32) -> [Float] {
    guard sqlite3_column_type(stmt, index) == SQLITE_BLOB,
          let bytes = sqlite3_column_blob(stmt, index)
    else {
        return []
    }
    let byteCount = Int(sqlite3_column_bytes(stmt, index))
    guard byteCount > 0, byteCount % MemoryLayout<Float>.stride == 0 else { return [] }
    let buffer = UnsafeRawBufferPointer(start: bytes, count: byteCount)
    return Array(buffer.bindMemory(to: Float.self))
}

private func lastError(_ db: OpaquePointer?) -> String {
    guard let message = sqlite3_errmsg(db) else { return "unknown sqlite error" }
    return String(cString: message)
}

private enum DateCodec {
    static func string(from date: Date) -> String {
        let formatter = fractionalFormatter()
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        fractionalFormatter().date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
