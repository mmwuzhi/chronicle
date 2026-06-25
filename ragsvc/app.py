#!/usr/bin/env python3
"""HTTP surface for the Chronicle RAG sidecar.

This service has no auth of its own: it is reachable only from the Go API (on
localhost / a private network), which authenticates the user and passes a
trusted user id in the X-User-Id header. Every request is scoped to that user.

Endpoints:
  GET  /health                 liveness
  POST /warmup                 preheat reranker + embedding (fire-and-forget)
  POST /index   {capture_id}   embed + extract one capture (called by Go on write)
  GET  /find?q=&limit=         hybrid search → ranked captures
  POST /ask     {question}     query-time cluster analysis → {answer, sources}
  POST /backfill               index/extract everything missing (one user, or all)
  GET  /config                 runtime config + local backend detection
  PATCH /config {rerank_backend}
"""
from __future__ import annotations

import os
import sys
import threading

import uvicorn
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from pydantic import BaseModel

import analysis
import detect
import extract
import rag
import search as search_svc
import webhook

app = FastAPI(title="Chronicle RAG sidecar", version="0.1.0")


def _index_one(capture_id: str, user_id: str) -> None:
    """Embed (if enabled) + extract metadata for one capture. Extraction runs
    independently of embedding, so the agent-based metadata still lands when the
    vector channel is off. Best-effort: a failure leaves the capture for the next
    backfill to self-heal."""
    try:
        text = rag.get_content(capture_id, user_id)
        if text is None:
            return
        if not text.strip():
            rag.clear_derived(capture_id)  # text cleared — drop stale derived rows
            return
        if rag.EMBED_ENABLED:
            rag.index_capture(capture_id, user_id)
        rag.update_metadata(capture_id, user_id, extract.extract(text), text)
        # Outbound rules fire last, with content + embedding + metadata all ready.
        # fire() never raises; a webhook can't break indexing.
        webhook.fire(capture_id, user_id)
    except Exception as e:
        print(f"[index] {capture_id} failed (backfill will retry): {e}", file=sys.stderr)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/warmup")
def warmup() -> dict[str, str]:
    threading.Thread(target=search_svc.warmup, daemon=True).start()
    return {"status": "warming"}


class IndexIn(BaseModel):
    capture_id: str


@app.post("/index", status_code=202)
def index(body: IndexIn, background: BackgroundTasks,
          user_id: str = Header(..., alias="X-User-Id")) -> dict[str, str]:
    background.add_task(_index_one, body.capture_id, user_id)
    return {"status": "queued"}


@app.get("/find")
def find(q: str, limit: int = 10, user_id: str = Header(..., alias="X-User-Id")) -> list[dict]:
    return search_svc.search(user_id, q, limit)


@app.get("/related")
def related(id: str, limit: int = 10,
            user_id: str = Header(..., alias="X-User-Id")) -> list[dict]:
    """Semantic neighbours of one capture (for the 'Related' surface). Empty when
    embeddings are off or the capture has no text — never an error."""
    return rag.related(user_id, id, limit)


class AskIn(BaseModel):
    question: str


@app.post("/ask")
def ask(body: AskIn, user_id: str = Header(..., alias="X-User-Id")) -> dict:
    return analysis.analyze(user_id, body.question)


@app.post("/backfill")
def backfill(user_id: str | None = Header(default=None, alias="X-User-Id")) -> dict:
    """Index every capture missing an embedding and (re-)extract metadata below
    the current version. Scoped to one user if X-User-Id is given, else all users
    (operator/cron use). Synchronous — meant for a CLI/cron, not a hot path."""
    targets = [user_id] if user_id else rag.all_user_ids()
    embedded = extracted = 0
    cleared = 0
    for uid in targets:
        # needs_index covers all three staleness cases: missing, stale content
        # hash (edited while down), and previous embedding model.
        for cid in rag.needs_index(uid):
            if rag.index_capture(cid, uid):
                embedded += 1
        extracted += extract.backfill(uid)
        # Purge derived rows for captures whose text was cleared while down.
        for cid in rag.orphaned_derived(uid):
            rag.clear_derived(cid)
            cleared += 1
    return {"users": len(targets), "embedded": embedded,
            "extracted": extracted, "cleared": cleared}


_RERANK_BACKENDS = {"auto", "local", "cross_encoder", "claude", "api", "off"}


class ConfigPatch(BaseModel):
    rerank_backend: str


@app.get("/config")
def get_config() -> dict:
    backend = rag.config_get("rerank_backend") or search_svc.RERANK_BACKEND
    return {"rerank_backend": backend,
            "rerank_api_ok": search_svc.rerank_api_ok(),
            "detected": detect.detect_backends(),
            "effective": search_svc.effective_backends()}


@app.patch("/config")
def patch_config(body: ConfigPatch) -> dict:
    if body.rerank_backend not in _RERANK_BACKENDS:
        raise HTTPException(
            status_code=400,
            detail=f"rerank_backend must be one of {sorted(_RERANK_BACKENDS)}")
    rag.config_set("rerank_backend", body.rerank_backend)
    if body.rerank_backend != "cross_encoder":
        search_svc._unload_reranker()
    return get_config()


class WebhookTestIn(BaseModel):
    capture_id: str
    keywords: list[str] = []
    semantic_query: str | None = None
    semantic_threshold: float = 0.6


@app.post("/webhooks/test")
def webhook_test(body: WebhookTestIn,
                 user_id: str = Header(..., alias="X-User-Id")) -> dict:
    """Score one webhook rule against one capture without delivering. The Go
    /webhooks/{id}/test proxies here so the UI can tune the semantic threshold."""
    frag = rag.get_fragment(body.capture_id, user_id)
    if frag is None:
        raise HTTPException(status_code=404, detail="capture not found")
    rule = {"keywords": body.keywords, "semantic_query": body.semantic_query,
            "semantic_threshold": body.semantic_threshold}
    matched, score = webhook.matches(rule, frag)
    return {"matched": matched, "score": score}


def main() -> None:
    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("RAG_PORT", "5400")))


if __name__ == "__main__":
    main()
