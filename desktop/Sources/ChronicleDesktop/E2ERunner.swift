import AppKit
import ChronicleDesktopCore
import Darwin
import Foundation

@MainActor
struct E2ERunner {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_E2E"] == "1"
    }

    private let delegate: AppDelegate
    private let environment: [String: String]

    init(delegate: AppDelegate, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.delegate = delegate
        self.environment = environment
    }

    func run() {
        Task {
            do {
                let notificationCount = CaptureChangeNotificationCounter()
                try await runMode()
                try notificationCount.writeIfRequested(environment: environment)
                NSApp.terminate(nil)
            } catch {
                let message = "ChronicleDesktop E2E failed: \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
        }
    }

    private func runMode() async throws {
        switch try required("CHRONICLE_DESKTOP_E2E_MODE") {
        case "capture-local":
            _ = try delegate.persistCapture(try capturePayload())
        case "capture-sync":
            let record = try delegate.persistCapture(try capturePayload())
            guard await delegate.sync(record, using: try captureClient(), notifySuccess: false) else {
                throw E2EError.syncFailed
            }
        case "reminders-sync":
            await delegate.syncServerReminders(using: try reminderClient())
        default:
            throw E2EError.unsupportedMode(environment["CHRONICLE_DESKTOP_E2E_MODE"] ?? "")
        }
    }

    private func capturePayload() throws -> CapturePayload {
        var payload = CapturePayload(rawText: try required("CHRONICLE_DESKTOP_E2E_CAPTURE_TEXT"))
        if let raw = environment["CHRONICLE_DESKTOP_E2E_REMIND_AT"], !raw.isEmpty {
            guard let date = Self.parseISO(raw) else {
                throw E2EError.invalidDate(raw)
            }
            payload.remindAt = date
        }
        return payload
    }

    private func captureClient() throws -> CaptureAPIClient {
        CaptureAPIClient(config: try config())
    }

    private func reminderClient() throws -> ReminderAPIClient {
        ReminderAPIClient(config: try config())
    }

    private func config() throws -> ChronicleConfig {
        guard let apiURL = URL(string: try required("CHRONICLE_API_URL")) else {
            throw E2EError.invalidURL(environment["CHRONICLE_API_URL"] ?? "")
        }
        return ChronicleConfig(apiURL: apiURL, token: try required("CHRONICLE_DESKTOP_E2E_TOKEN"))
    }

    private func required(_ key: String) throws -> String {
        guard let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw E2EError.missingEnv(key)
        }
        return value
    }

    private static func parseISO(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

private enum E2EError: Error, Equatable {
    case invalidDate(String)
    case invalidURL(String)
    case missingEnv(String)
    case syncFailed
    case unsupportedMode(String)
}

@MainActor
private final class CaptureChangeNotificationCounter {
    private var count = 0
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(
            forName: .chronicleCapturesChanged,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.count += 1
            }
        }
    }

    func writeIfRequested(environment: [String: String]) throws {
        guard let raw = environment["CHRONICLE_DESKTOP_E2E_CAPTURE_CHANGE_COUNT_PATH"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let url = URL(fileURLWithPath: raw)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try String(count).write(to: url, atomically: true, encoding: .utf8)
    }
}
