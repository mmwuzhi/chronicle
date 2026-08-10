"""PostgreSQL persistence for the Chronicle RAG sidecar.

This module owns SQL and row decoding. ``rag.py`` remains the compatibility
facade and retrieval orchestrator, so callers can keep importing ``rag`` while
storage changes stay isolated here.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import os

from psycopg.types.json import Json
from psycopg_pool import ConnectionPool

# Indexed content includes both a typed note and its transcript when present.
CONTENT_SQL = "trim(both ' ' from concat_ws(' ', NULLIF(c.raw_text, ''), NULLIF(c.transcript, '')))"

_POOL: ConnectionPool | None = None


def pool() -> ConnectionPool:
    """Lazily open the shared Postgres connection pool.

    Read DATABASE_URL here, not at module import time: rag.py loads the local
    .env after importing this module, before the first database operation.
    """
    global _POOL
    if _POOL is None:
        database_url = os.getenv("DATABASE_URL", "")
        if not database_url:
            raise RuntimeError("DATABASE_URL is not set")
        _POOL = ConnectionPool(database_url, min_size=1, max_size=8, open=True)
    return _POOL


def iso_datetime(value: dt.datetime) -> str:
    """TIMESTAMPTZ to local-time ISO string, aligned with date bucketing."""
    return value.astimezone().isoformat(timespec="seconds")


def content_hash(content: str) -> str:
    """Fingerprint used only for derived-data staleness detection."""
    return hashlib.md5(content.encode("utf-8")).hexdigest()


def clear_derived(capture_id: str) -> None:
    with pool().connection() as conn:
        conn.execute("DELETE FROM capture_embeddings WHERE capture_id = %s", (capture_id,))
        conn.execute("DELETE FROM capture_metadata WHERE capture_id = %s", (capture_id,))


def get_content(capture_id: str, user_id: str) -> str | None:
    with pool().connection() as conn:
        row = conn.execute(
            f"SELECT {CONTENT_SQL} FROM captures c "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
    return (row[0] or "") if row is not None else None


def replace_embeddings_if_content_matches(
    capture_id: str,
    user_id: str,
    expected_content: str,
    vectors: list[bytes],
    chunks: list[str],
    model: str,
    embed_v: int,
    source_hash: str,
) -> bool:
    """Atomically replace one capture's embedding chunks if content is unchanged."""
    with pool().connection() as conn:
        current = conn.execute(
            f"SELECT {CONTENT_SQL} FROM captures c "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
        if current is None or (current[0] or "").strip() != expected_content:
            return False
        conn.execute(
            "DELETE FROM capture_embeddings WHERE capture_id = %s",
            (capture_id,),
        )
        conn.cursor().executemany(
            "INSERT INTO capture_embeddings "
            "(capture_id, user_id, chunk_idx, embedding, chunk_text, model, "
            "embed_v, source_hash, updated_at) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())",
            [
                (
                    capture_id,
                    user_id,
                    index,
                    vector,
                    chunk,
                    model,
                    embed_v,
                    source_hash,
                )
                for index, (vector, chunk) in enumerate(zip(vectors, chunks))
            ],
        )
    return True


def load_rows(user_id: str) -> list[dict]:
    """Load captures plus aligned embedding chunks for one user."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.created_at, "
            "       m.data, c.media_type::text, "
            "       array_agg(e.embedding ORDER BY e.chunk_idx) "
            "         FILTER (WHERE e.embedding IS NOT NULL) AS embeddings, "
            "       array_agg(e.chunk_text ORDER BY e.chunk_idx) "
            "         FILTER (WHERE e.embedding IS NOT NULL) AS chunk_texts, "
            "       max(e.model) AS model, max(e.source_hash) AS source_hash "
            "FROM captures c "
            "LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "LEFT JOIN capture_embeddings e ON e.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            "GROUP BY c.id, m.data",
            (user_id,),
        ).fetchall()
    return [
        {
            "id": row[0],
            "content": row[1] or "",
            "created_at": iso_datetime(row[2]),
            "metadata": row[3],
            "modality": row[4],
            "chunks": [bytes(value) for value in (row[5] or [])],
            "chunk_texts": list(row[6] or []),
            "model": row[7],
            "source_hash": row[8],
        }
        for row in rows
    ]


def load_fragments(user_id: str) -> list[dict]:
    """Load the embedding-free corpus used by lexical-only retrieval."""
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.created_at, "
            "       m.data, c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL",
            (user_id,),
        ).fetchall()
    return [
        {
            "id": row[0],
            "content": row[1] or "",
            "created_at": iso_datetime(row[2]),
            "metadata": row[3],
            "modality": row[4],
        }
        for row in rows
    ]


def recent(user_id: str, limit: int, offset: int) -> list[dict]:
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.created_at, m.data, "
            "       c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            "ORDER BY c.created_at DESC, c.id DESC LIMIT %s OFFSET %s",
            (user_id, limit, offset),
        ).fetchall()
    return [
        {
            "id": row[0],
            "content": row[1] or "",
            "created_at": iso_datetime(row[2]),
            "metadata": row[3],
            "modality": row[4],
        }
        for row in rows
    ]


def on_date(
    user_id: str, date: str, limit: int, excluded_ids: set[str] | None = None,
) -> list[dict]:
    day = dt.date.fromisoformat(date)
    local_tz = dt.datetime.now().astimezone().tzinfo
    lo = dt.datetime.combine(day, dt.time.min, local_tz)
    hi = lo + dt.timedelta(days=1)
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.created_at, c.media_type::text "
            "FROM captures c "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            "AND NOT (c.id = ANY(%s::uuid[])) "
            "AND c.created_at >= %s AND c.created_at < %s "
            "ORDER BY c.created_at DESC, c.id DESC LIMIT %s",
            (user_id, list(excluded_ids or set()), lo, hi, limit),
        ).fetchall()
    return [
        {
            "id": row[0],
            "content": row[1] or "",
            "created_at": iso_datetime(row[2]),
            "modality": row[3],
            "score": 1.0,
            "lexical": False,
        }
        for row in rows
    ]


def update_metadata(capture_id: str, user_id: str, meta: dict, content: str) -> None:
    with pool().connection() as conn:
        current = conn.execute(
            f"SELECT {CONTENT_SQL} FROM captures c "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL",
            (capture_id, user_id),
        ).fetchone()
        if current is None or (current[0] or "") != content:
            return
        conn.execute(
            "INSERT INTO capture_metadata "
            "(capture_id, user_id, data, extract_v, source_hash, updated_at) "
            "VALUES (%s, %s, %s, %s, %s, now()) "
            "ON CONFLICT (capture_id) DO UPDATE SET "
            "data = EXCLUDED.data, extract_v = EXCLUDED.extract_v, "
            "source_hash = EXCLUDED.source_hash, updated_at = now()",
            (
                capture_id,
                user_id,
                Json(meta),
                int(meta.get("extract_v", 0)),
                content_hash(content),
            ),
        )


def needs_extract(user_id: str, current_version: int) -> list[dict]:
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.media_type::text "
            "FROM captures c LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            f"AND {CONTENT_SQL} <> '' "
            "AND (m.capture_id IS NULL OR COALESCE(m.extract_v, 0) < %s "
            f"     OR m.source_hash IS DISTINCT FROM md5({CONTENT_SQL})) "
            "ORDER BY c.created_at",
            (user_id, current_version),
        ).fetchall()
    return [
        {"id": row[0], "content": row[1] or "", "modality": row[2]}
        for row in rows
    ]


def needs_index(user_id: str, model: str, embed_v: int) -> list[str]:
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text FROM captures c "
            "WHERE c.user_id = %s AND c.deleted_at IS NULL "
            f"AND {CONTENT_SQL} <> '' "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM capture_embeddings e "
            "  WHERE e.capture_id = c.id AND e.model = %s "
            f"    AND e.source_hash = md5({CONTENT_SQL}) AND e.embed_v >= %s) "
            "ORDER BY c.created_at",
            (user_id, model, embed_v),
        ).fetchall()
    return [row[0] for row in rows]


def orphaned_derived(user_id: str) -> list[str]:
    with pool().connection() as conn:
        rows = conn.execute(
            f"SELECT c.id::text FROM captures c "
            "WHERE c.user_id = %s "
            f"AND {CONTENT_SQL} = '' "
            "AND (EXISTS (SELECT 1 FROM capture_embeddings e WHERE e.capture_id = c.id) "
            "  OR EXISTS (SELECT 1 FROM capture_metadata m WHERE m.capture_id = c.id))",
            (user_id,),
        ).fetchall()
    return [row[0] for row in rows]


def all_user_ids() -> list[str]:
    with pool().connection() as conn:
        rows = conn.execute("SELECT id::text FROM users").fetchall()
    return [row[0] for row in rows]


def config_get(key: str) -> str | None:
    with pool().connection() as conn:
        row = conn.execute(
            "SELECT value FROM rag_config WHERE key = %s", (key,)
        ).fetchone()
    return row[0] if row else None


def config_set(key: str, value: str) -> None:
    with pool().connection() as conn:
        conn.execute(
            "INSERT INTO rag_config (key, value) VALUES (%s, %s) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            (key, value),
        )


def webhooks_enabled(user_id: str) -> list[dict]:
    with pool().connection() as conn:
        rows = conn.execute(
            "SELECT id::text, name, target_url, keywords, semantic_query, "
            "semantic_threshold, payload_template FROM capture_webhooks "
            "WHERE user_id = %s AND enabled = true AND deleted_at IS NULL",
            (user_id,),
        ).fetchall()
    return [
        {
            "id": row[0],
            "name": row[1],
            "target_url": row[2],
            "keywords": list(row[3] or []),
            "semantic_query": row[4],
            "semantic_threshold": float(row[5]),
            "payload_template": row[6],
        }
        for row in rows
    ]


def get_fragment(capture_id: str, user_id: str) -> dict | None:
    with pool().connection() as conn:
        row = conn.execute(
            f"SELECT c.id::text, {CONTENT_SQL} AS content, c.created_at, "
            "       array_agg(e.embedding ORDER BY e.chunk_idx) "
            "         FILTER (WHERE e.embedding IS NOT NULL) AS embeddings, m.data "
            "FROM captures c "
            "LEFT JOIN capture_embeddings e ON e.capture_id = c.id "
            "LEFT JOIN capture_metadata m ON m.capture_id = c.id "
            "WHERE c.id = %s AND c.user_id = %s AND c.deleted_at IS NULL "
            "GROUP BY c.id, m.data",
            (capture_id, user_id),
        ).fetchone()
    if row is None:
        return None
    return {
        "id": row[0],
        "content": row[1] or "",
        "created_at": iso_datetime(row[2]) if row[2] else None,
        "embeddings": [bytes(value) for value in (row[3] or [])],
        "metadata": row[4],
    }
