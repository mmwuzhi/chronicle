import Foundation

// On-device embeddings for offline-first semantic search. The desktop calls a
// locally-running Ollama (no auth, localhost only) to embed captures and queries,
// so search can rank by meaning without logging in or reaching the server. The
// same bge-m3 model the API's RAG sidecar uses, so local and server hits speak
// one vector space. Any failure (Ollama not running, model missing) throws, and
// callers degrade to keyword substring search — semantic recall is a bonus layer,
// never a hard dependency.

public enum LocalEmbedderError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case emptyEmbedding
}

// One embedding row from Ollama's /api/embed (newer batch endpoint: `embeddings`
// is an array of vectors, one per input). We always send a single string.
struct OllamaEmbedResponse: Decodable {
    let embeddings: [[Float]]
}

public final class LocalEmbedder: @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!
    public static let defaultModel = "bge-m3"

    private let baseURL: URL
    public let model: String
    private let session: URLSession

    public init(
        baseURL: URL = LocalEmbedder.defaultBaseURL,
        model: String = LocalEmbedder.defaultModel,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    // Local calls never go through a proxy, mirroring the server's ollama client
    // (trust_env=False): a system HTTP proxy must not intercept loopback traffic.
    public func makeEmbedRequest(_ text: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "input": text])
        return request
    }

    public func embed(_ text: String) async throws -> [Float] {
        let request = try makeEmbedRequest(text)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalEmbedderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalEmbedderError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(OllamaEmbedResponse.self, from: data)
        guard let vector = decoded.embeddings.first, !vector.isEmpty else {
            throw LocalEmbedderError.emptyEmbedding
        }
        return vector
    }
}

// MARK: - Vector math (pure, unit-testable)

// Cosine similarity. Zero-magnitude vectors score 0 (a capture with no embedding
// never spuriously matches). Dimension mismatch also scores 0 — a stale vector
// from a different model must not pollute ranking.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
}

// Rank candidates by cosine against the query vector, keeping only those at or
// above `floor` (a low gate that keeps obvious non-matches out without trying to
// be the precision judge — the user still reads the rows). Highest score first.
public func rankByCosine<ID>(
    query: [Float],
    candidates: [(id: ID, vector: [Float])],
    limit: Int,
    floor: Float = 0.3
) -> [(id: ID, score: Float)] {
    candidates
        .map { (id: $0.id, score: cosineSimilarity(query, $0.vector)) }
        .filter { $0.score >= floor }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
}
