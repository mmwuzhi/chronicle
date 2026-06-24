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

    public func append(_ payload: CapturePayload, queuedAt: Date = Date(),
                       reminderLocalId: String? = nil) throws {
        var captures = try load()
        captures.append(QueuedCapture(
            payload: payload, queuedAt: queuedAt, reminderLocalId: reminderLocalId))
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
        var uploaded: [UploadedCapture] = []

        for capture in captures {
            do {
                let id = try await sender.send(capture.payload)
                uploaded.append(UploadedCapture(id: id, reminderLocalId: capture.reminderLocalId))
            } catch {
                remaining.append(capture)
            }
        }

        try save(remaining)
        return RetryResult(sent: uploaded.count, remaining: remaining.count, uploaded: uploaded)
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
    public var uploaded: [UploadedCapture]

    public init(sent: Int, remaining: Int, uploaded: [UploadedCapture] = []) {
        self.sent = sent
        self.remaining = remaining
        self.uploaded = uploaded
    }
}

// One successfully uploaded queued capture: its new server id, plus the local
// reminder id (if any) that should now be re-keyed to that capture id.
public struct UploadedCapture: Equatable {
    public let id: String
    public let reminderLocalId: String?

    public init(id: String, reminderLocalId: String?) {
        self.id = id
        self.reminderLocalId = reminderLocalId
    }
}
