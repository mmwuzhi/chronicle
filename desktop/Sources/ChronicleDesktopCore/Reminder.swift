import Foundation

// Time-based recall for the desktop app. The Go API exposes:
//   GET /reminders/due?since=   captures whose remind_at fell in (since, now]
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

    public func makeDueRequest(since: String?) -> URLRequest {
        var components = URLComponents(
            url: config.apiURL.appending(path: "reminders/due"),
            resolvingAgainstBaseURL: false,
        )!
        if let since, !since.isEmpty {
            components.queryItems = [URLQueryItem(name: "since", value: since)]
        }
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

    public func due(since: String?) async throws -> [ReminderItem] {
        let (data, response) = try await AuthedTransport.send(
            makeDueRequest(since: since), session: session, refresher: refresher)
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
