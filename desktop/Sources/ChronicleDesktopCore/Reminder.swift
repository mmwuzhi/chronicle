import Foundation

// Time-based recall for the desktop app. The Go API exposes:
//   GET /reminders/due?since=&until=   a bounded page whose remind_at fell in
//                                     (since, until]
//   GET /reminders/pending      captures whose remind_at is still in the future
// Both return CaptureBody rows; we decode only the fields the notifier needs
// (JSONDecoder ignores the rest). remind_at filtering is browse-only on the
// server — search and recall never see it, preserving time-window completeness.

public struct ReminderItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let rawText: String?
    public let transcript: String?
    public let remindAt: String?
    public let createdAt: String

    public init(
        id: String, rawText: String?, transcript: String?,
        remindAt: String?, createdAt: String
    ) {
        self.id = id
        self.rawText = rawText
        self.transcript = transcript
        self.remindAt = remindAt
        self.createdAt = createdAt
    }

    // Text shown in the notification body: prefer the user's own text, fall back
    // to the AI transcript, then to a generic line.
    public var summary: String {
        if let rawText, !rawText.isEmpty { return rawText }
        if let transcript, !transcript.isEmpty { return transcript }
        return "A capture is due"
    }
}

public final class ReminderAPIClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig, session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func makeDueRequest(
        since: String?,
        until: String? = nil,
        beforeAt: String? = nil,
        beforeID: String? = nil,
        limit: Int? = nil
    ) -> URLRequest {
        var components = URLComponents(
            url: config.apiURL.appending(path: "reminders/due"),
            resolvingAgainstBaseURL: false,
        )!
        var queryItems: [URLQueryItem] = []
        if let since, !since.isEmpty {
            queryItems.append(URLQueryItem(name: "since", value: since))
        }
        if let until, !until.isEmpty {
            queryItems.append(URLQueryItem(name: "until", value: until))
        }
        if let beforeAt, !beforeAt.isEmpty {
            queryItems.append(URLQueryItem(name: "beforeAt", value: beforeAt))
        }
        if let beforeID, !beforeID.isEmpty {
            queryItems.append(URLQueryItem(name: "beforeId", value: beforeID))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func makePendingRequest() -> URLRequest {
        var request = URLRequest(url: config.apiURL.appending(path: "reminders/pending"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func due(
        since: String?,
        until: String? = nil,
        beforeAt: String? = nil,
        beforeID: String? = nil,
        limit: Int? = nil
    ) async throws -> [ReminderItem] {
        let (data, response) = try await AuthedTransport.send(
            makeDueRequest(
                since: since,
                until: until,
                beforeAt: beforeAt,
                beforeID: beforeID,
                limit: limit
            ),
            session: session,
            refresher: refresher
        )
        try Self.validate(response)
        return try JSONDecoder().decode([ReminderItem].self, from: data)
    }

    public func pending() async throws -> [ReminderItem] {
        let (data, response) = try await AuthedTransport.send(
            makePendingRequest(), session: session, refresher: refresher)
        try Self.validate(response)
        return try JSONDecoder().decode([ReminderItem].self, from: data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureAPIError.httpStatus(http.statusCode)
        }
    }
}

/// Durable due-reminder paging policy. A brand-new device intentionally fetches
/// only the newest 25 reminders from the last day, preventing an account's
/// historical backlog from becoming an alert storm. Once that bootstrap
/// succeeds, the saved per-account checkpoint makes later syncs lossless and
/// walks every bounded server page before advancing.
public struct ReminderDueBatch: Equatable, Sendable {
    public let items: [ReminderItem]
    public let checkpoint: Date

    public init(items: [ReminderItem], checkpoint: Date) {
        self.items = items
        self.checkpoint = checkpoint
    }
}

public final class ReminderDueSynchronizer: @unchecked Sendable {
    public static let initialLookback: TimeInterval = 24 * 60 * 60
    public static let initialLimit = 25
    public static let pageLimit = 100

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func checkpoint(for scope: LocalCaptureScope) -> Date? {
        defaults.object(forKey: checkpointKey(for: scope)) as? Date
    }

    public func fetch(
        using client: ReminderAPIClient,
        scope: LocalCaptureScope,
        now: Date = Date()
    ) async throws -> ReminderDueBatch {
        let checkpoint = checkpoint(for: scope)
        let since = checkpoint ?? now.addingTimeInterval(-Self.initialLookback)
        let sinceString = Self.formatISO(since)
        let untilString = Self.formatISO(now)
        let limit = checkpoint == nil ? Self.initialLimit : Self.pageLimit

        var items: [ReminderItem] = []
        var beforeAt: String?
        var beforeID: String?
        repeat {
            let page = try await client.due(
                since: sinceString,
                until: untilString,
                beforeAt: beforeAt,
                beforeID: beforeID,
                limit: limit
            )
            items.append(contentsOf: page)
            guard checkpoint != nil, page.count == limit, let last = page.last,
                  let lastRemindAt = last.remindAt
            else {
                break
            }
            beforeAt = lastRemindAt
            beforeID = last.id
        } while true

        // Do not advance here. The caller must first durably record every item;
        // otherwise a crash or SQLite failure between fetch and persistence
        // would permanently skip the returned reminders.
        return ReminderDueBatch(items: items, checkpoint: now)
    }

    public func commit(_ batch: ReminderDueBatch, for scope: LocalCaptureScope) {
        defaults.set(batch.checkpoint, forKey: checkpointKey(for: scope))
    }

    private func checkpointKey(for scope: LocalCaptureScope) -> String {
        "chronicle.reminders.due-checkpoint.\(scope.persistenceKey)"
    }

    private static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// A synced reminder that must be cancelled and dropped because it is no longer
// on the server. `notificationId` is the id its scheduled OS notification was
// registered under.
public struct OrphanedReminder: Equatable, Sendable {
    public let serverId: String
    public let notificationId: String

    public init(serverId: String, notificationId: String) {
        self.serverId = serverId
        self.notificationId = notificationId
    }
}

// Pure reconciliation: which locally-synced reminders were cleared or deleted
// elsewhere. `/reminders/pending` returns the *complete* set of not-yet-due
// reminders, so any local reminder carrying a server id that is absent from that
// set is an orphan — its scheduled calendar trigger would otherwise fire a stale
// alert. Kept free of UNUserNotificationCenter and the store so the invariant is
// unit-testable (the notifier itself traps under `swift test`).
//
// The caller MUST pass server ids from a *successful* pending() fetch; an empty
// set from a failed request would mark every reminder an orphan.
public func orphanedServerReminders(
    local: [LocalCaptureRecord], alivePendingServerIds: Set<String>
) -> [OrphanedReminder] {
    local.compactMap { record in
        guard let serverId = record.serverId,
            !alivePendingServerIds.contains(serverId)
        else { return nil }
        return OrphanedReminder(serverId: serverId, notificationId: record.notificationId)
    }
}
