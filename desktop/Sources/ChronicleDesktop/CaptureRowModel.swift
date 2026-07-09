import Foundation
import ChronicleDesktopCore

// Non-view model shared by every list surface: API client bundle, the row
// projection, edit/delete plumbing, error wording, and timestamp formatting.

// MARK: - Clients

/// Fresh API clients built from the current signed-in config, or nil when not
/// signed in. Views call these per request so a sign-in mid-session is picked up.
@MainActor
final class CaptureClients {
    let recall: () -> RecallAPIClient?
    let webhook: () -> WebhookAPIClient?
    let openSettings: () -> Void
    // Open the single-capture detail window focused on the given row.
    let openDetail: (RowItem) -> Void
    // Pin / unpin a capture as a desktop sticky, and read whether one is pinned.
    let togglePin: (RowItem) -> Void
    let isPinned: (String) -> Bool
    // Offline-first local store access — always available, no login required.
    let localSearch: (String) -> [RowItem]
    // On-device semantic recall over the local cache (local Ollama). Returns []
    // when the embedder is unavailable, so callers merge it on top of localSearch.
    let localSemanticSearch: (String) async -> [RowItem]
    let localRecent: (Int) -> [RowItem]
    // Drop a capture's cached local row after it is deleted on the server, keyed
    // by the row id (server id, or local id for an unsynced row).
    let localDelete: (String) -> Void
    // Current session-visibility snapshot: whether the session is known-expired
    // (drives the "signed out" banner) and how many captures are queued locally
    // awaiting sync. Read on demand so any surface can render the nudge.
    let sessionStatus: () -> SessionStatus

    init(
        recall: @escaping () -> RecallAPIClient?,
        webhook: @escaping () -> WebhookAPIClient?,
        openSettings: @escaping () -> Void,
        openDetail: @escaping (RowItem) -> Void = { _ in },
        togglePin: @escaping (RowItem) -> Void = { _ in },
        isPinned: @escaping (String) -> Bool = { _ in false },
        localSearch: @escaping (String) -> [RowItem],
        localSemanticSearch: @escaping (String) async -> [RowItem] = { _ in [] },
        localRecent: @escaping (Int) -> [RowItem],
        localDelete: @escaping (String) -> Void,
        sessionStatus: @escaping () -> SessionStatus = { SessionStatus() }
    ) {
        self.recall = recall
        self.webhook = webhook
        self.openSettings = openSettings
        self.openDetail = openDetail
        self.togglePin = togglePin
        self.isPinned = isPinned
        self.localSearch = localSearch
        self.localSemanticSearch = localSemanticSearch
        self.localRecent = localRecent
        self.localDelete = localDelete
        self.sessionStatus = sessionStatus
    }
}

/// What the sign-in nudge needs to render: whether the server session is
/// known-expired, and how many local captures are waiting to sync. `signedOut`
/// is deliberately only true on a *proven* 401 — an offline app stays quiet
/// (offline-first), matching `SessionHealth.expired`.
struct SessionStatus: Equatable {
    var signedOut: Bool = false
    var pending: Int = 0
}

// MARK: - Row model

/// One renderable row, projected from either a search hit (RecallItem) or a
/// browsed capture (Capture) so the list rendering is shared.
struct RowItem: Identifiable, Equatable {
    let id: String
    let content: String
    let createdAt: String
    // createdAt parsed once at construction — merge/sort comparators run per
    // pair, so parsing there re-parses the same strings hundreds of times.
    let createdDate: Date?
    let modality: String
    // True when this row is backed by a server capture (its id is a real server id).
    // Server-only actions can gate on this; desktop pins are allowed for local rows
    // because the sticky persists the capture content and can render offline.
    let synced: Bool
    // Remote media URL (R2) for image/audio captures, when known. Search hits and
    // local records don't carry it (nil); a desktop sticky fills it in on refresh
    // from GET /captures/{id} so it can show an image thumbnail.
    let mediaUrl: String?
    // Todo facet, carried only by rows backed by a full CaptureBody (browse pages,
    // links, single fetches). Search hits, related, stickies, and local-cache rows
    // stay nil — the same asymmetry as the web, whose search modal shows no todo
    // state either. nil renders as a plain capture, not as "not a todo".
    let todoState: CaptureTodoState?

    init(_ hit: RecallItem) {
        id = hit.id
        content = hit.content
        createdAt = hit.createdAt
        createdDate = CaptureTime.parse(hit.createdAt)
        modality = hit.modality
        synced = true
        mediaUrl = nil
        todoState = nil
    }

    init(_ capture: Capture) {
        id = capture.id
        content = capture.content
        createdAt = capture.createdAt
        createdDate = CaptureTime.parse(capture.createdAt)
        modality = capture.mediaType
        synced = true
        mediaUrl = capture.mediaUrl
        todoState = capture.todoState
    }

    init(_ related: RelatedCapture) {
        id = related.id
        content = related.content
        createdAt = related.createdAt
        createdDate = CaptureTime.parse(related.createdAt)
        modality = related.modality
        synced = true
        mediaUrl = nil
        todoState = nil
    }

    // Build a row from a pinned sticky's cached fields, so double-clicking a sticky
    // can open the capture's detail window.
    init(id: String, content: String, createdAt: String, modality: String, mediaUrl: String?) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.createdDate = CaptureTime.parse(createdAt)
        self.modality = modality
        self.synced = true
        self.mediaUrl = mediaUrl
        self.todoState = nil
    }

    // From a local record. A synced record keys on its server id so it dedupes
    // against the same capture's server search hit; an unsynced one keeps its
    // local id (it exists only on this device until it syncs).
    init(_ record: LocalCaptureRecord) {
        id = record.serverId ?? record.id
        content = record.payload.rawText
        createdAt = RowItem.iso.string(from: record.createdAt)
        createdDate = record.createdAt
        modality = record.payload.mediaType
        synced = record.serverId != nil
        mediaUrl = nil
        todoState = nil
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct CaptureEditDraft: Equatable {
    var item: RowItem
    var text: String

    init(item: RowItem) {
        self.item = item
        self.text = item.content
    }

    var id: String { item.id }
    var originalText: String { item.content }
    var isDirty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != originalText
    }
}

enum CaptureDeletePlan: Equatable {
    case serverThenLocal(id: String)
    case localOnly(id: String)
    case unavailable
}

func captureDeletePlan(for row: RowItem, hasServerClient: Bool) -> CaptureDeletePlan {
    if row.synced {
        return hasServerClient ? .serverThenLocal(id: row.id) : .unavailable
    }
    return .localOnly(id: row.id)
}

// MARK: - Errors

/// One user-facing line for a capture-API failure, shared by every surface
/// (main window, quick panel, trash) so wording stays consistent.
func describeCaptureError(_ error: Error) -> String {
    switch error {
    case CaptureAPIError.httpStatus(401): "Session expired — sign in again from Settings."
    case CaptureAPIError.httpStatus(503): "Ask is unavailable — the recall service is offline."
    default: "Error: \(error.localizedDescription)"
    }
}

// MARK: - Recall mode

enum RecallMode: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case search = "Search"
    case ask = "Ask"

    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .capture: "Capture a thought…"
        case .search: "Search captures…"
        case .ask: "Ask a question…"
        }
    }

    var shortcutHint: String {
        switch self {
        case .capture: "⌘1"
        case .search: "⌘2"
        case .ask: "⌘3"
        }
    }

    var sendHint: String {
        switch self {
        case .capture: "⌘↩ Save"
        case .search: "↩ Search"
        case .ask: "↩ Ask"
        }
    }
}

// MARK: - Timestamps

enum CaptureTime {
    // Formatters are cached: parse/display/precise run for every visible timestamp
    // on each render (and on every hover flip to the precise stamp). ISO8601-/
    // DateFormatter are thread-safe (the latter since macOS 10.9); the unsafe
    // annotations just opt these immutable instances out of Swift 6's global-state
    // check.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    // Server timestamps carry fractional seconds, local ones don't; the fallback
    // used to allocate a fresh formatter on every non-fractional parse.
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static let sameYear = dateFormatter("MMM d")
    private static let otherYear = dateFormatter("MMM d, yyyy")
    // Same shape as the web app's precise stamp ("Jul 4, 2026 · 2:35pm") so the
    // two ends speak one time language.
    private static let exact: DateFormatter = {
        let f = dateFormatter("MMM d, yyyy · h:mma")
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        // POSIX locale pins the fixed format: without it macOS rewrites h↔HH to
        // match the user's 12/24-hour setting (QA1480) and localizes month names,
        // while the desktop UI is English-only.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func parse(_ value: String) -> Date? {
        iso.date(from: value) ?? isoPlain.date(from: value)
    }

    /// Compact relative stamp ("3m", "2h", "Jun 6") for the resting row state.
    static func display(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        if secs < 604800 { return "\(Int(secs / 86400))d" }
        let sameCalendarYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameCalendarYear ? sameYear : otherYear).string(from: date)
    }

    /// Exact stamp, revealed on hover (avoids the system tooltip's delay).
    static func precise(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        return exact.string(from: date)
    }
}
