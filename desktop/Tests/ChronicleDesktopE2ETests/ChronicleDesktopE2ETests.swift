import ChronicleDesktopCore
import Foundation
import Network
import XCTest

final class ChronicleDesktopE2ETests: XCTestCase {
    func testCaptureLocalWritesPendingSQLiteRecord() throws {
        let dbURL = temporaryDatabaseURL()
        let text = "offline capture \(UUID().uuidString)"

        try runApp(mode: "capture-local", dbURL: dbURL, text: text)

        let pending = try LocalCaptureStore(fileURL: dbURL).pendingSync()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.payload.rawText, text)
        XCTAssertNil(pending.first?.serverId)
    }

    func testCaptureSyncPostsCaptureAndBackfillsServerID() throws {
        let server = try FakeChronicleServer()
        server.createdCaptureID = "server-capture-1"
        try server.start()
        defer { server.stop() }

        let dbURL = temporaryDatabaseURL()
        let remindAt = "2026-06-18T09:00:00Z"
        let text = "synced capture \(UUID().uuidString)"

        try runApp(
            mode: "capture-sync",
            dbURL: dbURL,
            apiURL: server.baseURL,
            token: "test-token",
            text: text,
            remindAt: remindAt,
        )

        let request = try XCTUnwrap(server.requests.first(where: { $0.method == "POST" && $0.path == "/captures" }))
        XCTAssertEqual(request.headers["authorization"], "Bearer test-token")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["rawText"] as? String, text)
        XCTAssertEqual(body["source"] as? String, desktopQuickCaptureSource)
        XCTAssertEqual(body["remindAt"] as? String, remindAt)

        let synced = try XCTUnwrap(LocalCaptureStore(fileURL: dbURL).find(serverId: "server-capture-1"))
        XCTAssertEqual(synced.payload.rawText, text)
        XCTAssertNotNil(synced.syncedAt)
    }

    func testReminderSyncStoresPendingServerReminder() throws {
        let server = try FakeChronicleServer()
        server.pendingReminders = [
            reminderJSON(id: "pending-reminder-1", text: "web reminder", remindAt: "2026-06-18T10:00:00Z"),
        ]
        try server.start()
        defer { server.stop() }

        let dbURL = temporaryDatabaseURL()

        try runApp(mode: "reminders-sync", dbURL: dbURL, apiURL: server.baseURL, token: "test-token")

        XCTAssertTrue(server.requests.contains { $0.method == "GET" && $0.path == "/reminders/pending" })
        let reminder = try XCTUnwrap(LocalCaptureStore(fileURL: dbURL).find(serverId: "pending-reminder-1"))
        XCTAssertEqual(reminder.payload.rawText, "web reminder")
        XCTAssertEqual(reminder.payload.remindAt, isoDate("2026-06-18T10:00:00Z"))
        XCTAssertNil(reminder.notifiedAt)
    }

    func testDueReminderSyncMarksNotifiedOnlyOnce() throws {
        let server = try FakeChronicleServer()
        server.dueReminders = [
            reminderJSON(id: "due-reminder-1", text: "due reminder", remindAt: "2026-06-18T08:00:00Z"),
        ]
        try server.start()
        defer { server.stop() }

        let dbURL = temporaryDatabaseURL()

        try runApp(mode: "reminders-sync", dbURL: dbURL, apiURL: server.baseURL, token: "test-token")
        let first = try XCTUnwrap(LocalCaptureStore(fileURL: dbURL).find(serverId: "due-reminder-1"))
        let firstNotifiedAt = try XCTUnwrap(first.notifiedAt)

        try runApp(mode: "reminders-sync", dbURL: dbURL, apiURL: server.baseURL, token: "test-token")
        let second = try XCTUnwrap(LocalCaptureStore(fileURL: dbURL).find(serverId: "due-reminder-1"))

        XCTAssertEqual(try LocalCaptureStore(fileURL: dbURL).count(), 1)
        XCTAssertEqual(second.notifiedAt, firstNotifiedAt)
        XCTAssertGreaterThanOrEqual(server.requests.filter { $0.path == "/reminders/due" }.count, 2)
    }

    private func runApp(
        mode: String,
        dbURL: URL,
        apiURL: URL? = nil,
        token: String? = nil,
        text: String = "e2e capture",
        remindAt: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let appPath = try appExecutablePath()
        let process = Process()
        process.executableURL = appPath

        var environment = ProcessInfo.processInfo.environment
        environment["CHRONICLE_DESKTOP_E2E"] = "1"
        environment["CHRONICLE_DESKTOP_E2E_MODE"] = mode
        environment["CHRONICLE_DESKTOP_E2E_CAPTURE_TEXT"] = text
        environment["CHRONICLE_DESKTOP_DB_PATH"] = dbURL.path
        if let apiURL {
            environment["CHRONICLE_API_URL"] = apiURL.absoluteString
        }
        if let token {
            environment["CHRONICLE_DESKTOP_E2E_TOKEN"] = token
        }
        if let remindAt {
            environment["CHRONICLE_DESKTOP_E2E_REMIND_AT"] = remindAt
        }
        process.environment = environment

        let stderr = Pipe()
        process.standardError = stderr
        let exited = expectation(description: "app exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 10)

        if process.isRunning {
            process.terminate()
            XCTFail("app did not exit", file: file, line: line)
        }
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput, file: file, line: line)
    }

    private func appExecutablePath() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_E2E_APP_PATH"], !raw.isEmpty else {
            throw XCTSkip("CHRONICLE_DESKTOP_E2E_APP_PATH is not set; run desktop/scripts/e2e.sh")
        }
        let url = URL(fileURLWithPath: raw)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("app executable not found at \(url.path)")
            throw XCTSkip("missing app executable")
        }
        return url
    }
}

private final class FakeChronicleServer: @unchecked Sendable {
    var createdCaptureID = "server-capture"
    var pendingReminders: [[String: Any]] = []
    var dueReminders: [[String: Any]] = []

    private let listener: NWListener
    private let lock = NSLock()
    private var storedRequests: [HTTPRequest] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    var baseURL: URL {
        let port = listener.port?.rawValue ?? 0
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func start() throws {
        let ready = XCTestExpectation(description: "server ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            throw FakeServerError.notReady
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var next = buffer
            if let data {
                next.append(data)
            }
            if let request = HTTPRequest(data: next) {
                self.record(request)
                self.respond(to: request, on: connection)
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let body: Data
        let status: String
        do {
            switch (request.method, request.path) {
            case ("POST", "/captures"):
                body = try JSONSerialization.data(withJSONObject: ["id": createdCaptureID])
                status = "200 OK"
            case ("GET", "/reminders/pending"):
                body = try JSONSerialization.data(withJSONObject: pendingReminders)
                status = "200 OK"
            case ("GET", "/reminders/due"):
                body = try JSONSerialization.data(withJSONObject: dueReminders)
                status = "200 OK"
            default:
                body = Data("{}".utf8)
                status = "404 Not Found"
            }
        } catch {
            body = Data("{}".utf8)
            status = "500 Internal Server Error"
        }

        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\n".utf8))
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else { return nil }

        method = requestParts[0]
        path = URLComponents(string: requestParts[1])?.path ?? requestParts[1]
        self.headers = headers
        body = data[bodyStart..<bodyStart + contentLength]
    }

    var jsonBody: [String: Any]? {
        guard !body.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return nil
        }
        return value
    }

    static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.headers == rhs.headers && lhs.body == rhs.body
    }
}

private enum FakeServerError: Error {
    case notReady
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "chronicle-e2e.sqlite3")
}

private func reminderJSON(id: String, text: String, remindAt: String) -> [String: Any] {
    [
        "id": id,
        "rawText": text,
        "transcript": NSNull(),
        "remindAt": remindAt,
        "createdAt": "2026-06-18T00:00:00Z",
    ]
}

private func isoDate(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
}
