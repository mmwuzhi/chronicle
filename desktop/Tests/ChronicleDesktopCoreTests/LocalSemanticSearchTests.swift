import Foundation
import Testing

@testable import ChronicleDesktopCore

// MARK: - LocalEmbedder (request + decode, no network — mirrors RecallTests)

@Test
func localEmbedderBuildsPOSTToOllama() throws {
    let embedder = LocalEmbedder(
        baseURL: URL(string: "http://127.0.0.1:11434")!, model: "bge-m3")

    let request = try embedder.makeEmbedRequest("吃面")

    #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/embed")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(json["model"] == "bge-m3")
    #expect(json["input"] == "吃面")
}

@Test
func decodesOllamaEmbedResponse() throws {
    let json = Data(#"{"model":"bge-m3","embeddings":[[0.1,0.2,0.3]]}"#.utf8)

    let decoded = try JSONDecoder().decode(OllamaEmbedResponse.self, from: json)

    #expect(decoded.embeddings.first == [0.1, 0.2, 0.3])
}

// MARK: - Vector math (pure)

@Test
func cosineSimilarityHandlesEdgeCases() {
    #expect(cosineSimilarity([1, 0], [1, 0]) == 1)
    #expect(abs(cosineSimilarity([1, 0], [0, 1])) < 0.0001)   // orthogonal
    #expect(cosineSimilarity([1, 0], [1, 0, 0]) == 0)         // dimension mismatch
    #expect(cosineSimilarity([0, 0], [1, 0]) == 0)            // zero magnitude
    #expect(cosineSimilarity([], []) == 0)
}

@Test
func rankByCosineSortsFiltersAndLimits() {
    let candidates: [(id: String, vector: [Float])] = [
        ("near", [1, 0]),
        ("orthogonal", [0, 1]),
        ("mid", [0.8, 0.6]),
    ]

    let ranked = rankByCosine(query: [1, 0], candidates: candidates, limit: 2, floor: 0.3)

    // orthogonal (score 0) is below the floor; results are highest-first, capped at 2.
    #expect(ranked.map(\.id) == ["near", "mid"])
    #expect(ranked.first?.score == 1)
}

// MARK: - Store vector cache round-trip

@Test
func storeEmbeddingRoundTripsAndFiltersByModel() throws {
    let store = LocalCaptureStore(fileURL: temporarySemanticDBURL(), scope: .testing)
    let alpha = try store.create(CapturePayload(rawText: "alpha"))
    let beta = try store.create(CapturePayload(rawText: "beta"))

    // Both rows need embedding before any vector is written.
    #expect(Set(try store.rowsNeedingEmbedding(model: "bge-m3").map(\.id)) == [alpha.id, beta.id])

    try store.setEmbedding(id: alpha.id, model: "bge-m3", vector: [1, 0, 0])

    // alpha is now indexed under bge-m3; only beta still needs embedding there.
    #expect(try store.rowsNeedingEmbedding(model: "bge-m3").map(\.id) == [beta.id])

    let rows = try store.embeddedRows(model: "bge-m3")
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.record.id == alpha.id)
    #expect(row.vector == [1, 0, 0])

    // A model swap invalidates the cached vector: alpha needs re-embedding under
    // the new model, and the bge-m3 vector is invisible to that model's corpus.
    #expect(Set(try store.rowsNeedingEmbedding(model: "other").map(\.id)) == [alpha.id, beta.id])
    #expect(try store.embeddedRows(model: "other").isEmpty)
}

@Test
func rowsNeedingEmbeddingSkipsEmptyText() throws {
    let store = LocalCaptureStore(fileURL: temporarySemanticDBURL(), scope: .testing)
    _ = try store.create(CapturePayload(rawText: "   ", mediaType: "audio"))

    // A media-only / blank-text capture has nothing to embed.
    #expect(try store.rowsNeedingEmbedding(model: "bge-m3").isEmpty)
}

private func temporarySemanticDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "semantic.sqlite3")
}
