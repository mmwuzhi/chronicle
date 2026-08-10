import Foundation

// Offline-first semantic recall over the on-device capture cache. Embeds captures
// (in a background pass) and the live query via a local Ollama, then ranks by
// cosine — no login, no network beyond loopback. Degrades silently: when the
// embedder is unreachable, search returns nil and the caller keeps the keyword
// substring results it already showed, so search never goes dark.
public actor LocalSemanticSearch {
    private let store: LocalCaptureStore
    private let embedder: LocalEmbedder
    private var indexing = false

    // Without a reranker, cosine is the only precision gate. Chronicle prefers
    // fewer, stronger results over a recall-heavy tail of plausible noise.
    private static let recallFloor: Float = 0.55

    public init(store: LocalCaptureStore, embedder: LocalEmbedder) {
        self.store = store
        self.embedder = embedder
    }

    // Rank the query against already-embedded captures. Returns nil when the query
    // itself can't be embedded (Ollama down) so the caller falls back to keyword
    // search; returns [] (a real, empty answer) when the embedder works but nothing
    // clears the floor. Fires a background index pass so newly-added captures
    // become searchable on a later query without blocking this one.
    public func search(_ query: String, limit: Int = 10) async -> [LocalCaptureRecord]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        guard let queryVector = try? await embedder.embed(q) else { return nil }
        Task { await self.ensureIndexed() }

        guard let rows = try? store.embeddedRows(model: embedder.model) else { return [] }
        let ranked = rankByCosine(
            query: queryVector,
            candidates: rows.map { (id: $0.record.id, vector: $0.vector) },
            limit: limit,
            floor: Self.recallFloor,
        )
        let byID = Dictionary(rows.map { ($0.record.id, $0.record) }) { first, _ in first }
        return ranked.compactMap { byID[$0.id] }
    }

    // Embed every capture missing a current-model vector. Idempotent and
    // self-throttling (one pass at a time). Stops at the first embedder failure —
    // Ollama is likely down, so pressing on would just stall on every row.
    public func ensureIndexed() async {
        guard !indexing else { return }
        indexing = true
        defer { indexing = false }

        guard let pending = try? store.rowsNeedingEmbedding(model: embedder.model) else { return }
        for row in pending {
            let text = row.payload.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let vector = try? await embedder.embed(text) else { return }
            try? store.setEmbedding(id: row.id, model: embedder.model, vector: vector)
        }
    }
}
