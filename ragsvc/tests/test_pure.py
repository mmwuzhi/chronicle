"""Hermetic tests for the storage-agnostic logic — no Postgres, no Ollama.

Covers the ported retrieval algorithms (BM25, date windows, amount regex, content
gate, cosine) and the Chronicle-specific change: UUID citation remapping.
"""
import datetime as dt
import json

import numpy as np

import analysis
import bm25
import dates
import extract
import rag


def test_bm25_tokenize_ascii_and_cjk():
    assert bm25.tokenize("拉面店") == ["拉面", "面店"]
    assert bm25.tokenize("Android 12") == ["android", "12"]
    assert bm25.tokenize("好") == ["好"]


def test_bm25_ranks_shared_tokens():
    docs = [
        ("a", "今天午饭拉面 1200 日元"),
        ("b", "晚上看了电影"),
        ("c", "拉面真好吃"),
    ]
    ranked = bm25.top_k("拉面 1200", docs, k=3)
    ids = [d for d, _ in ranked]
    assert "a" in ids
    assert ids[0] == "a"  # matches both 拉面 and 1200


def test_dates_relative_windows():
    today = dt.date(2026, 6, 15)  # a Monday
    assert dates.parse_range("今天花了多少", today) == (today, today)
    assert dates.parse_range("上个月吃饭", today) == (dt.date(2026, 5, 1), dt.date(2026, 5, 31))
    assert dates.parse_range("最近3天", today) == (dt.date(2026, 6, 13), today)
    assert dates.parse_range("随便问问", today) is None


def test_dates_english_windows():
    today = dt.date(2026, 6, 15)  # a Monday
    assert dates.parse_range("how much this week", today) == (today, today)
    assert dates.parse_range("spending last month", today) == (
        dt.date(2026, 5, 1),
        dt.date(2026, 5, 31),
    )
    assert dates.parse_range("notes from the last 3 days", today) == (
        dt.date(2026, 6, 13),
        today,
    )
    assert dates.parse_range("today's mood", today) == (today, today)


def test_extract_amount_total_line_priority():
    receipt = "拉面 1180日元\n餐前酒 800日元\n合计 1980日元"
    assert extract.extract_amount(receipt) == (1980, "JPY")
    assert extract.extract_amount("花了100元") == (100, "CNY")
    assert extract.extract_amount("跑了100分钟") == (None, None)  # bare number, no marker


def test_extract_sanitize_drops_junk():
    out = extract._sanitize(
        {"mood": "累", "ok": True, "long": "x" * 40, "n": 5, "extract_v": 9},
        taken={"extract_v"},
    )
    assert out == {"mood": "累", "n": 5}  # bool dropped, overlong dropped, taken dropped


def test_facts_llm_parses_agent_json(monkeypatch):
    # The LLM may wrap the JSON in prose / fences; we pull out the first object.
    monkeypatch.setattr(
        extract.analysis, "llm",
        lambda *a, **k: 'Here you go:\n```json\n{"mood":"累","activity":"加班"}\n```',
    )
    assert extract._facts_llm("加班好累", "claude") == {"mood": "累", "activity": "加班"}


def test_extract_regex_wins_over_agent(monkeypatch):
    # Regex amount is authoritative; the agent cannot overwrite amount/currency.
    monkeypatch.setattr(extract, "EXTRACT_BACKEND", "claude")
    monkeypatch.setattr(
        extract.analysis, "llm",
        lambda *a, **k: '{"merchant":"拉面店","amount":999}',
    )
    out = extract.extract("午饭在拉面店花了1200日元")
    assert out["amount"] == 1200 and out["currency"] == "JPY"
    assert out["merchant"] == "拉面店"
    assert out["extract_v"] == extract.EXTRACT_V


def test_extract_failure_marks_incomplete(monkeypatch):
    # A transient agent failure must keep regex facts but leave extract_v at 0 so
    # backfill retries it later (not record a finished extraction).
    monkeypatch.setattr(extract, "EXTRACT_BACKEND", "claude")

    def boom(*a, **k):
        raise RuntimeError("claude unavailable")

    monkeypatch.setattr(extract.analysis, "llm", boom)
    out = extract.extract("午饭花了1200日元")
    assert out["extract_v"] == 0
    assert out["amount"] == 1200 and out["currency"] == "JPY"


def test_content_chars_gate():
    assert rag._content_chars("我说") == 0      # all function words
    assert rag._content_chars("好了？") == 0     # function word + punctuation
    assert rag._content_chars("拉面") == 2


def test_cosines_zero_vectors_score_zero():
    mat = np.array([[1.0, 0.0], [0.0, 0.0]], dtype=np.float32)
    sims = rag._cosines(mat, np.array([1.0, 0.0], dtype=np.float32))
    assert sims[0] == 1.0
    assert sims[1] == 0.0


def test_renumber_maps_positions_to_uuids():
    cluster = [
        rag.Fragment("11111111-1111-1111-1111-111111111111", "拉面 1200日元", "2026-06-10T12:00:00"),
        rag.Fragment("22222222-2222-2222-2222-222222222222", "晚饭 800日元", "2026-06-11T19:00:00"),
        rag.Fragment("33333333-3333-3333-3333-333333333333", "无关碎片", "2026-06-12T08:00:00"),
    ]
    answer = "你这两天吃饭花了 2000 日元（#1 1200 + #2 800）。"
    new_answer, sources = analysis._renumber(answer, cluster)
    assert "[1]" in new_answer and "[2]" in new_answer
    assert "#1" not in new_answer
    assert [s["id"] for s in sources] == [cluster[0].id, cluster[1].id]
    assert sources[0]["n"] == 1 and sources[1]["n"] == 2


def test_renumber_ignores_out_of_range_citation():
    cluster = [rag.Fragment("aaaa", "x", "2026-06-10T00:00:00")]
    answer = "见 #5 和 #1。"
    new_answer, sources = analysis._renumber(answer, cluster)
    assert "#5" in new_answer       # hallucinated, left as-is
    assert "[1]" in new_answer      # valid, remapped
    assert len(sources) == 1


# ── OpenAI-compatible (api / openai) backend seam ──

class _FakeResp:
    """Minimal context-manager stand-in for urllib's response (json.load reads it)."""

    def __init__(self, payload: bytes):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self._payload


def test_embed_default_ollama():
    # Default embedding backend is ollama — the local path stays unchanged, no
    # regression for anyone not opting into the cloud embedder.
    assert rag.EMBED_BACKEND == "ollama"
    assert rag.active_embed_model() == rag.MODEL_BGE


def test_embed_switch_to_openai_compat(monkeypatch):
    # EMBED_BACKEND=openai → embed() posts to an OpenAI-compatible /v1/embeddings
    # (mock urllib, no real network).
    import urllib.request

    monkeypatch.setattr(rag, "EMBED_BACKEND", "openai")
    monkeypatch.setattr(rag, "EMBED_MODEL_OPENAI", "test-embed")
    monkeypatch.setenv("OPENAI_BASE_URL", "https://x.example/v1")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.delenv("EMBED_BASE_URL", raising=False)
    monkeypatch.delenv("EMBED_API_KEY", raising=False)
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["auth"] = req.get_header("Authorization")
        captured["body"] = json.loads(req.data)
        return _FakeResp(b'{"data":[{"embedding":[0.1,0.2,0.3]}]}')

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    vec = rag.embed("hello", rag.MODEL_BGE)

    assert captured["url"] == "https://x.example/v1/embeddings"
    assert captured["auth"] == "Bearer sk-test"
    assert captured["body"]["model"] == "test-embed"
    assert np.allclose(vec, np.array([0.1, 0.2, 0.3], dtype=np.float32))
    assert vec.dtype == np.float32


def test_llm_api_posts_to_openai_compat(monkeypatch):
    # backend=api → llm() posts to an OpenAI-compatible /v1/chat/completions.
    import urllib.request

    monkeypatch.setenv("OPENAI_BASE_URL", "https://x.example/v1")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["auth"] = req.get_header("Authorization")
        captured["body"] = json.loads(req.data)
        return _FakeResp(b'{"choices":[{"message":{"content":"ok"}}]}')

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    out = analysis.llm("sys", "usr", backend="api", model="test-model")

    assert out == "ok"
    assert captured["url"] == "https://x.example/v1/chat/completions"
    assert captured["auth"] == "Bearer sk-test"
    assert captured["body"]["model"] == "test-model"
    assert captured["body"]["messages"][0]["role"] == "system"
