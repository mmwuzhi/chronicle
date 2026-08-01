"""Hermetic tests for the cloud rerank backend (`api`).

No network, no Postgres: urllib is monkeypatched. Covers the wire contract
(right endpoint, index→score remapping back to candidate order) and the
fail-safe (unconfigured/error → None → caller falls back to vector ordering).
"""
import json

import app
import search as search_svc


def test_rerank_api_posts_and_maps_scores(monkeypatch):
    # rerank=api → POST {model,query,documents} to {base}/rerank, then map each
    # result back to its candidate by `index`.
    monkeypatch.setenv("RERANK_BASE_URL", "https://r.example/v1")
    monkeypatch.setenv("RERANK_API_KEY", "rk-x")
    monkeypatch.setenv("RERANK_MODEL_API", "rerank-test")
    captured = {}

    class FakeResp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"results":[{"index":1,"relevance_score":0.9},{"index":0,"relevance_score":0.2}]}'

    def fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data)
        captured["auth"] = req.headers.get("Authorization")
        return FakeResp()

    monkeypatch.setattr(search_svc.urllib.request, "urlopen", fake_urlopen)
    scores = search_svc._rerank_api("q", [{"content": "a"}, {"content": "b"}])
    assert scores == [0.2, 0.9]  # index 0→0.2, index 1→0.9, back in candidate order
    assert captured["url"] == "https://r.example/v1/rerank"
    assert captured["body"]["model"] == "rerank-test"
    assert captured["body"]["documents"] == ["a", "b"]
    assert captured["auth"] == "Bearer rk-x"


def test_rerank_api_accepts_data_key(monkeypatch):
    # Some vendors return `data` instead of `results`; both are accepted.
    monkeypatch.setenv("RERANK_BASE_URL", "https://r.example/v1")
    monkeypatch.setenv("RERANK_API_KEY", "rk-x")

    class FakeResp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"data":[{"index":0,"relevance_score":0.7}]}'

    monkeypatch.setattr(search_svc.urllib.request, "urlopen",
                        lambda req, timeout=None: FakeResp())
    assert search_svc._rerank_api("q", [{"content": "x"}]) == [0.7]


def test_rerank_api_unconfigured_returns_none(monkeypatch):
    # No endpoint/key → None (fall back to vector ordering, never crash search).
    monkeypatch.delenv("RERANK_BASE_URL", raising=False)
    monkeypatch.delenv("RERANK_API_KEY", raising=False)
    assert search_svc._rerank_api("q", [{"content": "x"}]) is None
    assert search_svc.rerank_api_ok() is False


def test_rerank_api_failure_returns_none(monkeypatch):
    # A transport/parse error must degrade to None, not propagate.
    monkeypatch.setenv("RERANK_BASE_URL", "https://r.example/v1")
    monkeypatch.setenv("RERANK_API_KEY", "rk-x")

    def boom(req, timeout=None):
        raise RuntimeError("network down")

    monkeypatch.setattr(search_svc.urllib.request, "urlopen", boom)
    assert search_svc._rerank_api("q", [{"content": "x"}]) is None


def test_rerank_api_ok_reflects_env(monkeypatch):
    monkeypatch.setenv("RERANK_BASE_URL", "https://r.example/v1")
    monkeypatch.setenv("RERANK_API_KEY", "rk-x")
    assert search_svc.rerank_api_ok() is True


def test_api_is_an_accepted_backend():
    # The PATCH /config validator must accept the new `api` backend.
    assert "api" in app._RERANK_BACKENDS


def test_invalidate_endpoint_drops_only_requested_user(monkeypatch):
    seen = []
    monkeypatch.setattr(app.rag, "invalidate_corpus", seen.append)

    assert app.invalidate(user_id="user-123") == {"status": "invalidated"}
    assert seen == ["user-123"]


def test_backfill_continues_after_one_capture_fails(monkeypatch):
    attempted = []

    monkeypatch.setattr(app.rag, "needs_index", lambda _uid: ["poison", "healthy"])
    monkeypatch.setattr(app.rag, "orphaned_derived", lambda _uid: [])
    monkeypatch.setattr(app.rag, "invalidate_corpus", lambda _uid: None)
    monkeypatch.setattr(app.extract, "backfill", lambda _uid: 0)

    def index_capture(capture_id, _user_id):
        attempted.append(capture_id)
        if capture_id == "poison":
            raise RuntimeError("bad capture")
        return True

    monkeypatch.setattr(app.rag, "index_capture", index_capture)

    result = app.backfill("user-123")

    assert attempted == ["poison", "healthy"]
    assert result == {
        "users": 1,
        "embedded": 1,
        "extracted": 0,
        "cleared": 0,
        "failures": 1,
    }
