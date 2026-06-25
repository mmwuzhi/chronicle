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

import datetime as dt
import hashlib
import json
import os
import unicodedata
import urllib.request
from dataclasses import dataclass

import numpy as np
import ollama
from dotenv import load_dotenv
from psycopg.types.json import Json
from psycopg_pool import ConnectionPool

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL", "")
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

_POOL: ConnectionPool | None = None


def pool() -> ConnectionPool:
    """Lazily open a shared connection pool to the same Postgres as the Go API."""
    global _POOL
    if _POOL is None:
        if not DATABASE_URL:
            raise RuntimeError("DATABASE_URL is not set")
        _POOL = ConnectionPool(DATABASE_URL, min_size=1, max_size=8, open=True)
    return _POOL


# Indexed content = the user's note (raw_text) AND the transcript, both when
# present — a voice capture can carry a typed note plus its transcription, and the
# old keyword search matched either, so indexing only one would silently hide the
# other. concat_ws skips NULLs; NULLIF('') drops empty fields; trim cleans the
# seam. Empty string only when the capture has no text at all (media-only).
_CONTENT = "trim(both ' ' from concat_ws(' ', NULLIF(c.raw_text, ''), NULLIF(c.transcript, '')))"


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


def embed(text: str, model: str) -> np.ndarray:
    """Embed text. Default ollama (local); openai = any OpenAI-compatible
    /v1/embeddings endpoint (BYOK, no local model install). Switching backend
    changes dimension/vector space — the corpus must be re-embedded (backfill)."""
    if EMBED_BACKEND == "openai":
        return _embed_openai(text)
    return _embed_ollama(text, model)


def _embed_ollama(text: str, model: str) -> np.ndarray:
    """Local Ollama embedding.

    trust_env=False: a corporate proxy's HTTP_PROXY would otherwise hijack the
    localhost call to Ollama. Local calls never go through a proxy."""
    client = ollama.Client(host=OLLAMA_BASE_URL, trust_env=False)
    resp = client.embeddings(model=model, prompt=text[:4096])
    return np.array(resp["embedding"], dtype=np.float32)


def _embed_openai(text: str) -> np.ndarray:
    """OpenAI-compatible /v1/embeddings (hand-rolled HTTP, zero SDK — same seam
    discipline as the claude -p call). base/key default to the shared OPENAI_*
    config; EMBED_* overrides exist for when the embedding endpoint is a
    different provider than the chat endpoint."""
    base = (os.getenv("EMBED_BASE_URL") or os.getenv("OPENAI_BASE_URL")
            or "https://api.openai.com/v1").rstrip("/")
    key = os.getenv("EMBED_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
    if not key:
        raise RuntimeError("embedding API key not configured (EMBED_API_KEY/OPENAI_API_KEY)")
    body = json.dumps({"input": text[:8000], "model": EMBED_MODEL_OPENAI}).encode()
    req = urllib.request.Request(
        f"{base}/embeddings", data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    return np.array(data["data"][0]["embedding"], dtype=np.float32)


def _iso(value: dt.datetime) -> str:
    """TIMESTAMPTZ → local-time ISO string (seconds). Local so that date
    bucketing (on_date, time-window questions in dates.py) lines up with the
    user's local 'today', not UTC."""
    return value.astimezone().isoformat(timespec="seconds")


def _md5(content: str) -> str:
    """Content fingerprint for staleness detection. md5 (not security-sensitive,
    just change detection) so Postgres can compute the same hash inline with its
    built-in md5() — letting backfill find rows whose stored hash no longer
    matches the current capture text."""
    return hashlib.md5(content.encode("utf-8")).hexdigest()


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
    with pool().connection() as conn:
        conn.execute("DELETE FROM capture_embeddings WHERE capture_id = %s", (capture_id,))
        conn.execute("DELETE FROM capture_metadata WHERE capture_id = %s", (capture_id,))


def index_capture(capture_id: str, user_id: str) -> bool:
    """Compute and upsert the embedding for one capture. Returns True if an
    embedding was written, False otherwise (embeddings disabled, capture gone, no
    indexable text, or the text changed under us).

    Idempotent and safe under concurrent re-index of the same capture: embed()
    runs on the content we read, then a short write transaction re-reads the
    current content and only commits if it still matches. So when two quick edits
    fire two index tasks, a slow older task whose text is now stale aborts instead
    of overwriting the newer embedding."""
    if not EMBED_ENABLED:
        return False
    content = get_content(capture_id, user_id)
    if content is None:
        return False
    content = content.strip()
    if not content:
        return False

    model = active_embed_model()
    vec = embed(content, MODEL_BGE).astype(np.float32).tobytes()
    with pool().connection() as conn:
        cur = conn.execute(
            f"SELECT {_CONTENT} FROM captures c WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
        if cur is None:
            return False
        current = cur[0] or ""
        if current.strip() != content:
            return False  # content moved on; the newer index task owns this row
        conn.execute(
            "INSERT INTO capture_embeddings (capture_id, user_id, embedding, model, embed_v, source_hash, updated_at) "
            "VALUES (%s, %s, %s, %s, 1, %s, now()) "
            "ON CONFLICT (capture_id) DO UPDATE SET "
            "embedding = EXCLUDED.embedding, model = EXCLUDED.model, "
            "embed_v = EXCLUDED.embed_v, source_hash = EXCLUDED.source_hash, updated_at = now()",
            (capture_id, user_id, vec, model, _md5(current)),
        )
    return True


def get_content(capture_id: str, user_id: str) -> str | None:
    """The indexable text of one capture (transcript or raw_text), or None if the
    capture doesn't exist / isn't this user's. Empty string means media-only."""
    with pool().connection() as conn:
        row = conn.execute(
            f"SELECT {_CONTENT} FROM captures c "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
    return (row[0] or "") if row is not None else None


def _rows(user_id: str) -> list[dict]:
    """All indexable captures for a user, joined with extracted metadata + the
    raw embedding bytes and the model that produced it."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.created_at, "
            "       m.data, c.media_type::text, e.embedding, e.model "
            "FROM captures c "
            "LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "LEFT JOIN capture_embeddings e ON e.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL",
            (user_id,),
        ).fetchall()
    return [{"id": r[0], "content": r[1] or "", "created_at": _iso(r[2]),
             "metadata": r[3], "modality": r[4],
             "embedding": bytes(r[5]) if r[5] is not None else None,
             "model": r[6]}
            for r in rows]


def _load_for_search(user_id: str, dim: int) -> tuple[list[dict], np.ndarray]:
    """Load all rows + a vector matrix sized to `dim` (the current query vector's
    dimension). Only embeddings from the *active* model are placed; rows from a
    previous embedding model stay zero — they score cosine 0 until backfill
    re-embeds them. Matching dimension alone is not enough: two models can emit
    same-dim vectors in incompatible spaces, which would produce meaningless cosine
    rankings, so we require both the active model name and the exact dimension.
    Sizing to the query's dim guarantees the matrix multiply never shape-mismatches
    during a model change."""
    rows = _rows(user_id)
    active = active_embed_model()
    metas = [{"id": r["id"], "content": r["content"], "created_at": r["created_at"],
              "metadata": r["metadata"], "modality": r["modality"]} for r in rows]
    mat = np.zeros((len(rows), dim), dtype=np.float32)
    for i, r in enumerate(rows):
        if r["embedding"] and r["model"] == active and len(r["embedding"]) // 4 == dim:
            mat[i] = np.frombuffer(r["embedding"], dtype=np.float32)
    return metas, mat


def _cosines(mat: np.ndarray, qv: np.ndarray) -> np.ndarray:
    """Exact cosine similarity (full scan). Zero-vector rows score 0."""
    if mat.size == 0:
        return np.zeros(0, dtype=np.float32)
    qn = qv / (np.linalg.norm(qv) or 1.0)
    norms = np.linalg.norm(mat, axis=1)
    norms[norms == 0] = 1.0
    return (mat @ qn) / norms


def recent(user_id: str, limit: int = 50, offset: int = 0) -> list[Fragment]:
    """Most recent captures, newest first (id tiebreak for same-second stability)."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.created_at, m.data, "
            "       c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            "ORDER BY c.created_at DESC, c.id DESC LIMIT %s OFFSET %s",
            (user_id, limit, offset),
        ).fetchall()
    return [Fragment(r[0], r[1] or "", _iso(r[2]), r[3], r[4]) for r in rows]


def neighbors(user_id: str, query: str, limit: int = 20) -> list[Fragment]:
    """Semantic nearest neighbours, for assembling the query-time cluster. Empty
    when embeddings are disabled — the cluster then leans on recent ∪ BM25 ∪ the
    time-window slice instead."""
    if not EMBED_ENABLED:
        return []
    qv = embed(query, MODEL_BGE)
    metas, mat = _load_for_search(user_id, len(qv))
    sims = _cosines(mat, qv)
    order = np.argsort(-sims)[:limit]
    return [Fragment(metas[i]["id"], metas[i]["content"], metas[i]["created_at"],
                     metas[i]["metadata"], metas[i]["modality"])
            for i in order]


def related(user_id: str, capture_id: str, limit: int = 10) -> list[dict]:
    """Semantic neighbours of ONE capture, for the 'Related' surface. Embeds the
    capture's own indexable text and cosine-scans the user's other captures,
    excluding the capture itself. Returns dicts shaped like /find items (no
    embedding bytes). Empty — never an error — when embeddings are disabled or the
    capture has no indexable text (media-only / missing); the UI just shows no
    suggestions."""
    if not EMBED_ENABLED:
        return []
    content = get_content(capture_id, user_id)
    if not content or not content.strip():
        return []
    qv = embed(content, MODEL_BGE)
    metas, mat = _load_for_search(user_id, len(qv))
    sims = _cosines(mat, qv)
    out: list[dict] = []
    for i in np.argsort(-sims):
        if metas[i]["id"] == capture_id:
            continue
        # Rows with no active-model embedding stay zero vectors (backfill pending,
        # model changed, media-only, embed failed) and score exactly 0; stop before
        # them so they never fill the list with non-semantic suggestions. argsort is
        # descending, so everything past the first non-positive score is also junk.
        if sims[i] <= 0:
            break
        out.append({"id": metas[i]["id"], "content": metas[i]["content"],
                    "created_at": metas[i]["created_at"],
                    "modality": metas[i]["modality"], "score": float(sims[i])})
        if len(out) >= limit:
            break
    return out


# Vector floor for wide recall (a fallback only; literal hits ignore it).
# Final relevance is decided by the reranker.
CANDIDATE_FLOOR = float(os.getenv("CANDIDATE_FLOOR", "0.3"))


def candidates(user_id: str, query: str, k: int = 30) -> list[dict]:
    """Wide recall: literal substring hits ∪ vector top-k (low floor), for rerank.
    Zero-content captures are kept out of vector recall (unstable noise); literal
    hits are exempt. With embeddings disabled there is no vector channel, so this
    returns literal hits only — BM25 (added in search()) supplies the rest."""
    q = query.lower()
    if not EMBED_ENABLED:
        rows = all_fragments(user_id)
        pool_ = [{"id": f["id"], "content": f["content"], "created_at": f["created_at"],
                  "modality": f["modality"], "lexical": True, "vscore": 0.0}
                 for f in rows if q in f["content"].lower()]
        pool_.sort(key=lambda c: c["created_at"], reverse=True)
        return pool_[:k]

    qv = embed(query, MODEL_BGE)
    metas, mat = _load_for_search(user_id, len(qv))
    sims = _cosines(mat, qv)

    pool_: list[dict] = []
    for m, sim in zip(metas, sims):
        lex = q in m["content"].lower()
        if lex or (float(sim) >= CANDIDATE_FLOOR and _content_chars(m["content"]) > 0):
            pool_.append({"id": m["id"], "content": m["content"],
                          "created_at": m["created_at"], "modality": m["modality"],
                          "lexical": lex, "vscore": float(sim)})
    pool_.sort(key=lambda c: (not c["lexical"], -c["vscore"]))
    return pool_[:k]


def all_fragments(user_id: str) -> list[dict]:
    """All captures (for building the BM25 document set / time-window slice).

    Text-only — never SELECTs the embedding BYTEA, which this path discards. (The
    vector matrix is loaded separately by _load_for_search only when needed.) This
    matters at scale: pulling every embedding here would move tens of MB per call,
    sometimes several times per search."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.created_at, "
            "       m.data, c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL",
            (user_id,),
        ).fetchall()
    return [{"id": r[0], "content": r[1] or "", "created_at": _iso(r[2]),
             "metadata": r[3], "modality": r[4]} for r in rows]


def on_date(user_id: str, d: str, limit: int = 50) -> list[dict]:
    """Captures on a given local day (YYYY-MM-DD), newest first.

    Bounds are computed in the process's local timezone (the same one _iso and
    dates.parse_range use) and queried as a half-open timestamptz range, so date
    bucketing is correct regardless of the Postgres session timezone."""
    day = dt.date.fromisoformat(d)
    local_tz = dt.datetime.now().astimezone().tzinfo
    lo = dt.datetime.combine(day, dt.time.min, local_tz)
    hi = lo + dt.timedelta(days=1)
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.created_at, c.media_type::text "
            "FROM captures c "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            "AND c.created_at >= %s AND c.created_at < %s "
            "ORDER BY c.created_at DESC, c.id DESC LIMIT %s",
            (user_id, lo, hi, limit),
        ).fetchall()
    return [{"id": r[0], "content": r[1] or "", "created_at": _iso(r[2]),
             "modality": r[3], "score": 1.0, "lexical": False} for r in rows]


def update_metadata(capture_id: str, user_id: str, meta: dict, content: str) -> None:
    """Overwrite a capture's extracted metadata (extraction layer). source_hash is
    the fingerprint of the content the metadata was extracted from, so backfill
    can detect when an edit has invalidated it.

    Guards against overlapping extraction jobs the same way index_capture guards
    embeddings: re-read the current content and only write if it still matches the
    text this metadata was extracted from — so a slow older job can't recreate
    stale facts after a newer edit (or a clear) moved on."""
    with pool().connection() as conn:
        cur = conn.execute(
            f"SELECT {_CONTENT} FROM captures c WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
        if cur is None or (cur[0] or "") != content:
            return  # content moved on; the newer extraction job owns this row
        conn.execute(
            "INSERT INTO capture_metadata (capture_id, user_id, data, extract_v, source_hash, updated_at) "
            "VALUES (%s, %s, %s, %s, %s, now()) "
            "ON CONFLICT (capture_id) DO UPDATE SET "
            "data = EXCLUDED.data, extract_v = EXCLUDED.extract_v, "
            "source_hash = EXCLUDED.source_hash, updated_at = now()",
            (capture_id, user_id, Json(meta), int(meta.get("extract_v", 0)), _md5(content)),
        )


def needs_extract(user_id: str, current_version: int) -> list[dict]:
    """Captures needing (re-)extraction: no metadata, an older extract version, or
    metadata whose source_hash no longer matches the current content (edited while
    the sidecar was down). The hash check is what stops stale facts lingering."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            f"AND {_CONTENT} <> '' "
            "AND (m.capture_id IS NULL OR COALESCE(m.extract_v, 0) < %s "
            f"     OR m.source_hash IS DISTINCT FROM md5({_CONTENT})) "
            "ORDER BY c.created_at",
            (user_id, current_version),
        ).fetchall()
    return [{"id": r[0], "content": r[1] or "", "modality": r[2]} for r in rows]


def needs_index(user_id: str) -> list[str]:
    """Capture ids whose embedding is missing, stale (source_hash no longer matches
    the current content — e.g. edited while the sidecar was down), or produced by a
    different embedding model. Drives backfill self-heal + model-change reindex.
    Empty when embeddings are disabled (nothing to embed)."""
    if not EMBED_ENABLED:
        return []
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text FROM captures c "
            "LEFT JOIN capture_embeddings e ON e.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            f"AND {_CONTENT} <> '' "
            "AND (e.capture_id IS NULL OR e.model <> %s "
            f"     OR e.source_hash IS DISTINCT FROM md5({_CONTENT})) "
            "ORDER BY c.created_at",
            (user_id, active_embed_model()),
        ).fetchall()
    return [r[0] for r in rows]


def orphaned_derived(user_id: str) -> list[str]:
    """Capture ids whose text is now empty but which still have an embedding or
    metadata row — e.g. content was cleared while the sidecar was down, so the
    clear-on-edit never ran. Backfill clears these so deleted facts don't linger
    in search / Ask context. (needs_index/needs_extract skip empty captures, so
    this is the path that catches them.)"""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text FROM captures c "
            "WHERE c.user_id = %s "
            f"AND {_CONTENT} = '' "
            "AND (EXISTS (SELECT 1 FROM capture_embeddings e WHERE e.capture_id = c.id) "
            "  OR EXISTS (SELECT 1 FROM capture_metadata m WHERE m.capture_id = c.id))",
            (user_id,),
        ).fetchall()
    return [r[0] for r in rows]


def all_user_ids() -> list[str]:
    """Every user id (backfill iterates per user since retrieval is per user)."""
    with pool().connection() as conn:
        rows = conn.execute("SELECT id::text FROM users").fetchall()
    return [r[0] for r in rows]


# ── runtime config (global rag_config key/value) ──

def config_get(key: str) -> str | None:
    with pool().connection() as conn:
        r = conn.execute("SELECT value FROM rag_config WHERE key = %s", (key,)).fetchone()
    return r[0] if r else None


def config_set(key: str, value: str) -> None:
    with pool().connection() as conn:
        conn.execute(
            "INSERT INTO rag_config (key, value) VALUES (%s, %s) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            (key, value),
        )


# ── webhooks (event-driven outbound; Go owns the capture_webhooks table CRUD) ──


def webhooks_enabled(user_id: str) -> list[dict]:
    """Enabled, non-deleted webhook rules for one user. Go owns this table and
    its CRUD API; the sidecar only reads rules here to match + deliver."""
    with pool().connection() as conn:
        rows = conn.execute(
            "SELECT id::text, name, target_url, keywords, semantic_query, "
            "semantic_threshold, payload_template FROM capture_webhooks "
            "WHERE user_id = %s AND enabled = true AND deleted_at IS NULL",
            (user_id,),
        ).fetchall()
    return [{"id": r[0], "name": r[1], "target_url": r[2],
             "keywords": list(r[3] or []), "semantic_query": r[4],
             "semantic_threshold": float(r[5]), "payload_template": r[6]}
            for r in rows]


def get_fragment(capture_id: str, user_id: str) -> dict | None:
    """One capture's content + embedding + extracted metadata, for webhook
    matching and template rendering. None if the capture isn't this user's."""
    with pool().connection() as conn:
        row = conn.execute(
            f"SELECT c.id::text, {_CONTENT} AS content, c.created_at, "
            "e.embedding, m.data "
            "FROM captures c "
            "LEFT JOIN capture_embeddings e ON e.capture_id = c.id "
            "LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
    if row is None:
        return None
    return {
        "id": row[0],
        "content": row[1] or "",
        "created_at": _iso(row[2]) if row[2] else None,
        "embedding": bytes(row[3]) if row[3] is not None else None,
        "metadata": row[4],
    }
