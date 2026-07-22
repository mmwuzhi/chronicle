import Foundation

public let googleDriveFileScope = "https://www.googleapis.com/auth/drive.file"
public let googleDriveUploadMaxBytes = 100 * 1024 * 1024

public struct CloudCaptureFileUpload: Equatable, Sendable {
    public let operationId: String
    public let fileURL: URL
    public let sizeBytes: Int
    public let filename: String
    public let mimeType: String

    public init(
        operationId: String,
        fileURL: URL,
        sizeBytes: Int,
        filename: String,
        mimeType: String
    ) {
        self.operationId = operationId
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.filename = filename
        self.mimeType = mimeType
    }
}

public enum GoogleDriveOAuth {
    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: googleDriveFileScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "online"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw GoogleDriveError.invalidResponse }
        return url
    }

    public static func tokenRequest(
        clientID: String,
        redirectURI: String,
        code: String,
        codeVerifier: String
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }
}

public enum GoogleDriveOAuthCallbackResult: Equatable, Sendable {
    case incomplete
    case ignored
    case denied
    case accepted(String)
}

public enum GoogleDriveOAuthCallback {
    public static func parse(
        _ data: Data,
        expectedPath: String,
        expectedState: String
    ) -> GoogleDriveOAuthCallbackResult {
        guard data.count <= 32 * 1024 else { return .ignored }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil else { return .incomplete }
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first
        else {
            return .ignored
        }
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              fields[0] == "GET",
              fields[2].hasPrefix("HTTP/1."),
              let components = URLComponents(string: "http://127.0.0.1\(fields[1])"),
              components.path == expectedPath
        else {
            return .ignored
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return .ignored }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == expectedState else { return .ignored }
        if values["error"] != nil { return .denied }
        guard let code = values["code"], !code.isEmpty else { return .ignored }
        return .accepted(code)
    }
}

public struct GoogleOAuthTokenResponse: Decodable, Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

public final class GoogleDriveClient: @unchecked Sendable {
    private static let apiBase = URL(string: "https://www.googleapis.com/drive/v3")!
    private static let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func upload(
        fileURL: URL,
        sizeBytes: Int,
        filename: String,
        mimeType: String,
        operationId: String,
        accessToken: String
    ) async throws -> CloudAttachmentDraft {
        guard sizeBytes <= googleDriveUploadMaxBytes else {
            throw GoogleDriveError.fileTooLarge
        }
        let folderID = try await chronicleFolder(accessToken: accessToken)
        let uploaded: GoogleDriveFile
        if let existing = try await operationFile(
            operationId: operationId,
            folderID: folderID,
            accessToken: accessToken
        ) {
            uploaded = existing
        } else {
            uploaded = try await createFile(
                fileURL: fileURL,
                sizeBytes: sizeBytes,
                filename: filename,
                mimeType: mimeType,
                operationId: operationId,
                folderID: folderID,
                accessToken: accessToken
            )
        }
        guard let id = uploaded.id else { throw GoogleDriveError.invalidResponse }
        return CloudAttachmentDraft(
            provider: "google_drive",
            providerFileId: id,
            name: uploaded.name ?? filename,
            mimeType: uploaded.mimeType ?? mimeType,
            sizeBytes: uploaded.size.flatMap(Int.init) ?? sizeBytes,
            webUrl: uploaded.webViewLink
                ?? "https://drive.google.com/file/d/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/view"
        )
    }

    private func chronicleFolder(accessToken: String) async throws -> String {
        var components = URLComponents(
            url: Self.apiBase.appending(path: "files"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "mimeType='application/vnd.google-apps.folder' and name='Chronicle' and trashed=false and appProperties has { key='chronicle' and value='true' }"
            ),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let list: GoogleDriveFileList = try await sendJSON(request)
        if let id = list.files.first?.id { return id }

        var create = URLRequest(url: Self.apiBase.appending(path: "files"))
        create.httpMethod = "POST"
        create.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "Chronicle",
            "mimeType": "application/vnd.google-apps.folder",
            "appProperties": ["chronicle": "true"],
        ])
        let folder: GoogleDriveFile = try await sendJSON(create)
        guard let id = folder.id else { throw GoogleDriveError.invalidResponse }
        return id
    }

    private func operationFile(
        operationId: String,
        folderID: String,
        accessToken: String
    ) async throws -> GoogleDriveFile? {
        var components = URLComponents(
            url: Self.apiBase.appending(path: "files"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "'\(folderID)' in parents and trashed=false and appProperties has { key='chronicleOperationId' and value='\(operationId)' }"
            ),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,webViewLink)"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let list: GoogleDriveFileList = try await sendJSON(request)
        return list.files.first
    }

    private func createFile(
        fileURL: URL,
        sizeBytes: Int,
        filename: String,
        mimeType: String,
        operationId: String,
        folderID: String,
        accessToken: String
    ) async throws -> GoogleDriveFile {
        var components = URLComponents(
            url: Self.uploadBase.appending(path: "files"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,name,mimeType,size,webViewLink"),
        ]
        let metadata: [String: Any] = [
            "name": filename,
            "mimeType": mimeType,
            "parents": [folderID],
            "appProperties": [
                "chronicle": "true",
                "chronicleOperationId": operationId,
            ],
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(sizeBytes), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.httpStatus(http.statusCode)
        }
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location)
        else {
            throw GoogleDriveError.invalidResponse
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "PUT"
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        upload.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        let (data, uploadResponse) = try await session.upload(for: upload, fromFile: fileURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }
        guard (200..<300).contains(uploadHTTP.statusCode) else {
            throw GoogleDriveError.httpStatus(uploadHTTP.statusCode)
        }
        return try JSONDecoder().decode(GoogleDriveFile.self, from: data)
    }

    private func sendJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct GoogleDriveFileList: Decodable {
    let files: [GoogleDriveFile]
}

private struct GoogleDriveFile: Decodable {
    let id: String?
    let name: String?
    let mimeType: String?
    let size: String?
    let webViewLink: String?
}

public enum GoogleDriveError: Error, Equatable {
    case notConfigured
    case authorizationFailed
    case fileTooLarge
    case invalidResponse
    case httpStatus(Int)
}
