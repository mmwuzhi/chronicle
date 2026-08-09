# Chronicle RAG sidecar

This optional Python FastAPI service supplies embeddings, hybrid recall,
related Captures, extraction, and query-time answers. Modules have detailed
docstrings; read them before changing their behavior.

Use `just rag` to run it, `just rag-test` for tests, `just rag-eval` for the
deterministic retrieval gate, and `just rag-backfill` for operator backfill.
Pytest already receives the package root through `pyproject.toml`; the Justfile
entry remains preferred because it selects the project environment consistently.

## HTTP surface

- `/health` and `/warmup`: liveness and backend preheating
- `/index` and `/invalidate`: best-effort derived-data write and per-user cache
  invalidation
- `/find`, `/related`, and `/ask`: ranked recall, semantic neighbours, and
  query-time answer synthesis
- `/backfill` and `/backfill-queue`: synchronous operator repair and bounded,
  deduplicated per-user repair scheduling
- `GET/PATCH /config`: effective reranker configuration and local-backend
  detection

## Module map

- `app.py`: routes and queued/periodic repair workers
- `rag.py`: compatibility facade and retrieval/index orchestration
- `repository.py`: user-scoped PostgreSQL reads and guarded derived writes
- `embedding.py`: Ollama/OpenAI-compatible providers and chunking
- `corpus.py`: decoded per-user corpus snapshots and exact numpy cosine
- `search.py`: info gate, keyword/vector recall, reranking, and thresholding
- `bm25.py`: dependency-free character-bigram keyword recall
- `extract.py`: literal capture-time key/value extraction
- `analysis.py`: completeness-oriented `/ask` context and LLM invocation
- `dates.py`: rule-based relative-date parsing
- `detect.py`: read-only local backend detection
- `webhook.py`: best-effort rule matching and delivery after indexing

Runtime settings and defaults are defined by `.env.example` plus the modules
that read them. Do not copy a second configuration table into this file.

## Trust boundary

The sidecar has no auth of its own. The Go API authenticates the caller and
passes trusted `X-User-Id`; every interactive query and cache mutation is scoped
to that user. Keep the service on localhost/private networking and never add an
interactive endpoint that bypasses user scope. Headerless `/backfill` is an
operator-only all-user path, not a public API.

## Design decisions

- Use exact cosine full-scan, not ANN. Personal corpora are small enough to keep
  full recall; pgvector is the scale-up trigger.
- Cache decoded corpus snapshots in-process per user. Writes through the
  sidecar invalidate immediately; API visibility changes call `/invalidate`;
  TTL bounds external staleness. Zero TTL disables the cache.
- Long content is split into overlapping chunks. Store one embedding per
  `(capture, chunk_idx)`, score a Capture by max-over-chunks, and rerank the best
  chunk. Do not average a long Capture into one vector.
- `/find` layers keyword and vector recall; `/related` is semantic-neighbour
  lookup. Preserve useful empty/degraded behavior when embeddings are disabled.
- Extraction records only facts literally present in the Capture. Never invent
  facts or causation; keys remain open rather than taxonomic.
- `/ask` uses the same completeness-oriented recall for factual and
  interpretive questions. Do not add intent routing or SQL aggregation.
- Indexing is best-effort and repairable. Webhook delivery never blocks it; the
  queued and periodic backfill paths repair missing/stale derived data.
- Date parsing intentionally uses the process-local date for the current
  local-first deployment model.
