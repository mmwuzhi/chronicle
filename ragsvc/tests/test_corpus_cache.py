"""Hermetic tests for the in-process corpus cache (rag._snapshot & friends).

No Postgres: the DB loader (_rows / all_fragments) is monkeypatched with a call
counter so we can assert exactly when a reload happens. Covers cache hit, TTL
expiry, explicit invalidation, model-change invalidation, LRU eviction, the
TTL=0 disable switch, and matrix memoisation.
"""
import numpy as np
import pytest

import rag


def _rows(n, model="bge-m3", dim=4):
    """n canned corpus rows, one chunk each, whose embedding is a `dim`-float32
    vector tagged with `model` so _snapshot_chunks will place it."""
    out = []
    for i in range(n):
        vec = np.full(dim, float(i + 1), dtype=np.float32)
        out.append({
            "id": str(i), "content": f"c{i}",
            "created_at": "2026-01-01T00:00:00", "metadata": None,
            "modality": "text", "chunks": [vec.tobytes()], "chunk_texts": [f"c{i}"],
            "model": model, "source_hash": None,
        })
    return out


@pytest.fixture(autouse=True)
def _reset_cache(monkeypatch):
    """Every test starts with an empty cache, embeddings on, a real TTL, and a
    fixed active model (bge-m3, dim 4 in these fixtures)."""
    rag._corpus_cache.clear()
    monkeypatch.setattr(rag, "EMBED_ENABLED", True)
    monkeypatch.setattr(rag, "CORPUS_CACHE_TTL", 60.0)
    monkeypatch.setattr(rag, "CORPUS_CACHE_MAX_USERS", 32)
    monkeypatch.setattr(rag, "active_embed_model", lambda: "bge-m3")


def _spy_loader(monkeypatch, rows=None):
    """Patch the embeddings-on loader to count calls; returns the counter dict."""
    calls = {"n": 0}
    data = rows if rows is not None else _rows(3)

    def fake_rows(user_id):
        calls["n"] += 1
        return list(data)  # a fresh list each load, like the real query

    monkeypatch.setattr(rag, "_rows", fake_rows)
    return calls


def test_hit_reuses_without_reloading(monkeypatch):
    calls = _spy_loader(monkeypatch)
    a = rag.search_corpus("u1")
    b = rag.search_corpus("u1")
    assert calls["n"] == 1          # loaded once
    assert a is b                   # same cached rows object


def test_separate_users_load_separately(monkeypatch):
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    rag.search_corpus("u2")
    assert calls["n"] == 2


def test_invalidate_forces_reload(monkeypatch):
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    rag.invalidate_corpus("u1")
    rag.search_corpus("u1")
    assert calls["n"] == 2


def test_ttl_expiry_reloads(monkeypatch):
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    # Age the snapshot past the TTL (deterministic — no sleep).
    rag._corpus_cache["u1"].built_at -= rag.CORPUS_CACHE_TTL + 1
    rag.search_corpus("u1")
    assert calls["n"] == 2


def test_model_change_invalidates(monkeypatch):
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    monkeypatch.setattr(rag, "active_embed_model", lambda: "text-embedding-3-small")
    rag.search_corpus("u1")
    assert calls["n"] == 2          # different vector space → rebuild


def test_lru_evicts_least_recently_used(monkeypatch):
    monkeypatch.setattr(rag, "CORPUS_CACHE_MAX_USERS", 2)
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    rag.search_corpus("u2")
    rag.search_corpus("u1")          # u1 now most-recently used
    rag.search_corpus("u3")          # evicts u2 (LRU), not u1
    assert "u2" not in rag._corpus_cache
    assert "u1" in rag._corpus_cache and "u3" in rag._corpus_cache
    rag.search_corpus("u1")          # still cached → no reload
    assert calls["n"] == 3           # u1, u2, u3 (u1's re-read was a hit)


def test_ttl_zero_disables_cache(monkeypatch):
    monkeypatch.setattr(rag, "CORPUS_CACHE_TTL", 0.0)
    calls = _spy_loader(monkeypatch)
    rag.search_corpus("u1")
    rag.search_corpus("u1")
    assert calls["n"] == 2           # every call reloads
    assert rag._corpus_cache == {}   # nothing cached


def test_chunk_matrix_memoised_on_snapshot(monkeypatch):
    _spy_loader(monkeypatch)
    snap = rag._snapshot("u1")
    m1, _, _ = rag._snapshot_chunks(snap, 4)
    m2, _, _ = rag._snapshot_chunks(snap, 4)
    assert m1 is m2                  # memoised on the snapshot, not rebuilt
    assert snap.chunk_mat is m1
    assert m1.shape == (3, 4)        # 3 captures × 1 chunk each, dim 4


def test_chunk_matrix_rebuilds_on_dim_change(monkeypatch):
    _spy_loader(monkeypatch, rows=_rows(2, dim=4))
    snap = rag._snapshot("u1")
    m4, _, _ = rag._snapshot_chunks(snap, 4)
    m8, _, _ = rag._snapshot_chunks(snap, 8)   # query vector dim changed
    assert m4.shape == (2, 4)
    assert m8.shape == (0, 8)        # dim-4 chunks don't fit dim 8 → none placed
