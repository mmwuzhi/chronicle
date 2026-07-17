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
    let openSignIn: () -> Void
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
    // Edit a capture's text in the local store (offline-first), keyed by the row id
    // (server id, or local id for an unsynced row). Returns true when a local row
    // was changed; false means the row isn't cached locally (a signed-in,
    // server-only browse fragment) and must be edited directly against the server.
    let localSetText: (String, String) -> Bool
    // Push offline/optimistic edits (dirty rows) to the server now, if a session is
    // live. No-op when signed out — the edits stay queued and replay on sign-in.
    let syncEdits: () async -> Void

    init(
        recall: @escaping () -> RecallAPIClient?,
        webhook: @escaping () -> WebhookAPIClient?,
        openSignIn: @escaping () -> Void,
        openDetail: @escaping (RowItem) -> Void = { _ in },
        togglePin: @escaping (RowItem) -> Void = { _ in },
        isPinned: @escaping (String) -> Bool = { _ in false },
        localSearch: @escaping (String) -> [RowItem],
        localSemanticSearch: @escaping (String) async -> [RowItem] = { _ in [] },
        localRecent: @escaping (Int) -> [RowItem],
        localDelete: @escaping (String) -> Void,
        localSetText: @escaping (String, String) -> Bool = { _, _ in false },
        syncEdits: @escaping () async -> Void = {}
    ) {
        self.recall = recall
        self.webhook = webhook
        self.openSignIn = openSignIn
        self.openDetail = openDetail
        self.togglePin = togglePin
        self.isPinned = isPinned
        self.localSearch = localSearch
        self.localSemanticSearch = localSemanticSearch
        self.localRecent = localRecent
        self.localDelete = localDelete
        self.localSetText = localSetText
        self.syncEdits = syncEdits
    }
}

/// What the menu-bar sign-in glyph + tooltip need to render: whether the server
/// session is known-expired, and how many local captures are waiting to sync.
/// `signedOut` is deliberately only true on a *proven* 401 — an offline app stays
/// quiet (offline-first), matching `SessionHealth.expired`.
struct SessionStatus: Equatable {
    var signedOut: Bool = false
    var pending: Int = 0
}

// MARK: - Row model

/// One renderable row, projected from either a search hit (RecallItem) or a
/// browsed capture (Capture) so the list rendering is shared.
struct RowItem: Identifiable, Equatable {
    let id: String
    // Text chosen for the current surface. This may be a transcript, a search
    // projection, or cached sticky text and is never assumed to be writable.
    let content: String
    var snippet: String?
    // The capture's actual user-authored raw_text when this row came from a full
    // CaptureBody or the local store. Search/related/sticky projections leave it
    // nil; those surfaces must fetch the full capture before starting an edit.
    let editableRawText: String?
    let createdAt: String
    // createdAt parsed once at construction — merge/sort comparators run per
    // pair, so parsing there re-parses the same strings hundreds of times.
    let createdDate: Date?
    let modality: String
    // True when this row is backed by a server capture (its id is a real server id).
    // Server-only actions can gate on this; desktop pins are allowed for local rows
    // because the sticky persists the capture content and can render offline.
    let synced: Bool
    // True for a server-backed local row whose text was edited since its last sync
    // (an offline/optimistic edit not yet pushed). Only local-cache rows can be
    // dirty; every server/search-sourced row is false. The browse merge floats a
    // dirty row ahead of its same-id server fragment so the not-yet-pushed new text
    // wins over the stale server copy (see MainView.rebuildBrowseRows).
    let dirty: Bool
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
        snippet = hit.snippet
        editableRawText = nil
        createdAt = hit.createdAt
        createdDate = CaptureTime.parse(hit.createdAt)
        modality = hit.modality
        synced = true
        dirty = false
        mediaUrl = nil
        todoState = nil
    }

    init(_ capture: Capture) {
        id = capture.id
        content = capture.content
        snippet = nil
        editableRawText = capture.rawText ?? ""
        createdAt = capture.createdAt
        createdDate = CaptureTime.parse(capture.createdAt)
        modality = capture.mediaType
        synced = true
        dirty = false
        mediaUrl = capture.mediaUrl
        todoState = capture.todoState
    }

    init(_ related: RelatedCapture) {
        id = related.id
        content = related.content
        snippet = nil
        editableRawText = nil
        createdAt = related.createdAt
        createdDate = CaptureTime.parse(related.createdAt)
        modality = related.modality
        synced = true
        dirty = false
        mediaUrl = nil
        todoState = nil
    }

    // Build a row from a pinned sticky's cached fields, so double-clicking a sticky
    // can open the capture's detail window.
    init(id: String, content: String, createdAt: String, modality: String, mediaUrl: String?) {
        self.id = id
        self.content = content
        self.snippet = nil
        self.editableRawText = nil
        self.createdAt = createdAt
        self.createdDate = CaptureTime.parse(createdAt)
        self.modality = modality
        self.synced = true
        self.dirty = false
        self.mediaUrl = mediaUrl
        self.todoState = CaptureTodoTag.state(in: content)
    }

    // From a local record. A synced record keys on its server id so it dedupes
    // against the same capture's server search hit; an unsynced one keeps its
    // local id (it exists only on this device until it syncs). `dirty` mirrors
    // LocalCaptureStore.pendingUpdates: a server-backed row edited since its last
    // sync (updated_at > synced_at) — the not-yet-pushed edit the merge must float
    // above the stale server fragment.
    init(_ record: LocalCaptureRecord) {
        id = record.serverId ?? record.id
        content = record.payload.rawText
        snippet = nil
        editableRawText = record.payload.rawText
        createdAt = RowItem.iso.string(from: record.createdAt)
        createdDate = record.createdAt
        modality = record.payload.mediaType
        synced = record.serverId != nil
        dirty = record.serverId != nil && (record.syncedAt.map { record.updatedAt > $0 } ?? true)
        mediaUrl = nil
        todoState = CaptureTodoTag.state(in: record.payload.rawText)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var displayText: String {
        let visible = snippet.flatMap { $0.isEmpty ? nil : $0 } ?? content
        guard todoState != nil else { return visible }
        return CaptureTodoTag.displayText(from: visible)
    }

    mutating func mergeDisplayEvidence(from other: RowItem) {
        guard snippet?.isEmpty != false,
              let evidence = other.snippet,
              !evidence.isEmpty
        else {
            return
        }
        snippet = evidence
    }
}

struct CaptureEditDraft: Equatable {
    var item: RowItem
    var text: String

    init?(item: RowItem) {
        guard let editableRawText = item.editableRawText else { return nil }
        self.item = item
        self.text = editableRawText
    }

    var id: String { item.id }
    var originalText: String { item.editableRawText ?? "" }
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
@MainActor
func describeCaptureError(_ error: Error) -> String {
    switch error {
    case CaptureAPIError.httpStatus(401): L("Session expired — sign in again from Settings.")
    case CaptureAPIError.httpStatus(503): L("Ask is unavailable — the recall service is offline.")
    default: DesktopLocalization.shared.format("Error: %@", error.localizedDescription)
    }
}

// MARK: - Recall mode

enum RecallMode: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case search = "Search"
    case ask = "Ask"

    var id: String { rawValue }

    @MainActor
    var title: String { L(rawValue) }

    @MainActor
    var placeholder: String {
        switch self {
        case .capture: L("Capture a thought…")
        case .search: L("Search captures…")
        case .ask: L("Ask a question…")
        }
    }

    var shortcutHint: String {
        switch self {
        case .capture: "⌘1"
        case .search: "⌘2"
        case .ask: "⌘3"
        }
    }

    @MainActor
    var sendHint: String {
        switch self {
        case .capture: L("⌘↩ Save")
        case .search: L("↩ Search")
        case .ask: L("↩ Ask")
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
    private static let sameYearChinese = dateFormatter("M月d日", locale: "zh_CN")
    private static let otherYearChinese = dateFormatter("yyyy年M月d日", locale: "zh_CN")
    // Same shape as the web app's precise stamp ("Jul 4, 2026 · 2:35pm") so the
    // two ends speak one time language.
    private static let exact: DateFormatter = {
        let f = dateFormatter("MMM d, yyyy · h:mma")
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()
    private static let exactChinese = dateFormatter("yyyy年M月d日 · HH:mm", locale: "zh_CN")

    private static func dateFormatter(_ format: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let f = DateFormatter()
        // POSIX locale pins the fixed format: without it macOS rewrites h↔HH to
        // match the user's 12/24-hour setting (QA1480). English stays pinned to
        // the web timestamp contract; the Chinese formatters use zh_CN explicitly.
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        return f
    }

    static func parse(_ value: String) -> Date? {
        iso.date(from: value) ?? isoPlain.date(from: value)
    }

    /// Compact relative stamp ("3m", "2h", "Jun 6") for the resting row state.
    @MainActor
    static func display(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return L("just now") }
        if secs < 3600 { return DesktopLocalization.shared.format("%dm", Int(secs / 60)) }
        if secs < 86400 { return DesktopLocalization.shared.format("%dh", Int(secs / 3600)) }
        if secs < 604800 { return DesktopLocalization.shared.format("%dd", Int(secs / 86400)) }
        let sameCalendarYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        if DesktopLocalization.shared.usesChinese {
            return (sameCalendarYear ? sameYearChinese : otherYearChinese).string(from: date)
        }
        return (sameCalendarYear ? sameYear : otherYear).string(from: date)
    }

    /// Exact stamp, revealed on hover (avoids the system tooltip's delay).
    @MainActor
    static func precise(_ value: String) -> String {
        guard let date = parse(value) else { return "" }
        return (DesktopLocalization.shared.usesChinese ? exactChinese : exact).string(from: date)
    }
}
