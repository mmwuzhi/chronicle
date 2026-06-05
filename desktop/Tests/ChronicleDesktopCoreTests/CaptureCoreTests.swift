import Foundation
import Testing

@testable import ChronicleDesktopCore

@Test
func capturePayloadUsesDesktopDefaults() {
    let payload = CapturePayload(rawText: "Follow up on report")

    #expect(payload.mediaType == "text")
    #expect(payload.classifiedAs == "unclassified")
    #expect(payload.source == desktopQuickCaptureSource)
}

@Test
func apiClientBuildsCaptureRequest() throws {
    let config = ChronicleConfig(apiURL: URL(string: "http://localhost:8080")!, token: "test-token")
    let client = CaptureAPIClient(config: config)

    let request = try client.makeRequest(for: CapturePayload(rawText: "Quick note"))

    #expect(request.url?.absoluteString == "http://localhost:8080/captures")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(CapturePayload.self, from: body)
    #expect(decoded.rawText == "Quick note")
    #expect(decoded.source == desktopQuickCaptureSource)
}

@Test
func authClientBuildsLoginRequest() throws {
    let client = AuthAPIClient(apiURL: URL(string: "http://localhost:8080")!)

    let request = try client.makeLoginRequest(email: "test@example.com", password: "password")

    #expect(request.url?.absoluteString == "http://localhost:8080/auth/login")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(LoginRequest.self, from: body)
    #expect(decoded.email == "test@example.com")
    #expect(decoded.password == "password")
}

@Test
func hotKeyParserParsesDefaultShortcut() throws {
    let spec = try #require(HotKeyParser.parse("control+option+space"))

    #expect(spec == HotKeyParser.defaultSpec)
    #expect(HotKeyParser.displayString(for: spec) == "control+option+space")
}

@Test
func shortcutParserDefaultsToDoubleControl() throws {
    let spec = try #require(ShortcutParser.parse("Double Control"))

    #expect(spec == ShortcutParser.defaultSpec)
    #expect(ShortcutParser.displayString(for: spec) == "Double Control")
}

@Test
func shortcutParserStillSupportsHotKeys() throws {
    let spec = try #require(ShortcutParser.parse("control+option+space"))

    #expect(ShortcutParser.displayString(for: spec) == "control+option+space")
}

@Test
func hotKeyParserParsesAliases() throws {
    let spec = try #require(HotKeyParser.parse("cmd+shift+k"))

    #expect(HotKeyParser.displayString(for: spec) == "command+shift+k")
}

@Test
func queueAppendsAndLoadsCaptures() throws {
    let queue = CaptureQueue(fileURL: temporaryQueueURL())
    let date = Date(timeIntervalSince1970: 1_800)

    try queue.append(CapturePayload(rawText: "Queue this"), queuedAt: date)

    let captures = try queue.load()
    #expect(captures == [QueuedCapture(payload: CapturePayload(rawText: "Queue this"), queuedAt: date)])
}

@Test
func retryQueueRemovesSentCaptures() async throws {
    let queue = CaptureQueue(fileURL: temporaryQueueURL())
    try queue.append(CapturePayload(rawText: "First"))
    try queue.append(CapturePayload(rawText: "Second"))

    let sender = StubSender(failingTexts: ["Second"])
    let result = try await queue.retry(using: sender)

    #expect(result.sent == 1)
    #expect(result.remaining == 1)
    #expect(try queue.load().map(\.payload.rawText) == ["Second"])
}

private func temporaryQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "queue.json")
}

private final class StubSender: CaptureSending {
    private let failingTexts: Set<String>

    init(failingTexts: Set<String> = []) {
        self.failingTexts = failingTexts
    }

    func send(_ payload: CapturePayload) async throws {
        if failingTexts.contains(payload.rawText) {
            throw CaptureAPIError.httpStatus(500)
        }
    }
}
