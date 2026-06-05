import Foundation

public final class CaptureQueue {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ payload: CapturePayload, queuedAt: Date = Date()) throws {
        var captures = try load()
        captures.append(QueuedCapture(payload: payload, queuedAt: queuedAt))
        try save(captures)
    }

    public func load() throws -> [QueuedCapture] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }
        return try decoder.decode([QueuedCapture].self, from: data)
    }

    public func replace(with captures: [QueuedCapture]) throws {
        try save(captures)
    }

    public func retry(using sender: CaptureSending) async throws -> RetryResult {
        let captures = try load()
        var remaining: [QueuedCapture] = []
        var sent = 0

        for capture in captures {
            do {
                try await sender.send(capture.payload)
                sent += 1
            } catch {
                remaining.append(capture)
            }
        }

        try save(remaining)
        return RetryResult(sent: sent, remaining: remaining.count)
    }

    private func save(_ captures: [QueuedCapture]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try encoder.encode(captures)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct RetryResult: Equatable {
    public var sent: Int
    public var remaining: Int

    public init(sent: Int, remaining: Int) {
        self.sent = sent
        self.remaining = remaining
    }
}
