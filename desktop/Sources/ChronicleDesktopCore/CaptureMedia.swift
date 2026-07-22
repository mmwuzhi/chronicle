import Foundation

public let directCaptureUploadMaxBytes = 20 * 1024 * 1024

public struct CaptureMediaUpload: Equatable, Sendable {
    public let operationId: String
    public let data: Data
    public let filename: String
    public let mimeType: String
    public let text: String
    public let durationSeconds: Int?
    public let remindAt: Date?
    public let remindHide: Bool?

    public init(
        operationId: String = UUID().uuidString,
        data: Data,
        filename: String,
        mimeType: String,
        text: String = "",
        durationSeconds: Int? = nil,
        remindAt: Date? = nil,
        remindHide: Bool? = nil
    ) {
        self.operationId = operationId
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.text = text
        self.durationSeconds = durationSeconds
        self.remindAt = remindAt
        self.remindHide = remindHide
    }
}

public struct MediaUploadedCapture: Decodable, Equatable, Sendable {
    public let id: String
    public let mediaUrl: String
    public let mediaType: String
    public let source: String?
    public let createdAt: String?
}

public final class CaptureMediaUploadClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig,
        session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func makeRequest(
        for upload: CaptureMediaUpload,
        boundary: String = "chronicle_\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard upload.data.count <= directCaptureUploadMaxBytes else {
            throw CaptureMediaUploadError.fileTooLarge
        }
        var request = URLRequest(url: config.apiURL.appending(path: "captures/upload"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(upload.operationId, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(upload, boundary: boundary)
        return request
    }

    public func upload(_ upload: CaptureMediaUpload) async throws -> MediaUploadedCapture {
        let request = try makeRequest(for: upload)
        let (data, response) = try await AuthedTransport.send(
            request,
            session: session,
            refresher: refresher
        )
        guard let http = response as? HTTPURLResponse else {
            throw CaptureMediaUploadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureMediaUploadError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(MediaUploadedCapture.self, from: data)
    }
}

public enum CaptureMediaUploadError: Error, Equatable {
    case fileTooLarge
    case invalidResponse
    case httpStatus(Int)
}

private func multipartBody(_ upload: CaptureMediaUpload, boundary: String) -> Data {
    var body = Data()

    func append(_ string: String) {
        body.append(Data(string.utf8))
    }

    func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    let safeFilename = upload.filename.unicodeScalars.map { scalar -> Character in
        if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\\" || scalar == "\"" {
            return "_"
        }
        return Character(String(scalar))
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(String(safeFilename))\"\r\n")
    append("Content-Type: \(upload.mimeType)\r\n\r\n")
    body.append(upload.data)
    append("\r\n")
    appendField(name: "createCapture", value: "true")
    appendField(name: "source", value: desktopQuickCaptureSource)
    if !upload.text.isEmpty {
        appendField(name: "text", value: upload.text)
    }
    if let durationSeconds = upload.durationSeconds {
        appendField(name: "durationSec", value: String(durationSeconds))
    }
    if let remindAt = upload.remindAt {
        appendField(name: "remindAt", value: ISO8601DateFormatter().string(from: remindAt))
        appendField(name: "remindHide", value: String(upload.remindHide ?? true))
    }
    append("--\(boundary)--\r\n")
    return body
}

public struct CloudAttachmentDraft: Codable, Equatable, Sendable {
    public let provider: String
    public let providerFileId: String
    public let name: String
    public let mimeType: String?
    public let sizeBytes: Int?
    public let webUrl: String

    public init(
        provider: String,
        providerFileId: String,
        name: String,
        mimeType: String?,
        sizeBytes: Int?,
        webUrl: String
    ) {
        self.provider = provider
        self.providerFileId = providerFileId
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.webUrl = webUrl
    }
}

public final class CaptureAttachmentAPIClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig,
        session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func makeAddRequest(captureId: String, attachment: CloudAttachmentDraft) throws -> URLRequest {
        var request = URLRequest(
            url: config.apiURL
                .appending(path: "captures")
                .appending(path: captureId)
                .appending(path: "attachments")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(attachment)
        return request
    }

    public func add(captureId: String, attachment: CloudAttachmentDraft) async throws {
        let request = try makeAddRequest(captureId: captureId, attachment: attachment)
        let (_, response) = try await AuthedTransport.send(
            request,
            session: session,
            refresher: refresher
        )
        guard let http = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureAPIError.httpStatus(http.statusCode)
        }
    }
}

private struct CaptureWithAttachmentRequest: Encodable {
    let operationId: String
    let rawText: String
    let source: String
    let remindAt: Date?
    let remindHide: Bool?
    let attachment: CloudAttachmentDraft
}

public final class CaptureWithAttachmentAPIClient: @unchecked Sendable {
    private let config: ChronicleConfig
    private let session: URLSession
    private let refresher: AuthRefresher?

    public init(
        config: ChronicleConfig,
        session: URLSession = .shared,
        refresher: AuthRefresher? = nil
    ) {
        self.config = config
        self.session = session
        self.refresher = refresher
    }

    public func makeRequest(
        operationId: String,
        text: String,
        remindAt: Date?,
        remindHide: Bool?,
        attachment: CloudAttachmentDraft
    ) throws -> URLRequest {
        var request = URLRequest(
            url: config.apiURL
                .appending(path: "captures")
                .appending(path: "with-attachment")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(
            CaptureWithAttachmentRequest(
                operationId: operationId,
                rawText: text,
                source: desktopQuickCaptureSource,
                remindAt: remindAt,
                remindHide: remindHide,
                attachment: attachment
            )
        )
        return request
    }

    public func create(
        operationId: String,
        text: String,
        remindAt: Date?,
        remindHide: Bool?,
        attachment: CloudAttachmentDraft
    ) async throws -> Capture {
        let request = try makeRequest(
            operationId: operationId,
            text: text,
            remindAt: remindAt,
            remindHide: remindHide,
            attachment: attachment
        )
        let (data, response) = try await AuthedTransport.send(
            request,
            session: session,
            refresher: refresher
        )
        guard let http = response as? HTTPURLResponse else {
            throw CaptureAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureAPIError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Capture.self, from: data)
    }
}
