import AppKit
import ChronicleDesktopCore
import Foundation
import Network

enum GoogleDriveConfiguration {
    static func clientID(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        let raw = environment["CHRONICLE_GOOGLE_DRIVE_CLIENT_ID"]
            ?? bundle.object(forInfoDictionaryKey: "ChronicleGoogleDriveClientID") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class GoogleDriveAuthorizer {
    private let session: URLSession
    private var cachedToken: (value: String, expiresAt: Date)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func invalidate() {
        cachedToken = nil
    }

    func authorize(clientID: String) async throws -> String {
        if let cachedToken, cachedToken.expiresAt > Date().addingTimeInterval(30) {
            return cachedToken.value
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let port = try await start(listener)
        defer { listener.cancel() }

        let redirectURI = "http://127.0.0.1:\(port)/oauth/callback"
        let state = UUID().uuidString
        let pkce = DesktopOAuthPKCE.generate()
        let url = try GoogleDriveOAuth.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        )
        guard NSWorkspace.shared.open(url) else {
            throw GoogleDriveError.authorizationFailed
        }
        let code = try await receiveCode(
            listener: listener,
            expectedPath: "/oauth/callback",
            expectedState: state
        )
        let request = GoogleDriveOAuth.tokenRequest(
            clientID: clientID,
            redirectURI: redirectURI,
            code: code,
            codeVerifier: pkce.verifier
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let token = try? JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data),
              !token.accessToken.isEmpty
        else {
            throw GoogleDriveError.authorizationFailed
        }
        cachedToken = (
            token.accessToken,
            Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
        )
        return token.accessToken
    }

    private func start(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        gate.resume(returning: port)
                    } else {
                        gate.resume(throwing: GoogleDriveError.authorizationFailed)
                    }
                case .failed:
                    gate.resume(throwing: GoogleDriveError.authorizationFailed)
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func receiveCode(
        listener: NWListener,
        expectedPath: String,
        expectedState: String
    ) async throws -> String {
        let cancellation = ContinuationCancellationRelay<String>()
        let connectedMessage = L("Google Drive is connected. You can return to Chronicle.")
        let failedMessage = L("Chronicle could not connect to Google Drive. You can close this tab.")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate<String>(continuation)
                cancellation.install(gate)
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    Self.receiveHTTPRequest(on: connection) { data in
                        let result = data.map {
                            GoogleDriveOAuthCallback.parse(
                                $0,
                                expectedPath: expectedPath,
                                expectedState: expectedState
                            )
                        } ?? .ignored
                        switch result {
                        case .accepted(let code):
                            Self.respond(connection, accepted: true, message: connectedMessage)
                            gate.resume(returning: code)
                        case .denied:
                            Self.respond(connection, accepted: false, message: failedMessage)
                            gate.resume(throwing: GoogleDriveError.authorizationFailed)
                        case .ignored, .incomplete:
                            // Port scanners, duplicate query keys, wrong state, and
                            // incomplete requests do not get to consume the real
                            // OAuth callback. Keep listening until timeout.
                            Self.respond(connection, accepted: false, message: failedMessage)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    gate.resume(throwing: GoogleDriveError.authorizationFailed)
                }
            }
        } onCancel: {
            listener.cancel()
            cancellation.cancel()
        }
    }

    nonisolated private static func receiveHTTPRequest(
        on connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            data, _, complete, error in
            guard error == nil else {
                completion(nil)
                return
            }
            var next = accumulated
            if let data { next.append(data) }
            guard next.count <= 32 * 1024 else {
                completion(nil)
                return
            }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil || complete {
                completion(next)
                return
            }
            receiveHTTPRequest(on: connection, accumulated: next, completion: completion)
        }
    }

    nonisolated private static func respond(
        _ connection: NWConnection,
        accepted: Bool,
        message: String
    ) {
        let html = "<html><body>\(message)</body></html>"
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

private final class ContinuationCancellationRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: ContinuationGate<Value>?
    private var cancelled = false

    func install(_ gate: ContinuationGate<Value>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            gate.resume(throwing: CancellationError())
            return
        }
        self.gate = gate
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let gate = gate
        self.gate = nil
        lock.unlock()
        gate?.resume(throwing: CancellationError())
    }
}
