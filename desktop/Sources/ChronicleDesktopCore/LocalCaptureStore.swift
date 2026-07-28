import Foundation
import SQLite3

/// The security boundary for Chronicle's on-device cache.
///
/// An API bearer token is not an identity: the desktop must first verify it with
/// `/users/me`, then bind local data to that returned user id plus the API origin
/// that vouched for it. Keeping the origin in the key prevents two independent
/// Chronicle servers from colliding even if they issue the same user UUID.
public struct LocalCaptureScope: Equatable, Hashable, Sendable {
    public let apiOrigin: String
    public let userID: String

    public init?(apiURL: URL, userID: String) {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, let origin = Self.origin(of: apiURL) else { return nil }
        self.apiOrigin = origin
        self.userID = userID
    }

    public static func origin(of apiURL: URL) -> String? {
        guard let scheme = apiURL.scheme?.lowercased(),
              let host = apiURL.host?.lowercased(),
              !scheme.isEmpty, !host.isEmpty
        else { return nil }
        let port = apiURL.port ?? (scheme == "https" ? 443 : 80)
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(renderedHost):\(port)"
    }

    /// Stable SQLite / pin-cache key. This is an identifier, not a secret.
    public var persistenceKey: String {
        "\(apiOrigin)\u{1F}\(userID)"
    }

    /// Deterministic scope for isolated test databases and the executable E2E
    /// harness. Production app code never falls back to this scope.
    public static let testing = LocalCaptureScope(
        apiURL: URL(string: "http://localhost")!,
        userID: "chronicle-desktop-test-user"
    )!
}

public struct LocalCaptureRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var scope: LocalCaptureScope
    public var payload: CapturePayload
    public var createdAt: Date
    public var updatedAt: Date
    public var serverId: String?
    public var syncedAt: Date?
    public var editRevision: Int
    public var syncedRevision: Int
    public var lastError: String?
    public var notifiedAt: Date?

    public var notificationId: String {
        "rmd-local-\(id)"
    }

    public var isSynced: Bool {
        serverId != nil && syncedAt != nil
    }

    public var hasPendingUpdate: Bool {
        serverId != nil && editRevision > syncedRevision
    }
}

public enum LocalCaptureStoreError: Error, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case scopeUnavailable
}

public struct LocalCaptureSyncBacklog: Equatable, Sendable {
    public let pendingCreates: Int
    public let pendingUpdates: Int

    public var total: Int {
        pendingCreates + pendingUpdates
    }
}

public final class LocalCaptureStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var activeScope: LocalCaptureScope?

    public init(fileURL: URL, scope: LocalCaptureScope? = nil) {
        self.fileURL = fileURL
        activeScope = scope
    }

    /// Switch the complete local data boundary atomically. Passing nil quarantines
    /// every row until an identity has been verified (or a persisted, same-origin
    /// signed-out binding is explicitly restored).
    public func activate(_ scope: LocalCaptureScope?) {
        lock.withLock {
            activeScope = scope
        }
    }

    public var scope: LocalCaptureScope? {
        lock.withLock { activeScope }
    }

    public func isActive(_ record: LocalCaptureRecord) -> Bool {
        lock.withLock { activeScope == record.scope }
    }

    @discardableResult
    public func create(_ payload: CapturePayload, now: Date = Date()) throws -> LocalCaptureRecord {
        let id = UUID().uuidString
        return try withScopedDatabase { db, scope in
            let record = LocalCaptureRecord(
                id: id,
                scope: scope,
                payload: payload,
                createdAt: now,
                updatedAt: now,
                serverId: nil,
                syncedAt: nil,
                editRevision: 0,
                syncedRevision: 0,
                lastError: nil,
                notifiedAt: nil,
            )
            let sql = """
                INSERT INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                    remind_hide, account_scope
                ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, record.id)
                bindText(stmt, 2, payload.rawText)
                bindText(stmt, 3, payload.mediaType)
                // Legacy cache column (classified_as TEXT NOT NULL, from before the
                // server's todo-facet migration). Kept to avoid a cache schema
                // migration — the cache is rebuildable; the value is never read back.
                bindText(stmt, 4, "unclassified")
                bindText(stmt, 5, payload.source)
                bindOptionalDate(stmt, 6, payload.remindAt)
                bindDate(stmt, 7, record.createdAt)
                bindDate(stmt, 8, record.updatedAt)
                bindOptionalBool(stmt, 9, payload.remindHide)
                bindText(stmt, 10, scope.persistenceKey)
            }
            return record
        }
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
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ? AND raw_text LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC
            LIMIT ?
            """,
        ) { stmt in
            bindText(stmt, 2, "%\(escaped)%")
            sqlite3_bind_int(stmt, 3, Int32(limit))
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
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ?
              AND trim(raw_text) <> ''
              AND (embedding IS NULL OR embed_model IS NOT ?)
            ORDER BY created_at DESC
            LIMIT ?
            """,
        ) { stmt in
            bindText(stmt, 2, model)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }
    }

    // Cache one capture's embedding (raw float32 bytes) and its producing model.
    public func setEmbedding(id: String, model: String, vector: [Float]) throws {
        let data = vector.withUnsafeBytes { Data($0) }
        try withScopedDatabase { db, scope in
            try executeStatement(
                db, """
                UPDATE local_captures SET embedding = ?, embed_model = ?
                WHERE id = ? AND account_scope = ?
                """
            ) { stmt in
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(data.count), sqliteTransient)
                }
                bindText(stmt, 2, model)
                bindText(stmt, 3, id)
                bindText(stmt, 4, scope.persistenceKey)
            }
        }
    }

    // Every locally-cached capture with a current-model embedding, paired with its
    // vector — the corpus the caller ranks a query against. Small by nature (the
    // on-device store), so loading all vectors and ranking in memory is fine.
    public func embeddedRows(model: String) throws -> [(record: LocalCaptureRecord, vector: [Float])] {
        try withScopedDatabase { db, scope in
            let sql = """
                SELECT id, server_id, raw_text, media_type, classified_as, source,
                       remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                       remind_hide, account_scope, edit_revision, synced_revision, embedding
                FROM local_captures
                WHERE account_scope = ? AND embed_model = ? AND embedding IS NOT NULL
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, scope.persistenceKey)
            bindText(stmt, 2, model)

            var rows: [(record: LocalCaptureRecord, vector: [Float])] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else {
                    throw LocalCaptureStoreError.stepFailed(lastError(db))
                }
                let vector = columnFloatArray(stmt, 16)
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
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ?
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
        ) { stmt in
            sqlite3_bind_int(stmt, 2, Int32(limit))
            sqlite3_bind_int(stmt, 3, Int32(offset))
        }
    }

    public func pendingSync(limit: Int = 50) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ? AND server_id IS NULL
            ORDER BY created_at
            LIMIT ?
            """,
        ) { stmt in
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    // Server-backed rows whose edit revision is ahead of its acknowledged revision:
    // offline/optimistic edits waiting to be PATCHed back. Distinct from
    // pendingSync (never-created rows, server_id IS NULL) — these already exist on
    // the server and only need their new text pushed. Revisions are monotonic and
    // deliberately independent of wall-clock changes.
    public func pendingUpdates(limit: Int = 50) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ?
              AND server_id IS NOT NULL
              AND edit_revision > synced_revision
            ORDER BY updated_at
            LIMIT ?
            """,
        ) { stmt in
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    /// One exact definition of "waiting to sync" for status UI and sync summaries.
    /// Count both kinds in SQLite instead of loading and decoding bounded record
    /// lists: the user-visible backlog must not silently stop at a page limit.
    public func syncBacklog() throws -> LocalCaptureSyncBacklog {
        try withScopedDatabase { db, scope in
            let sql = """
                SELECT
                    COALESCE(SUM(CASE WHEN server_id IS NULL THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE
                        WHEN server_id IS NOT NULL
                         AND edit_revision > synced_revision
                        THEN 1 ELSE 0
                    END), 0)
                FROM local_captures
                WHERE account_scope = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, scope.persistenceKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw LocalCaptureStoreError.stepFailed(lastError(db))
            }
            return LocalCaptureSyncBacklog(
                pendingCreates: Int(sqlite3_column_int64(stmt, 0)),
                pendingUpdates: Int(sqlite3_column_int64(stmt, 1))
            )
        }
    }

    /// Compatibility overload for callers compiled against the former bounded API.
    /// The limit is intentionally ignored because backlog counts must be exact.
    @available(*, deprecated, message: "The limit is ignored; use syncBacklog() instead")
    public func syncBacklog(limit _: Int) throws -> LocalCaptureSyncBacklog {
        try syncBacklog()
    }

    public func upcomingReminders(now: Date = Date()) throws -> [LocalCaptureRecord] {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ? AND remind_at IS NOT NULL AND remind_at > ?
            ORDER BY remind_at
            """,
        ) { stmt in
            bindDate(stmt, 2, now)
        }
    }

    public func markSynced(localId: String, serverId: String, syncedAt: Date = Date()) throws {
        try withScopedDatabase { db, scope in
            try executeStatement(
                db, """
                DELETE FROM local_captures
                WHERE account_scope = ? AND server_id = ? AND id <> ?
                """
            ) { stmt in
                bindText(stmt, 1, scope.persistenceKey)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, localId)
            }
            let sql = """
                UPDATE local_captures
                SET server_id = ?, synced_at = ?, updated_at = ?,
                    synced_revision = edit_revision, last_error = NULL
                WHERE id = ? AND account_scope = ?
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, serverId)
                bindDate(stmt, 2, syncedAt)
                bindDate(stmt, 3, syncedAt)
                bindText(stmt, 4, localId)
                bindText(stmt, 5, scope.persistenceKey)
            }
        }
    }

    /// Cache a capture that was created remotely first, such as a multipart
    /// media upload or a cloud-drive attachment capture. It is already synced,
    /// so it must never enter the pending-create queue.
    @discardableResult
    public func cacheServerCapture(
        serverId: String,
        payload: CapturePayload,
        createdAt: Date = Date(),
        syncedAt: Date = Date()
    ) throws -> LocalCaptureRecord {
        try withScopedDatabase { db, scope in
            let sql = """
                INSERT OR IGNORE INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                    remind_hide, account_scope
                ) VALUES (?, ?, ?, ?, 'unclassified', ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, UUID().uuidString)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, payload.rawText)
                bindText(stmt, 4, payload.mediaType)
                bindText(stmt, 5, payload.source)
                bindOptionalDate(stmt, 6, payload.remindAt)
                bindDate(stmt, 7, createdAt)
                bindDate(stmt, 8, syncedAt)
                bindDate(stmt, 9, syncedAt)
                bindOptionalBool(stmt, 10, payload.remindHide)
                bindText(stmt, 11, scope.persistenceKey)
            }
            try executeStatement(
                db, """
                UPDATE local_captures
                SET raw_text = ?, media_type = ?, source = ?, remind_at = ?,
                    updated_at = ?, synced_at = ?, last_error = NULL,
                    remind_hide = ?, synced_revision = edit_revision
                WHERE account_scope = ? AND server_id = ?
                """
            ) { stmt in
                bindText(stmt, 1, payload.rawText)
                bindText(stmt, 2, payload.mediaType)
                bindText(stmt, 3, payload.source)
                bindOptionalDate(stmt, 4, payload.remindAt)
                bindDate(stmt, 5, syncedAt)
                bindDate(stmt, 6, syncedAt)
                bindOptionalBool(stmt, 7, payload.remindHide)
                bindText(stmt, 8, scope.persistenceKey)
                bindText(stmt, 9, serverId)
            }
        }
        guard let record = try find(serverId: serverId) else {
            throw LocalCaptureStoreError.stepFailed("cached server capture did not return a row")
        }
        return record
    }

    // Complete a create-sync. Marks the row synced (server_id + synced_at), but if
    // its text changed since `sentText` was snapshotted — an edit raced the
    // in-flight create POST, so the server received the stale create payload —
    // leaves edit_revision ahead of synced_revision so pendingUpdates re-PATCHes
    // the newer text instead of stranding the server on the old copy. Returns true
    // when a concurrent edit was detected and the row was kept dirty for re-push.
    @discardableResult
    public func markCreateSynced(
        localId: String, serverId: String, sentText: String, sentRevision: Int,
        syncedAt: Date = Date()
    ) throws -> Bool {
        return try withScopedDatabase { db, scope in
            // Keep the create completion and re-edit detection under the store
            // lock. Most importantly, never write raw_text here: an edit arriving
            // during the POST already owns that column and must not be overwritten
            // by the older payload snapshot.
            try executeStatement(
                db, """
                DELETE FROM local_captures
                WHERE account_scope = ? AND server_id = ? AND id <> ?
                """
            ) { stmt in
                bindText(stmt, 1, scope.persistenceKey)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, localId)
            }
            let sql = """
                UPDATE local_captures
                SET server_id = ?, synced_at = ?,
                    synced_revision = MAX(synced_revision, ?),
                    updated_at = CASE WHEN raw_text = ? THEN ? ELSE updated_at END,
                    last_error = NULL
                WHERE id = ? AND account_scope = ?
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, serverId)
                bindDate(stmt, 2, syncedAt)
                sqlite3_bind_int64(stmt, 3, sqlite3_int64(sentRevision))
                bindText(stmt, 4, sentText)
                bindDate(stmt, 5, syncedAt)
                bindText(stmt, 6, localId)
                bindText(stmt, 7, scope.persistenceKey)
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, """
                SELECT raw_text FROM local_captures
                WHERE id = ? AND account_scope = ?
                """, -1, &stmt, nil
            ) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, localId)
            bindText(stmt, 2, scope.persistenceKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw LocalCaptureStoreError.stepFailed(lastError(db))
            }
            return columnText(stmt, 0) != sentText
        }
    }

    // Acknowledge exactly the revision that was PATCHed. A concurrent re-edit
    // increments edit_revision, so it stays ahead of synced_revision regardless
    // of wall-clock movement and is replayed on the next pass.
    public func markUpdatePushed(
        localId: String,
        syncedRevision: Int,
        syncedAt: Date
    ) throws {
        try withScopedDatabase { db, scope in
            try executeStatement(
                db, """
                UPDATE local_captures
                SET synced_at = ?, synced_revision = MAX(synced_revision, ?),
                    last_error = NULL
                WHERE id = ? AND account_scope = ?
                """
            ) { stmt in
                bindDate(stmt, 1, syncedAt)
                sqlite3_bind_int64(stmt, 2, sqlite3_int64(syncedRevision))
                bindText(stmt, 3, localId)
                bindText(stmt, 4, scope.persistenceKey)
            }
        }
    }

    // Edit a capture's text in place (offline-first). Bumps updated_at but leaves
    // synced_revision untouched, so a server-backed row becomes dirty by revision
    // and pendingUpdates re-pushes it; an unsynced row
    // just carries the new text into its eventual create. `id` may be a server id
    // (synced rows key on it) or a local id (unsynced), so match both — as delete
    // does. Also drops any cached embedding: the vector indexed the *old* text, so
    // leaving it would make on-device semantic search keep ranking this capture by
    // stale content (rowsNeedingEmbedding only re-embeds rows with a missing or
    // different-model vector). Nulling it re-enqueues the row for re-embedding.
    // Returns the number of rows changed: 0 means the row isn't in the local cache
    // (a signed-in, server-only browse fragment), so the caller edits it directly
    // against the server instead.
    @discardableResult
    public func setText(id: String, rawText: String, now: Date = Date()) throws -> Int {
        try withScopedDatabase { db, scope in
            let sql = """
                UPDATE local_captures
                SET raw_text = ?, updated_at = ?, edit_revision = edit_revision + 1,
                    embedding = NULL, embed_model = NULL
                WHERE account_scope = ? AND (server_id = ? OR id = ?)
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, rawText)
                bindDate(stmt, 2, now)
                bindText(stmt, 3, scope.persistenceKey)
                bindText(stmt, 4, id)
                bindText(stmt, 5, id)
            }
            return Int(sqlite3_changes(db))
        }
    }

    // Drop a capture's local row once it is deleted on the server, so it stops
    // resurfacing in offline browse/search (the cache would otherwise outlive the
    // server-side soft delete). `id` may be the server id (synced rows surface
    // under it) or the local id (a row deleted before it ever synced), so match
    // both. Hard delete is correct here — this is the on-device cache, not the
    // server's soft-delete-only user data.
    public func delete(id: String) throws {
        try withScopedDatabase { db, scope in
            try executeStatement(
                db, """
                DELETE FROM local_captures
                WHERE account_scope = ? AND (server_id = ? OR id = ?)
                """
            ) { stmt in
                bindText(stmt, 1, scope.persistenceKey)
                bindText(stmt, 2, id)
                bindText(stmt, 3, id)
            }
        }
    }

    public func markFailed(localId: String, error: Error, now: Date = Date()) throws {
        try withScopedDatabase { db, scope in
            let sql = """
                UPDATE local_captures
                SET last_error = ?, updated_at = ?
                WHERE id = ? AND account_scope = ?
                """
            try executeStatement(db, sql) { stmt in
                bindText(stmt, 1, String(describing: error))
                bindDate(stmt, 2, now)
                bindText(stmt, 3, localId)
                bindText(stmt, 4, scope.persistenceKey)
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
        try withScopedDatabase { db, scope in
            try executeStatement(db, """
                INSERT OR IGNORE INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                    account_scope
                ) VALUES (?, ?, ?, 'text', 'unclassified', 'server', ?, ?, ?, ?, NULL, NULL, ?)
                """) { stmt in
                bindText(stmt, 1, UUID().uuidString)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, text)
                bindDate(stmt, 4, remindAt)
                bindDate(stmt, 5, now)
                bindDate(stmt, 6, now)
                bindDate(stmt, 7, now)
                bindText(stmt, 8, scope.persistenceKey)
            }
            // A reminder refresh is not a text edit. Preserve a dirty offline edit
            // and its clocks so the update drain still PATCHes the user's text;
            // only clean rows may accept the server's summary snapshot.
            try executeStatement(db, """
                UPDATE local_captures
                SET raw_text = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE raw_text
                    END,
                    remind_at = ?,
                    updated_at = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE updated_at
                    END,
                    synced_at = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE synced_at
                    END,
                    last_error = NULL,
                    notified_at = NULL
                WHERE account_scope = ? AND server_id = ?
                """) { stmt in
                bindText(stmt, 1, text)
                bindDate(stmt, 2, remindAt)
                bindDate(stmt, 3, now)
                bindDate(stmt, 4, now)
                bindText(stmt, 5, scope.persistenceKey)
                bindText(stmt, 6, serverId)
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
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ? AND server_id = ?
            LIMIT 1
            """,
        ) { stmt in
            bindText(stmt, 2, serverId)
        }.first
    }

    // The local id stays stable across markSynced, so it can round-trip through
    // long-lived references (e.g. a reminder notification's userInfo) and still
    // resolve after the capture syncs.
    public func find(localId: String) throws -> LocalCaptureRecord? {
        try query(
            """
            SELECT id, server_id, raw_text, media_type, classified_as, source,
                   remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                   remind_hide, account_scope, edit_revision, synced_revision
            FROM local_captures
            WHERE account_scope = ? AND id = ?
            LIMIT 1
            """,
        ) { stmt in
            bindText(stmt, 2, localId)
        }.first
    }

    public func count() throws -> Int {
        try withScopedDatabase { db, scope in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM local_captures WHERE account_scope = ?",
                -1, &stmt, nil
            ) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, scope.persistenceKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw LocalCaptureStoreError.stepFailed(lastError(db))
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // Record that a reminder's local notification fired. This is bookkeeping, NOT a
    // text edit: it must not increment edit_revision. Doing so would make a
    // server-backed reminder look edited and get PATCHed to
    // /captures/{id} with the cached text — for server-sourced reminders that text
    // is the reminder *summary*, so the drain would overwrite the capture body.
    // Only user text edits (setText) advance edit_revision.
    public func markNotified(localId: String, now: Date = Date()) throws {
        try withScopedDatabase { db, scope in
            try executeStatement(
                db, """
                UPDATE local_captures SET notified_at = ?
                WHERE id = ? AND account_scope = ?
                """
            ) { stmt in
                bindDate(stmt, 1, now)
                bindText(stmt, 2, localId)
                bindText(stmt, 3, scope.persistenceKey)
            }
        }
    }

    public func upsertDueServerReminder(
        serverId: String,
        text: String,
        remindAt: Date,
        now: Date = Date()
    ) throws -> LocalCaptureRecord? {
        try withScopedDatabase { db, scope in
            try executeStatement(db, """
                INSERT OR IGNORE INTO local_captures (
                    id, server_id, raw_text, media_type, classified_as, source,
                    remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                    account_scope
                ) VALUES (?, ?, ?, 'text', 'unclassified', 'server', ?, ?, ?, ?, NULL, NULL, ?)
                """) { stmt in
                bindText(stmt, 1, UUID().uuidString)
                bindText(stmt, 2, serverId)
                bindText(stmt, 3, text)
                bindDate(stmt, 4, remindAt)
                bindDate(stmt, 5, now)
                bindDate(stmt, 6, now)
                bindDate(stmt, 7, now)
                bindText(stmt, 8, scope.persistenceKey)
            }
            try executeStatement(db, """
                UPDATE local_captures
                SET raw_text = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE raw_text
                    END,
                    remind_at = ?,
                    updated_at = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE updated_at
                    END,
                    synced_at = CASE
                        WHEN edit_revision <= synced_revision THEN ?
                        ELSE synced_at
                    END,
                    last_error = NULL
                WHERE account_scope = ? AND server_id = ?
                """) { stmt in
                bindText(stmt, 1, text)
                bindDate(stmt, 2, remindAt)
                bindDate(stmt, 3, now)
                bindDate(stmt, 4, now)
                bindText(stmt, 5, scope.persistenceKey)
                bindText(stmt, 6, serverId)
            }
        }
        guard let record = try find(serverId: serverId), record.notifiedAt == nil else {
            return nil
        }
        // Persisting the server row is only phase one. The notifier marks it
        // notified after UNUserNotificationCenter accepts the stable-id request;
        // an add/crash failure must leave this record retryable.
        return record
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> [LocalCaptureRecord] {
        try withScopedDatabase { db, scope in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw LocalCaptureStoreError.prepareFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, scope.persistenceKey)
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

    private func withScopedDatabase<T>(
        _ body: (OpaquePointer?, LocalCaptureScope) throws -> T
    ) throws -> T {
        try withDatabase { db in
            guard let activeScope else {
                throw LocalCaptureStoreError.scopeUnavailable
            }
            return try body(db, activeScope)
        }
    }

    private func migrate(_ db: OpaquePointer?) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS local_captures (
                id TEXT PRIMARY KEY,
                server_id TEXT,
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
        // NULL deliberately quarantines every row written by an older, unscoped
        // build. There is no safe way to infer which Chronicle account owned it,
        // so it must never appear or enter a future account's sync queue.
        try ensureColumn(db, table: "local_captures", column: "account_scope", definition: "TEXT")
        try ensureColumn(
            db, table: "local_captures", column: "edit_revision",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try ensureColumn(
            db, table: "local_captures", column: "synced_revision",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        // Preserve pending edits from the timestamp-based schema on first upgrade.
        // False positives are safer than dropping an edit: a replay is idempotent,
        // while an unqueued local change is permanent data loss.
        let migrateDirtyRows = """
            UPDATE local_captures
            SET edit_revision = 1, synced_revision = 0
            WHERE server_id IS NOT NULL
              AND (synced_at IS NULL OR updated_at <> synced_at)
              AND edit_revision = 0
              AND synced_revision = 0;
            """
        if sqlite3_exec(db, migrateDirtyRows, nil, nil, nil) != SQLITE_OK {
            throw LocalCaptureStoreError.execFailed(lastError(db))
        }
        try removeLegacyGlobalServerIDUniqueness(db)
        let scopedIndexes = """
            DROP INDEX IF EXISTS local_captures_pending_sync_idx;
            DROP INDEX IF EXISTS local_captures_remind_at_idx;
            CREATE INDEX IF NOT EXISTS local_captures_scope_recent_idx
                ON local_captures(account_scope, created_at DESC);
            CREATE INDEX IF NOT EXISTS local_captures_scope_pending_sync_idx
                ON local_captures(account_scope, created_at)
                WHERE server_id IS NULL;
            CREATE INDEX IF NOT EXISTS local_captures_scope_remind_at_idx
                ON local_captures(account_scope, remind_at)
                WHERE remind_at IS NOT NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS local_captures_scope_server_id_uidx
                ON local_captures(account_scope, server_id)
                WHERE account_scope IS NOT NULL AND server_id IS NOT NULL;
            """
        if sqlite3_exec(db, scopedIndexes, nil, nil, nil) != SQLITE_OK {
            throw LocalCaptureStoreError.execFailed(lastError(db))
        }
    }

    private func removeLegacyGlobalServerIDUniqueness(_ db: OpaquePointer?) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_captures'",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else {
            throw LocalCaptureStoreError.prepareFailed(lastError(db))
        }
        let hasLegacyUnique: Bool
        if sqlite3_step(stmt) == SQLITE_ROW,
           let createSQL = columnText(stmt, 0)
        {
            hasLegacyUnique = createSQL.uppercased().contains("SERVER_ID TEXT UNIQUE")
        } else {
            hasLegacyUnique = false
        }
        sqlite3_finalize(stmt)
        stmt = nil
        guard hasLegacyUnique else { return }

        let rebuild = """
            BEGIN IMMEDIATE;
            DROP TABLE IF EXISTS local_captures_scoped_rebuild;
            CREATE TABLE local_captures_scoped_rebuild (
                id TEXT PRIMARY KEY,
                server_id TEXT,
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
                remind_hide INTEGER,
                embedding BLOB,
                embed_model TEXT,
                account_scope TEXT,
                edit_revision INTEGER NOT NULL DEFAULT 0,
                synced_revision INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO local_captures_scoped_rebuild (
                id, server_id, raw_text, media_type, classified_as, source,
                remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                remind_hide, embedding, embed_model, account_scope,
                edit_revision, synced_revision
            )
            SELECT
                id, server_id, raw_text, media_type, classified_as, source,
                remind_at, created_at, updated_at, synced_at, last_error, notified_at,
                remind_hide, embedding, embed_model, account_scope,
                edit_revision, synced_revision
            FROM local_captures;
            DROP TABLE local_captures;
            ALTER TABLE local_captures_scoped_rebuild RENAME TO local_captures;
            COMMIT;
            """
        if sqlite3_exec(db, rebuild, nil, nil, nil) != SQLITE_OK {
            let message = lastError(db)
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw LocalCaptureStoreError.execFailed(message)
        }
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
    // Column 4 (legacy classified_as) is skipped: it stays in the schema and in
    // every SELECT so the positional indexes here keep working, but the payload
    // no longer carries it.
    let payload = CapturePayload(
        rawText: rawText,
        mediaType: columnText(stmt, 3) ?? "text",
        source: columnText(stmt, 5) ?? desktopQuickCaptureSource,
        remindAt: remindAt,
        remindHide: columnOptionalBool(stmt, 12),
    )
    guard let scopeKey = columnText(stmt, 13),
          let scope = localCaptureScope(fromPersistenceKey: scopeKey)
    else {
        throw LocalCaptureStoreError.stepFailed("scoped query returned an invalid account scope")
    }
    return LocalCaptureRecord(
        id: columnText(stmt, 0) ?? "",
        scope: scope,
        payload: payload,
        createdAt: try columnDate(stmt, 7) ?? Date(timeIntervalSince1970: 0),
        updatedAt: try columnDate(stmt, 8) ?? Date(timeIntervalSince1970: 0),
        serverId: columnText(stmt, 1),
        syncedAt: try columnDate(stmt, 9),
        editRevision: Int(sqlite3_column_int64(stmt, 14)),
        syncedRevision: Int(sqlite3_column_int64(stmt, 15)),
        lastError: columnText(stmt, 10),
        notifiedAt: try columnDate(stmt, 11),
    )
}

private func localCaptureScope(fromPersistenceKey key: String) -> LocalCaptureScope? {
    let parts = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let originURL = URL(string: String(parts[0]))
    else { return nil }
    return LocalCaptureScope(apiURL: originURL, userID: String(parts[1]))
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
