#!/usr/bin/env python3
"""Search = layered recall → cross-encoder rerank → calibrated-score threshold;
explicit dates route to that day.

Layers (L0-L3):
  L0 information gate — query side: zero-content queries go literal-only;
                        doc side: zero-content captures stay out of fuzzy recall.
  L1 keyword recall   — ILIKE substring (in rag.candidates) + BM25 char-bigrams.
  L2 vector recall    — bge-m3 cosine top-k, low floor (in rag.candidates).
  L3 rerank           — bge-reranker-v2-m3 or an LLM scorer; calibrated 0-1 score
                        doubles as per-item relevance and overall "any results".
                        Seam: rerank backend is swappable (config rerank_backend).
"""
from __future__ import annotations

import gc
import json
import os
import re
import sys
import threading
import time
import urllib.request

import bm25
import rag
from rag import _content_chars

RERANK_BACKEND = os.getenv("RERANK_BACKEND", "auto")
RERANK_MODEL = os.getenv("RERANK_MODEL", "BAAI/bge-reranker-v2-m3")
RERANK_MIN_SCORE = float(os.getenv("RERANK_MIN_SCORE", "0.1"))
VECTOR_TAIL = float(os.getenv("VECTOR_TAIL", "0.55"))
TAIL_MIN_CHARS = int(os.getenv("TAIL_MIN_CHARS", "3"))
SEARCH_TOPK = int(os.getenv("SEARCH_TOPK", "10"))

_DATE_RE = re.compile(r"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$")
BM25_TOPK = int(os.getenv("BM25_TOPK", "10"))
RERANK_IDLE_UNLOAD = int(os.getenv("RERANK_IDLE_UNLOAD", "900"))

_reranker = None
_reranker_lock = threading.Lock()
_last_used = 0.0
_unloader_started = False


def _get_reranker():
    """Lazy-load bge-reranker (sentence-transformers), fp16. Locked so the warmup
    and request threads never load two copies."""
    global _reranker, _last_used
    _last_used = time.monotonic()
    if _reranker is None:
        with _reranker_lock:
            if _reranker is None:
                import torch
                from sentence_transformers import CrossEncoder
                _reranker = CrossEncoder(
                    RERANK_MODEL, max_length=512,
                    model_kwargs={"torch_dtype": torch.float16},
                )
                _start_unloader()
    return _reranker


def _unload_reranker() -> None:
    global _reranker
    with _reranker_lock:
        if _reranker is None:
            return
        _reranker = None
    gc.collect()
    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:
        pass


def _start_unloader() -> None:
    global _unloader_started
    if _unloader_started or RERANK_IDLE_UNLOAD <= 0:
        return
    _unloader_started = True

    def loop() -> None:
        while True:
            time.sleep(60)
            if _reranker is not None and time.monotonic() - _last_used > RERANK_IDLE_UNLOAD:
                _unload_reranker()

    threading.Thread(target=loop, daemon=True).start()


def warmup() -> None:
    """Preheat the heavy models (reranker + Ollama embedding) so the seconds a
    user spends typing become model load time. Fire-and-forget from /warmup."""
    if _resolve_rerank_backend() == "cross_encoder":
        _get_reranker()
    if rag.EMBED_ENABLED:
        try:
            rag.embed("warmup")
        except Exception:
            pass


# ── rerank backend seam (mirrors analysis.ANALYZER_BACKEND) ──

def _configured_rerank_backend() -> str:
    return rag.config_get("rerank_backend") or RERANK_BACKEND


def _resolve_rerank_backend() -> str:
    """Resolve 'auto' to a concrete backend: a usable local Ollama LLM → local,
    else off. auto never auto-loads cross_encoder and never auto-uses claude."""
    b = _configured_rerank_backend()
    if b != "auto":
        return b
    import detect
    d = detect.detect_backends()
    if d["ollama"]["available"] and d["ollama"]["models"]:
        return "local"
    return "off"


def effective_backends() -> dict:
    import analysis
    import extract
    if not rag.EMBED_ENABLED:
        embedding = "disabled"
    elif rag.EMBED_BACKEND == "openai":
        embedding = f"openai:{rag.EMBED_MODEL_OPENAI}"
    else:
        embedding = f"ollama:{rag.MODEL_BGE}"
    extract_label = (extract.EXTRACT_BACKEND if extract.EXTRACT_BACKEND in ("claude", "api")
                     else f"ollama:{extract.EXTRACT_MODEL}")
    return {
        "embedding": embedding,
        "rerank": _resolve_rerank_backend(),
        "extract": extract_label,
        "analysis": analysis.ANALYZER_BACKEND,
    }


_RERANK_SYSTEM = (
    "你给候选记录按与查询的相关性打分。只输出一个 JSON 对象：键是候选编号(字符串)，"
    "值是 0~1 的相关性分（1=高度相关，0=无关）。不要解释、不要多余文字。"
)


def _llm_rerank(query: str, cands: list[dict], backend: str) -> list[float] | None:
    """Score candidates via local Ollama or claude. Failure → None (fall back to
    vector ordering). Routed through analysis.llm — claude calls stay inside the
    analysis module. 0-based keys, not fragment ids (big ids bias the model)."""
    import analysis
    items = "\n".join(f"#{i} {c['content'][:200]}" for i, c in enumerate(cands))
    user = f"查询：{query}\n\n候选：\n{items}"
    ana_backend = "ollama" if backend == "local" else "claude"
    try:
        out = analysis.llm(_RERANK_SYSTEM, user,
                           backend=ana_backend, model=analysis.ANALYZER_MODEL)
        m = re.search(r"\{.*\}", out, re.DOTALL)
        if not m:
            raise ValueError("no JSON in LLM output")
        data = json.loads(m.group(0))
        return [float(data.get(str(i), 0.0)) for i in range(len(cands))]
    except Exception as e:
        print(f"[rerank] LLM scoring failed ({backend}), falling back to vector order: {e}",
              file=sys.stderr)
        return None


def rerank_api_ok() -> bool:
    """True when a cloud rerank endpoint + key are configured (env). The `api`
    rerank backend is only usable then; GET /config exposes this so the UI can
    offer `api` only when it would actually work."""
    return bool(os.getenv("RERANK_BASE_URL") and os.getenv("RERANK_API_KEY"))


def _rerank_api(query: str, cands: list[dict]) -> list[float] | None:
    """Generic cloud rerank API (jina / cohere / voyage …): POST
    {model, query, documents} → {results|data: [{index, relevance_score}]}.
    Hand-rolled HTTP, zero SDK (same seam discipline as rag._embed_openai),
    endpoint/key/model configurable, no vendor lock. Unconfigured or any failure
    → None, so the caller falls back to vector ordering — cloud jitter can never
    break search."""
    base = (os.getenv("RERANK_BASE_URL") or "").rstrip("/")
    key = os.getenv("RERANK_API_KEY") or ""
    model = os.getenv("RERANK_MODEL_API") or "rerank-2"
    if not base or not key:
        return None
    body = json.dumps({"model": model, "query": query,
                       "documents": [c["content"][:2000] for c in cands]}).encode()
    try:
        req = urllib.request.Request(
            f"{base}/rerank", data=body,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        items = data.get("results") or data.get("data") or []
        scores = [0.0] * len(cands)
        for it in items:
            scores[int(it["index"])] = float(it["relevance_score"])
        return scores
    except Exception as e:
        print(f"[rerank] API failed, falling back to vector order: {e}", file=sys.stderr)
        return None


def _rerank_scores(query: str, cands: list[dict]) -> list[float] | None:
    backend = _resolve_rerank_backend()
    if backend == "off":
        return None
    if backend == "cross_encoder":
        preds = _get_reranker().predict([[query, c["content"]] for c in cands])
        return [float(s) for s in preds]
    if backend == "api":
        return _rerank_api(query, cands)
    if backend in ("local", "claude"):
        return _llm_rerank(query, cands, backend)
    return None


def search(user_id: str, query: str, limit: int = SEARCH_TOPK) -> list[dict]:
    q = query.strip()
    if not q:
        return []

    m = _DATE_RE.match(q)
    if m:
        y, mo, d = (int(x) for x in m.groups())
        return rag.on_date(user_id, f"{y:04d}-{mo:02d}-{d:02d}", limit)

    cands = rag.candidates(user_id, q, k=30)

    # Information-poor query: single char, or all function words. No alignable
    # topic, rerank score is noise → literal hits only, newest first.
    if len(q) == 1 or _content_chars(q) == 0:
        kept = [c for c in cands if c["lexical"]]
        kept.sort(key=lambda c: c["created_at"], reverse=True)
        for c in kept:
            c["score"] = 1.0
        return kept[:limit]

    # L1 BM25 recall folded into candidates. Multi-word queries fail whole-string
    # ILIKE and may miss the 0.3 vector floor; shared tokens catch them. BM25
    # candidates do NOT get the literal-hit exemption — precision is still rerank's
    # job. Zero-density captures stay out of fuzzy recall.
    frags = rag.all_fragments(user_id)
    by_id = {f["id"]: f for f in frags}
    seen = {c["id"] for c in cands}
    for fid, _s in bm25.top_k(q, [(f["id"], f["content"]) for f in frags], k=BM25_TOPK):
        f = by_id[fid]
        if fid in seen or _content_chars(f["content"]) == 0:
            continue
        cands.append({"id": fid, "content": f["content"], "created_at": f["created_at"],
                      "modality": f["modality"], "lexical": False, "vscore": 0.0})

    if not cands:
        return []

    scores = _rerank_scores(q, cands)
    if scores is None:
        for c in cands:
            c["score"] = c["vscore"]
        cands.sort(key=lambda c: (not c["lexical"], -c["vscore"]))
        return cands[:limit]

    for c, s in zip(cands, scores):
        c["score"] = float(s)
    # Literal hits (a user-typed substring) are always kept and ranked first —
    # this is literal search, rerank must not veto it. Others kept if rerank ≥
    # threshold, or strong vector signal on a dense capture (rerank misfires on
    # transliterations / cross-language).
    kept = [c for c in cands
            if c["lexical"] or c["score"] >= RERANK_MIN_SCORE
            or (c["vscore"] >= VECTOR_TAIL
                and _content_chars(c["content"]) >= TAIL_MIN_CHARS)]
    kept.sort(key=lambda c: (not c["lexical"], -max(c["score"], c["vscore"] - 0.5)))
    return kept[:limit]
