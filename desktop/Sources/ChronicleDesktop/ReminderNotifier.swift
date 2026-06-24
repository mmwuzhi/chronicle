import Foundation
import UserNotifications

import ChronicleDesktopCore

// Schedules reminders as macOS system notifications via UNCalendarNotificationTrigger.
// A trigger fires at its time even when the app isn't running, with no network
// or login — the offline-first path that replaces the old server polling.
// Requires a bundle id (packaged .app); the caller gates on Bundle.main, since
// UNUserNotificationCenter traps under a bare `swift run`.
@MainActor
final class ReminderNotifier {
    // Settings toggle: when explicitly false, due reminders are not turned into
    // system notifications. Absent (default) means enabled, preserving the
    // original always-on behavior (and the existing tests).
    static let enabledKey = "notifyOnReminderDue"

    private static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let store: LocalCaptureStore
    private let makeClient: () -> ReminderAPIClient?
    private var lastEnabled = ReminderNotifier.notificationsEnabled

    init(store: LocalCaptureStore, makeClient: @escaping () -> ReminderAPIClient?) {
        self.store = store
        self.makeClient = makeClient
    }

    // Call once at launch (only when Bundle.main.bundleIdentifier != nil).
    func start() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        reconcileLocal()
        syncFromServer()
        observeEnabledToggle()
    }

    // The reminders toggle is an @AppStorage default; react to it at runtime so
    // disabling actually stops alerts instead of only suppressing future ones.
    private func observeEnabledToggle() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyEnabledChange() }
        }
    }

    // Act only on an actual on/off transition (didChangeNotification fires for any
    // default write). Off: cancel the notifications already scheduled — a calendar
    // trigger otherwise fires even with the app closed. On: reschedule from local +
    // server state so not-yet-fired reminders come back.
    private func applyEnabledChange() {
        let enabled = Self.notificationsEnabled
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        if enabled {
            reconcileLocal()
            syncFromServer()
        } else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }

    func schedule(_ record: LocalCaptureRecord) {
        guard Self.notificationsEnabled else { return }
        guard let remindAt = record.payload.remindAt else { return }
        let scheduled = scheduleNotification(
            id: record.notificationId, text: record.payload.rawText, at: remindAt)
        if scheduled {
            // A future-dated calendar trigger now guarantees delivery even with the
            // app closed, so mark this reminder handled. Without it, once the reminder
            // syncs and later shows up in `due`, notifyDueFromServer would post a
            // *second* alert for the same reminder (its notified_at would still be
            // nil). Past-dated reminders schedule nothing and fall through to the due
            // path for a single immediate alert.
            try? store.markNotified(localId: record.id)
        }
    }

    func cancel(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Local (Phase A)

    private func reconcileLocal() {
        for record in (try? store.upcomingReminders()) ?? [] {
            schedule(record)
        }
    }

    // Returns whether a calendar trigger was actually registered (false when the
    // date is in the past, which a calendar trigger can't fire on).
    @discardableResult
    private func scheduleNotification(id: String, text: String, at date: Date) -> Bool {
        guard date > Date() else { return false }  // a calendar trigger can't fire in the past
        let content = UNMutableNotificationContent()
        content.title = "Chronicle reminder"
        content.body = text.isEmpty ? "A capture is due" : text
        content.sound = .default
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        UNUserNotificationCenter.current().add(request)  // same identifier replaces → idempotent
        return true
    }

    // MARK: - Server sync (Phase B)

    func syncFromServer() {
        guard let client = makeClient() else { return }  // not signed in → local only
        Task {
            let pending = (try? await client.pending()) ?? []
            let due = (try? await client.due(since: nil)) ?? []
            await MainActor.run {
                for item in pending { self.scheduleFromServer(item) }
                for item in due { self.notifyDueFromServer(item) }
            }
        }
    }

    private func scheduleFromServer(_ item: ReminderItem) {
        guard let at = item.remindAt.flatMap(Self.parseISO) else { return }
        guard let record = try? store.upsertServerReminder(
            serverId: item.id,
            text: item.summary,
            remindAt: at,
        ) else {
            return
        }
        schedule(record)
    }

    private func notifyDueFromServer(_ item: ReminderItem) {
        // Honor the toggle for server-due reminders too, not just locally
        // scheduled ones (schedule() already guards). Without this, turning
        // notifications off still posts an alert for every reminder the server
        // reports as due.
        guard Self.notificationsEnabled else { return }
        let remindAt = item.remindAt.flatMap(Self.parseISO) ?? Date()
        guard (try? store.upsertDueServerReminder(
            serverId: item.id,
            text: item.summary,
            remindAt: remindAt,
        )) != nil else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Chronicle reminder"
        content.body = item.summary
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "rmd-\(item.id)", content: content, trigger: nil))
    }

    private static func parseISO(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }
}
