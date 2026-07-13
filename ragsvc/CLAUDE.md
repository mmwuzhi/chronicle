# Chronicle RAG sidecar — agent notes

Python FastAPI service (uvicorn, `127.0.0.1:5400`, override `RAG_PORT`).
Run with `just rag` (auto-creates `.venv`); tests with `just rag-test` or
`cd ragsvc && python -m pytest` (always `python -m` so top-level imports
resolve). Backfill existing captures with `just rag-backfill`.

Every module has a thorough docstring — read those first; this file is the
map plus the rules that span modules.

## Module map

- `app.py` — HTTP surface: `/health`, `/warmup`, `/index`, `/invalidate`,
  `/find`, `/ask`, `/backfill`, webhook test scoring.
- `rag.py` — storage + retrieval core on Chronicle's PostgreSQL. Embeddings
  are float32 BYTEA blobs, one row per (capture, chunk); retrieval is an exact
  numpy cosine full-scan over one user's chunks, reduced to a per-capture max.
  A user's decoded corpus (rows + chunk matrix) is cached in-process per user
  (`_snapshot`, TTL + explicit invalidation on write) so back-to-back searches
  don't reload and re-decode the whole corpus from Postgres.
- `search.py` — layered recall (L0 info gate → L1 keyword → L2 vector) →
  cross-encoder rerank → calibrated-score threshold; explicit dates route to
  that day. Rerank backend is swappable (`rerank_backend`).
- `bm25.py` — keyword recall: pure-Python BM25 over character bigrams (CJK
  without a segmenter dependency).
- `extract.py` — capture-time open key/value extraction by the local LLM.
- `analysis.py` — `/ask`: assemble the relevant capture cluster, hand it to
  an LLM (`claude -p` by default, local Ollama fallback).
- `dates.py` — relative date words → inclusive range; rule-based,
  CJK-focused; `today` injectable for tests.
- `detect.py` — probe locally available AI backends (claude CLI, Ollama);
  read-only, never raises.
- `webhook.py` — rule matching + delivery at the tail of indexing;
  fire-and-forget.

## Trust boundary

No auth of its own. The Go API authenticates the user and passes a trusted
`X-User-Id`; every query is scoped to that user. The sidecar must only be
reachable from the Go API (localhost / private network). Never add
endpoints that skip the user scoping.

## Design decisions — don't re-litigate

- **Exact cosine full-scan, not ANN.** At personal scale (< tens of
  thousands of captures per user) it's sub-50 ms with zero recall loss.
  pgvector is the documented scale-up trigger, not a current need.
- **Per-user in-process corpus cache, not a warm ANN index.** The scan is
  cheap; the cost was reloading + re-decoding the whole corpus per search.
  A single-process cache (`_snapshot`) fixes that without new infrastructure:
  writes through this process invalidate immediately, a TTL bounds staleness
  from writes the Go API makes on its own. Go-side visibility mutations call
  `/invalidate`; keep that endpoint user-scoped. `CORPUS_CACHE_TTL=0` disables
  the cache.
- **Chunked embeddings, max-over-chunks recall.** Long content (a fetched
  link page, a long transcript) is split into overlapping windows, each
  embedded on its own, so it is findable by any part instead of through one
  averaged whole-document vector. `capture_embeddings` is one row per
  (capture, chunk); a capture's vector score is the max cosine over its
  chunks, and the best chunk's text is what the reranker scores. Short content
  is a single chunk (unchanged). `embed_v` marks the format (2 = chunked); a
  one-time `just rag-backfill` re-chunks the pre-migration-027 corpus.
- **Extraction red line:** only extract facts literally present in the
  capture; never invent, never infer causation. Key names are open — no
  taxonomy.
- **No intent routing, no SQL aggregation in `/ask`.** Factual and
  interpretive questions both go through the same completeness-oriented
  recall; the LLM does arithmetic in place.
- **Indexing must never be blocked by side effects.** A webhook delivery
  failure only logs to stderr.
- **Timezone:** `dates.py` uses the process-local date by design
  (local-first single-user deployment). Threading per-user timezones is
  deferred with the cloud form.
