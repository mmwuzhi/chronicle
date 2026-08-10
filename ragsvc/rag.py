#!/usr/bin/env python3
"""Storage + retrieval core for the Chronicle RAG sidecar.

Port of the rag project's rag.py, with the persistence layer rewritten from
stdlib SQLite to Chronicle's PostgreSQL. The retrieval *philosophy* is
unchanged: embeddings are stored as float32 byte blobs (BYTEA) and retrieval is
an exact numpy cosine full-scan over a single user's rows — at personal scale
(<tens of thousands of captures per user) this is sub-50ms and avoids the recall
loss of approximate indexes. pgvector is the documented scale-up trigger.

Differences from the rag original, all driven by Chronicle's schema:
  - ids are capture UUIDs (strings), not autoincrement ints.
  - every query is scoped by user_id (Chronicle is multi-user; the Go gateway
    passes a trusted user_id — this service has no auth of its own).
  - the indexed "content" of a capture is its transcript (audio, filled by
    Chronicle's Whisper pipeline) or else its raw_text. Media-only captures with
    no text are simply un-indexable until text arrives (mirrors rag's [图片]
    placeholder behaviour).
  - embeddings/extracted metadata live in side tables (capture_embeddings,
    capture_metadata) keyed by capture_id; captures itself is owned by Go.
"""
from __future__ import annotations

import os
import threading
import time
import unicodedata
from collections import OrderedDict
from dataclasses import dataclass

import numpy as np
from dotenv import load_dotenv

import corpus
import embedding
import repository

load_dotenv()

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
MODEL_BGE = os.getenv("EMBED_MODEL_BGE", "bge-m3")

# Embedding backend: ollama (local, default) or openai (any OpenAI-compatible
# /v1/embeddings endpoint, BYOK). The openai path is what lets semantic search
# run with NO local model install — it reuses Chronicle's existing OPENAI_* key
# (the one the Whisper transcription path already uses). Switching backend
# changes the vector space / dimension, so the whole corpus must be re-embedded;
# active_embed_model() makes the model name change with the backend, which is
# what drives needs_index → backfill to rebuild automatically.
EMBED_BACKEND = os.getenv("EMBED_BACKEND", "ollama")
EMBED_MODEL_OPENAI = os.getenv("EMBED_MODEL_OPENAI", "text-embedding-3-small")

# Embeddings need a real embedding model (Ollama/sentence-transformers); a chat
# agent (claude/codex CLI) cannot produce vectors. Default OFF so the service
# runs with no model install at all — retrieval falls back to BM25 + literal +
# (optional) agent rerank, and Ask clusters from recent ∪ BM25 ∪ time-window
# rather than semantic neighbours. Set EMBED_ENABLED=true (with Ollama running)
# to re-light the semantic vector channel.
EMBED_ENABLED = os.getenv("EMBED_ENABLED", "false").lower() == "true"

# In-process corpus cache. Every /find and /ask reloads a user's whole corpus
# (content + embedding BYTEA) from Postgres and rebuilds the numpy matrix per
# request; at personal scale the cosine math is cheap but that reload + decode is
# the real per-search cost. We cache the decoded snapshot per user in this single
# uvicorn process (no --workers, so one shared cache is coherent). Freshness is
# kept two ways: writes that go through this process invalidate immediately
# (_index_one, backfill), and a short TTL bounds staleness from writes the Go API
# makes without telling us (soft-delete / restore). CORPUS_CACHE_TTL=0 disables
# caching entirely (every call reloads — the pre-cache behaviour, for rollback).
CORPUS_CACHE_TTL = float(os.getenv("CORPUS_CACHE_TTL", "60"))
# LRU bound: one entry per active user. 1 for a personal deployment; capped so a
# multi-user host can never grow the cache without limit (each entry is
# rows + an N×dim float32 matrix).
CORPUS_CACHE_MAX_USERS = int(os.getenv("CORPUS_CACHE_MAX_USERS", "32"))

# Chunked embeddings: long content is split into overlapping character windows,
# each embedded on its own, so a long capture is findable by any of its parts
# rather than through one averaged whole-document vector. Short content is a
# single chunk (identical to the pre-chunking behaviour). CHUNK_CHARS is a rough
# few-hundred-token budget; bge-m3 and the OpenAI embeddings both handle
# multilingual text, so we split by characters — no tokenizer/segmenter
# dependency, the same discipline bm25 uses for CJK.
CHUNK_CHARS = int(os.getenv("CHUNK_CHARS", "1200"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "180"))
# Embedding format version stored on every row: 1 = pre-chunking single vector,
# 2 = chunked. needs_index treats anything below EMBED_V as stale, so one
# backfill re-chunks the corpus after migration 027.
EMBED_V = 2

# Same function-word / particle set as the rag project: text made only of these
# (a query or a capture) carries no alignable topic, so its rerank score is pure
# noise. Heuristic and conservative — content chars (花/钱/累/饿/疲/劳/饭…) are
# never listed; better to under-block than over-block.
_STOPCHARS = set(
    "我你他她它们咱"
    "的了吗呢吧啊呀哦噢嗯哎唉欸喂"
    "是有在和与跟也都就还又"
    "好说讲想觉得要会能"
    "这那哪些个么什怎样"
    "はをがのにへともでやかねよ"
)

# Indexed content = the user's note (raw_text) AND the transcript, both when
# present — a voice capture can carry a typed note plus its transcription, and the
# old keyword search matched either, so indexing only one would silently hide the
# other. concat_ws skips NULLs; NULLIF('') drops empty fields; trim cleans the
# seam. Empty string only when the capture has no text at all (media-only).
def _content_chars(text: str) -> int:
    """Count of "content chars": excludes whitespace, punctuation/symbols, and
    function words. Zero = no topical information. Query side uses it to gate
    intent-free queries; capture side uses it to keep zero-information captures
    out of fuzzy recall."""
    n = 0
    for ch in text:
        if ch.isspace() or ch in _STOPCHARS:
            continue
        if unicodedata.category(ch)[0] in ("P", "S"):
            continue
        n += 1
    return n


def active_embed_model() -> str:
    """The model name of the *active* embedding backend. Stored on each embedding
    row and compared by needs_index, so switching backend (ollama bge-m3 →
    openai text-embedding-3-small) changes the name and makes backfill rebuild
    the whole corpus into the new vector space."""
    return EMBED_MODEL_OPENAI if EMBED_BACKEND == "openai" else MODEL_BGE


def embed(text: str) -> np.ndarray:
    """Embed text with the active backend's model (active_embed_model).
    Default ollama (local); openai = any OpenAI-compatible /v1/embeddings
    endpoint (BYOK, no local model install). Switching backend changes
    dimension/vector space — the corpus must be re-embedded (backfill)."""
    if EMBED_BACKEND == "openai":
        return _embed_openai(text)
    return _embed_ollama(text)


def _embed_ollama(text: str) -> np.ndarray:
    """Local Ollama embedding."""
    return embedding.ollama_embed(text, MODEL_BGE, OLLAMA_BASE_URL)


def _embed_openai(text: str) -> np.ndarray:
    """OpenAI-compatible /v1/embeddings (hand-rolled HTTP, zero SDK — same seam
    discipline as the claude -p call). base/key default to the shared OPENAI_*
    config; EMBED_* overrides exist for when the embedding endpoint is a
    different provider than the chat endpoint."""
    return embedding.openai_embed(text, EMBED_MODEL_OPENAI)


@dataclass
class Fragment:
    id: str               # capture UUID
    content: str
    created_at: str       # local ISO string
    metadata: dict | None = None
    modality: str = "text"


def clear_derived(capture_id: str) -> None:
    """Drop a capture's derived embedding + metadata (used when its text is
    cleared, so removed facts don't linger in search / Ask context)."""
    repository.clear_derived(capture_id)


def chunk_content(text: str) -> list[str]:
    """Split indexable content into overlapping character windows for embedding.
    Content that fits one window is returned whole — the common case, since most
    captures are short, so this is a single chunk exactly as before chunking. The
    overlap keeps a phrase straddling a window boundary recoverable from at least
    one chunk. Deterministic; the unit of retrieval, not display."""
    return embedding.chunk_content(text, CHUNK_CHARS, CHUNK_OVERLAP)


def index_capture(capture_id: str, user_id: str) -> bool:
    """Compute and store the chunked embeddings for one capture. Returns True if
    chunks were written, False otherwise (embeddings disabled, capture gone, no
    indexable text, or the text changed under us).

    Idempotent and safe under concurrent re-index of the same capture: embed()
    runs on the content we read, then a short write transaction re-reads the
    current content and only replaces the chunk set if it still matches. So when
    two quick edits fire two index tasks, a slow older task whose text is now
    stale aborts instead of overwriting the newer embedding. The whole chunk set
    is replaced (delete + insert) rather than upserted because the chunk count
    can change between edits."""
    if not EMBED_ENABLED:
        return False
    content = get_content(capture_id, user_id)
    if content is None:
        return False
    content = content.strip()
    if not content:
        return False

    model = active_embed_model()
    source_hash = repository.content_hash(content)
    chunks = chunk_content(content)
    # Embed outside the write transaction — the model round-trips are the slow
    # part and must not hold a row lock. The re-read below guards staleness.
    vecs = [embed(ch).astype(np.float32).tobytes() for ch in chunks]
    return repository.replace_embeddings_if_content_matches(
        capture_id,
        user_id,
        content,
        vecs,
        chunks,
        model,
        EMBED_V,
        source_hash,
    )


def get_content(capture_id: str, user_id: str) -> str | None:
    """The indexable text of one capture (transcript or raw_text), or None if the
    capture doesn't exist / isn't this user's. Empty string means media-only."""
    return repository.get_content(capture_id, user_id)


def _rows(user_id: str) -> list[dict]:
    """All indexable captures for a user, joined with extracted metadata and their
    chunk embeddings aggregated into per-capture arrays (ordered by chunk_idx).
    `chunks` and `chunk_texts` are aligned — both filtered by embedding presence —
    so a pre-chunking row (embed_v=1, chunk_text NULL) still contributes its one
    vector with a None text. model / source_hash are identical across a capture's
    chunks (index_capture writes them together), so max() collapses each to that
    single value; a capture with no embedding yet gets empty arrays and NULLs."""
    return repository.load_rows(user_id)


_Snapshot = corpus.Snapshot


_corpus_cache: "OrderedDict[str, _Snapshot]" = OrderedDict()
_corpus_lock = threading.Lock()


def _fresh_snapshot(user_id: str) -> _Snapshot:
    """Load a user's corpus from Postgres. With embeddings on this is _rows (the
    vector channel needs the bytes); off, the embedding-free all_fragments."""
    rows = _rows(user_id) if EMBED_ENABLED else all_fragments(user_id)
    return _Snapshot(rows=rows, model=active_embed_model(), built_at=time.monotonic())


def _snapshot(user_id: str) -> _Snapshot:
    """The user's corpus snapshot, from cache when fresh (same model, within TTL)
    else freshly loaded. TTL<=0 disables caching (always reload). The DB load runs
    outside the lock — a concurrent builder just loads twice and the later write
    wins, which is wasted work, never corruption."""
    if CORPUS_CACHE_TTL <= 0:
        return _fresh_snapshot(user_id)
    now = time.monotonic()
    with _corpus_lock:
        snap = _corpus_cache.get(user_id)
        if (snap is not None and snap.model == active_embed_model()
                and now - snap.built_at <= CORPUS_CACHE_TTL):
            _corpus_cache.move_to_end(user_id)
            return snap
    snap = _fresh_snapshot(user_id)
    with _corpus_lock:
        _corpus_cache[user_id] = snap
        _corpus_cache.move_to_end(user_id)
        while len(_corpus_cache) > CORPUS_CACHE_MAX_USERS:
            _corpus_cache.popitem(last=False)  # evict least-recently-used
    return snap


def invalidate_corpus(user_id: str) -> None:
    """Drop a user's cached snapshot so the next recall reloads. Called after any
    write to their embeddings/content that this process makes (index, clear,
    backfill); the TTL covers writes the Go API makes on its own."""
    with _corpus_lock:
        _corpus_cache.pop(user_id, None)


def search_corpus(user_id: str) -> list[dict]:
    """The rows of a user's cached corpus, shared by every recall channel of a
    single request (BM25, time-window, and — via the same snapshot — the vector
    channel). See _snapshot for the caching + freshness contract."""
    return _snapshot(user_id).rows


def _snapshot_chunks(snap: _Snapshot, dim: int):
    """Flatten every capture's active-model chunk vectors into one matrix, with an
    aligned owner array (matrix row → index into snap.rows) and chunk-text list.
    Built once per query dimension and memoised on the snapshot. Only chunks from
    the active model at the query's dimension are placed — a stale-model or
    wrong-dim chunk sits in an incompatible vector space, so it is skipped and its
    capture simply scores 0 until backfill re-embeds it (same guard the old
    per-row matrix applied). Returns (matrix, owner, texts)."""
    return corpus.snapshot_chunks(snap, dim, active_embed_model())


def _capture_max_sims(snap: _Snapshot, qv: np.ndarray):
    """Per-capture vector score = the max cosine over that capture's chunks, plus
    the text of that best chunk (handed to the reranker so it scores the matched
    fragment, not a long document's truncated opening). Both are aligned to
    snap.rows; a capture with no active-model chunk scores 0 with None text."""
    return corpus.capture_max_sims(snap, qv, active_embed_model())


def _cosines(mat: np.ndarray, qv: np.ndarray) -> np.ndarray:
    """Exact cosine similarity (full scan). Zero-vector rows score 0."""
    return corpus.cosines(mat, qv)


def recent(user_id: str, limit: int = 50, offset: int = 0) -> list[Fragment]:
    """Most recent captures, newest first (id tiebreak for same-second stability)."""
    rows = repository.recent(user_id, limit, offset)
    return [
        Fragment(
            row["id"],
            row["content"],
            row["created_at"],
            row["metadata"],
            row["modality"],
        )
        for row in rows
    ]


def neighbors(user_id: str, query: str, limit: int = 20) -> list[Fragment]:
    """Semantic nearest neighbours, for assembling the query-time cluster. Empty
    when embeddings are disabled — the cluster then leans on recent ∪ BM25 ∪ the
    time-window slice instead. Reads the cached corpus snapshot (shared with the
    caller's own search_corpus load in the same request)."""
    if not EMBED_ENABLED:
        return []
    snap = _snapshot(user_id)
    metas = snap.rows
    best, _ = _capture_max_sims(snap, embed(query))
    # Skip zero-score captures (no active-model embedding yet — backfill pending or
    # model changed): they would otherwise be pulled into the cluster as bogus
    # neighbours, polluting Ask answers. argsort is descending, so stop at the
    # first non-positive score. Same filter related() applies.
    order: list[int] = []
    for i in np.argsort(-best):
        if best[i] <= 0:
            break
        order.append(i)
        if len(order) >= limit:
            break
    return [Fragment(metas[i]["id"], metas[i]["content"], metas[i]["created_at"],
                     metas[i]["metadata"], metas[i]["modality"])
            for i in order]


def _stored_query_vec(row: dict) -> np.ndarray | None:
    """A capture's own query vector rebuilt from its stored chunks: the
    normalised mean of its active-model chunk vectors — for the common
    single-chunk capture that is exactly the stored vector, i.e. the same
    embedding a fresh embed of the content would produce. None when nothing
    usable is stored (no chunks yet, stale model, mixed dims) — the caller
    falls back to a fresh embed."""
    if row.get("model") != active_embed_model():
        return None
    chunks = row.get("chunks") or []
    if not chunks:
        return None
    vecs = [np.frombuffer(b, dtype=np.float32) for b in chunks]
    dim = len(vecs[0])
    if dim == 0 or any(len(v) != dim for v in vecs):
        return None
    if len(vecs) == 1:
        return vecs[0]
    mat = np.vstack(vecs)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return (mat / norms).mean(axis=0)


def related_candidates(
    user_id: str, capture_id: str, limit: int = 30,
    excluded_ids: set[str] | None = None,
) -> tuple[str, list[dict]]:
    """Wide semantic candidates for ONE capture's Related surface: score the
    user's other captures against this capture's meaning (max cosine over their
    chunks), excluding the capture itself. Search owns the precision threshold
    and optional rerank stage; this function only supplies the wide vector pool
    and anchor text. The query vector is rebuilt from the
    capture's own stored chunk vectors (_stored_query_vec), so opening Related
    normally costs no embed round-trip; a fresh full-content embed is the
    fallback when nothing usable is stored (just created, model switched,
    backfill pending). Returns dicts shaped like /find items. Empty — never an
    error — when embeddings are disabled or the capture has no indexable text
    (media-only / missing)."""
    if not EMBED_ENABLED:
        return "", []
    snap = _snapshot(user_id)
    metas = snap.rows
    own = next((r for r in metas if r["id"] == capture_id), None)
    if own is None or not own["content"].strip():
        return "", []
    qv = _stored_query_vec(own)
    if qv is None:
        qv = embed(own["content"])
    best, best_text = _capture_max_sims(snap, qv)
    out: list[dict] = []
    excluded = excluded_ids or set()
    for i in np.argsort(-best):
        if metas[i]["id"] == capture_id or metas[i]["id"] in excluded:
            continue
        # Zero-score captures (no active-model embedding: backfill pending, model
        # changed, media-only, embed failed) sort last; stop before them so they
        # never fill the list with non-semantic suggestions. argsort is descending,
        # so everything past the first non-positive score is also junk.
        if best[i] <= 0:
            break
        out.append({"id": metas[i]["id"], "content": metas[i]["content"],
                    "created_at": metas[i]["created_at"],
                    "modality": metas[i]["modality"], "score": float(best[i]),
                    "vscore": float(best[i]), "lexical": False,
                    "rerank_text": best_text[i] or metas[i]["content"]})
        if len(out) >= limit:
            break
    return own["content"], out


# Vector floor for wide recall (a fallback only; literal hits ignore it).
# Final relevance is decided by the reranker.
CANDIDATE_FLOOR = float(os.getenv("CANDIDATE_FLOOR", "0.3"))


def candidates(
    user_id: str, query: str, k: int = 30,
    excluded_ids: set[str] | None = None,
) -> list[dict]:
    """Wide recall: literal substring hits ∪ vector top-k (low floor), for rerank.
    Zero-content captures are kept out of vector recall (unstable noise); literal
    hits are exempt. With embeddings disabled there is no vector channel, so this
    returns literal hits only — BM25 (added in search()) supplies the rest. Reads
    the cached corpus snapshot (shared with the caller's own search_corpus load in
    the same request). A capture's vector score is the max cosine over its chunks,
    and rerank_text carries the best-matching chunk so the reranker scores the
    matched fragment rather than a long document's truncated opening."""
    q = query.lower()
    excluded = excluded_ids or set()
    snap = _snapshot(user_id)
    if not EMBED_ENABLED:
        pool_ = [{"id": f["id"], "content": f["content"], "created_at": f["created_at"],
                  "modality": f["modality"], "lexical": True, "vscore": 0.0,
                  "rerank_text": f["content"]}
                 for f in snap.rows
                 if f["id"] not in excluded and q in f["content"].lower()]
        pool_.sort(key=lambda c: c["created_at"], reverse=True)
        return pool_[:k]

    best, best_text = _capture_max_sims(snap, embed(query))
    pool_: list[dict] = []
    for i, m in enumerate(snap.rows):
        if m["id"] in excluded:
            continue
        lex = q in m["content"].lower()
        sim = float(best[i])
        if lex or (sim >= CANDIDATE_FLOOR and _content_chars(m["content"]) > 0):
            pool_.append({"id": m["id"], "content": m["content"],
                          "created_at": m["created_at"], "modality": m["modality"],
                          "lexical": lex, "vscore": sim,
                          "rerank_text": best_text[i] or m["content"]})
    pool_.sort(key=lambda c: (not c["lexical"], -c["vscore"]))
    return pool_[:k]


def all_fragments(user_id: str) -> list[dict]:
    """All captures (for building the BM25 document set / time-window slice)
    with embeddings disabled — search_corpus routes here so that path never
    SELECTs the embedding BYTEA it would discard. With embeddings on, the one
    shared _rows load (which does carry the vectors) serves every channel."""
    return repository.load_fragments(user_id)


def on_date(
    user_id: str, d: str, limit: int = 50,
    excluded_ids: set[str] | None = None,
) -> list[dict]:
    """Captures on a given local day (YYYY-MM-DD), newest first.

    Bounds are computed in the process's local timezone (the same one repository
    timestamp formatting and dates.parse_range use) and queried as a half-open
    timestamptz range, so date bucketing is correct regardless of the Postgres
    session timezone."""
    return repository.on_date(user_id, d, limit, excluded_ids)


def update_metadata(capture_id: str, user_id: str, meta: dict, content: str) -> None:
    """Overwrite a capture's extracted metadata (extraction layer). source_hash is
    the fingerprint of the content the metadata was extracted from, so backfill
    can detect when an edit has invalidated it.

    Guards against overlapping extraction jobs the same way index_capture guards
    embeddings: re-read the current content and only write if it still matches the
    text this metadata was extracted from — so a slow older job can't recreate
    stale facts after a newer edit (or a clear) moved on."""
    repository.update_metadata(capture_id, user_id, meta, content)


def needs_extract(user_id: str, current_version: int) -> list[dict]:
    """Captures needing (re-)extraction: no metadata, an older extract version, or
    metadata whose source_hash no longer matches the current content (edited while
    the sidecar was down). The hash check is what stops stale facts lingering."""
    return repository.needs_extract(user_id, current_version)


def needs_index(user_id: str) -> list[str]:
    """Capture ids whose embedding is missing, stale (source_hash no longer matches
    the current content — e.g. edited while the sidecar was down), produced by a
    different embedding model, or still in the pre-chunking format (embed_v <
    EMBED_V). Drives backfill self-heal, model-change reindex, and the one-time
    re-chunk after migration 027. A capture is up to date iff it has at least one
    chunk that is current on all three axes, so NOT EXISTS of such a chunk means it
    needs indexing — and returns one id per capture (no per-chunk duplication).
    Empty when embeddings are disabled (nothing to embed)."""
    if not EMBED_ENABLED:
        return []
    return repository.needs_index(user_id, active_embed_model(), EMBED_V)


def orphaned_derived(user_id: str) -> list[str]:
    """Capture ids whose text is now empty but which still have an embedding or
    metadata row — e.g. content was cleared while the sidecar was down, so the
    clear-on-edit never ran. Backfill clears these so deleted facts don't linger
    in search / Ask context. (needs_index/needs_extract skip empty captures, so
    this is the path that catches them.)"""
    return repository.orphaned_derived(user_id)


def all_user_ids() -> list[str]:
    """Every user id (backfill iterates per user since retrieval is per user)."""
    return repository.all_user_ids()


# ── runtime config (global rag_config key/value) ──

def config_get(key: str) -> str | None:
    return repository.config_get(key)


def config_set(key: str, value: str) -> None:
    repository.config_set(key, value)


# ── webhooks (event-driven outbound; Go owns the capture_webhooks table CRUD) ──


def webhooks_enabled(user_id: str) -> list[dict]:
    """Enabled, non-deleted webhook rules for one user. Go owns this table and
    its CRUD API; the sidecar only reads rules here to match + deliver."""
    return repository.webhooks_enabled(user_id)


def get_fragment(capture_id: str, user_id: str) -> dict | None:
    """One capture's content + chunk embeddings + extracted metadata, for webhook
    matching and template rendering. `embeddings` is the list of the capture's
    chunk vectors (empty if unembedded); matches() takes the max cosine over them.
    None if the capture isn't this user's."""
    return repository.get_fragment(capture_id, user_id)
