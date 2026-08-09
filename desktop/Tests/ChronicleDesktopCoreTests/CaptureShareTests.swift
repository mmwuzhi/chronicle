import Foundation
import Testing

@testable import ChronicleDesktopCore

private let shareTestConfig = ChronicleConfig(
    apiURL: URL(string: "https://api.chronicle.example/v1")!,
    token: "share-test-token"
)

@Test
func shareListRequestUsesBearerAuthentication() {
    let request = CaptureShareAPIClient(config: shareTestConfig).makeListRequest(
        cursor: "next page",
        limit: 25,
        captureID: "capture-1"
    )

    #expect(
        request.url?.absoluteString
            == "https://api.chronicle.example/v1/shares?captureId=capture-1&cursor=next%20page&limit=25"
    )
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer share-test-token")
}

@Test
func shareCreateRequestCarriesCaptureAndExpiry() throws {
    let request = try CaptureShareAPIClient(config: shareTestConfig)
        .makeCreateRequest(
            captureID: "capture-1",
            expiresIn: .thirtyDays,
            snapshotRawText: "Owner-approved preview"
        )

    #expect(
        request.url?.absoluteString
            == "https://api.chronicle.example/v1/captures/capture-1/shares"
    )
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer share-test-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode([String: String].self, from: body)
    #expect(decoded == [
        "expiresIn": "30d",
        "snapshotRawText": "Owner-approved preview",
    ])
}

@Test
func shareRevokeRequestUsesOwnerEndpoint() {
    let request = CaptureShareAPIClient(config: shareTestConfig)
        .makeRevokeRequest(id: "share-1")

    #expect(request.url?.absoluteString == "https://api.chronicle.example/v1/shares/share-1")
    #expect(request.httpMethod == "DELETE")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer share-test-token")
}

@Test
func captureShareDecodesCanonicalURLAndExpiry() throws {
    let data = Data(
        """
        {
          "id":"share-1",
          "captureId":"capture-1",
          "snapshotRawText":"private snapshot made public",
          "capturedAt":"2026-08-09T10:00:00Z",
          "expiresAt":"2026-08-16T10:00:00Z",
          "createdAt":"2026-08-09T11:00:00Z",
          "secret":"secret-1",
          "url":"https://chronicle.example/s/share-1#secret-1"
        }
        """.utf8
    )

    let share = try JSONDecoder().decode(CaptureShare.self, from: data)
    let beforeExpiry = try #require(
        ISO8601DateFormatter().date(from: "2026-08-16T09:59:59Z")
    )
    let afterExpiry = try #require(
        ISO8601DateFormatter().date(from: "2026-08-16T10:00:01Z")
    )

    #expect(share.captureId == "capture-1")
    #expect(share.url == "https://chronicle.example/s/share-1#secret-1")
    #expect(!share.isExpired(at: beforeExpiry))
    #expect(share.isExpired(at: afterExpiry))
}
