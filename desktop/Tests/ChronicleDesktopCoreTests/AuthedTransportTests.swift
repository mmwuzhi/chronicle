import Foundation
import Testing

@testable import ChronicleDesktopCore

private final class SessionBoundaryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var receivedAuthorization: [String?] = []

    static func reset() {
        lock.lock()
        receivedAuthorization = []
        lock.unlock()
    }

    static func authorizations() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return receivedAuthorization
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.receivedAuthorization.append(
            request.value(forHTTPHeaderField: "Authorization")
        )
        let requestNumber = Self.receivedAuthorization.count
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: requestNumber == 1 ? 401 : 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AuthedTransportTests {
    @Test
    func staleAccountRequestCannotReplayWithNewAccountToken() async throws {
        let session = makeSession()
        let refresher = AuthRefresher(
            mint: { requestToken in
                #expect(requestToken == "account-a")
                return AuthRefreshResult(token: "account-b", sessionGeneration: 7)
            },
            permitsRetry: { requestToken, refresh in
                #expect(requestToken == "account-a")
                #expect(refresh.token == "account-b")
                #expect(refresh.sessionGeneration == 7)
                return false
            }
        )
        let (_, response) = try await AuthedTransport.send(
            request(token: "account-a"),
            session: session,
            refresher: refresher
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(SessionBoundaryURLProtocol.authorizations() == ["Bearer account-a"])
    }

    @Test
    func currentSessionRefreshRetriesExactlyOnce() async throws {
        let session = makeSession()
        let refresher = AuthRefresher(
            mint: { _ in AuthRefreshResult(token: "account-a-fresh", sessionGeneration: 9) },
            permitsRetry: { _, refresh in refresh.sessionGeneration == 9 }
        )
        let (_, response) = try await AuthedTransport.send(
            request(token: "account-a"),
            session: session,
            refresher: refresher
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(
            SessionBoundaryURLProtocol.authorizations()
                == ["Bearer account-a", "Bearer account-a-fresh"]
        )
    }

    private func makeSession() -> URLSession {
        SessionBoundaryURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionBoundaryURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func request(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chronicle.invalid/captures")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
