#!/usr/bin/env python3
"""HTTP surface for the Chronicle RAG sidecar.

This service has no auth of its own: it is reachable only from the Go API (on
localhost / a private network), which authenticates the user and passes a
trusted user id in the X-User-Id header. Every request is scoped to that user.

Endpoints:
  GET  /health                 liveness
  POST /warmup                 preheat reranker + embedding (fire-and-forget)
  POST /index   {capture_id}   embed + extract one capture (called by Go on write)
  POST /backfill-queue         enqueue one deduplicated user repair pass
  GET|POST /find               hybrid search → ranked captures
  POST /ask     {question}     query-time cluster analysis → {answer, sources}
  POST /backfill               index/extract everything missing (one user, or all)
  GET  /config                 runtime config + local backend detection
  PATCH /config {rerank_backend}
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
import os
import queue
import sys
import threading
import time

import uvicorn
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

import analysis
import detect
import extract
import rag
import search as search_svc
import webhook


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    start_repair_workers()
    yield


app = FastAPI(
    title="Chronicle RAG sidecar",
    version="0.1.0",
    lifespan=lifespan,
)
_BACKFILL_INTERVAL = int(os.getenv("BACKFILL_INTERVAL_SECONDS", "900"))
_BACKFILL_CHUNK_SIZE = 50
_backfill_lock = threading.Lock()
_backfill_queue: queue.Queue[str] = queue.Queue(maxsize=64)
_backfill_states: dict[str, str] = {}
_backfill_dirty: set[str] = set()
_backfill_pending_lock = threading.Lock()


def _index_one(capture_id: str, user_id: str, fire_webhooks: bool = True) -> None:
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
        if fire_webhooks:
            webhook.fire(capture_id, user_id)
    except Exception as e:
        print(f"[index] {capture_id} failed (backfill will retry): {e}", file=sys.stderr)
    finally:
        # This write changed the user's corpus (embedding/metadata add or clear);
        # drop the cached snapshot so the next recall reflects it immediately
        # rather than waiting out the TTL. Runs on every path (a no-op reload when
        # nothing changed is cheap and rare).
        rag.invalidate_corpus(user_id)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/warmup")
def warmup() -> dict[str, str]:
    threading.Thread(target=search_svc.warmup, daemon=True).start()
    return {"status": "warming"}


@app.post("/invalidate")
def invalidate(user_id: str = Header(..., alias="X-User-Id")) -> dict[str, str]:
    """Drop one user's in-process corpus snapshot after a membership mutation.

    This is deliberately separate from /index: delete/restore must refresh recall
    visibility without re-running extraction or firing outbound webhooks.
    """
    rag.invalidate_corpus(user_id)
    return {"status": "invalidated"}


class IndexIn(BaseModel):
    capture_id: str
    fire_webhooks: bool = True


@app.post("/index", status_code=202)
def index(body: IndexIn, background: BackgroundTasks,
          user_id: str = Header(..., alias="X-User-Id")) -> dict[str, str]:
    background.add_task(
        _index_one, body.capture_id, user_id, body.fire_webhooks)
    return {"status": "queued"}


class FindIn(BaseModel):
    query: str
    limit: int = 10
    excluded_ids: list[str] = Field(default_factory=list)


@app.post("/find")
def find(body: FindIn, user_id: str = Header(..., alias="X-User-Id")) -> list[dict]:
    return search_svc.search(user_id, body.query, body.limit, set(body.excluded_ids))


@app.get("/find")
def find_compat(
    q: str, limit: int = 10, user_id: str = Header(..., alias="X-User-Id"),
) -> list[dict]:
    """Compatibility for API instances rolling forward before their sidecar."""
    return search_svc.search(user_id, q, limit)


class RelatedIn(BaseModel):
    capture_id: str
    limit: int = 5
    excluded_ids: list[str] = Field(default_factory=list)


@app.post("/related")
def related(body: RelatedIn,
            user_id: str = Header(..., alias="X-User-Id")) -> list[dict]:
    """Semantic neighbours of one capture (for the 'Related' surface). Empty when
    embeddings are off or the capture has no text — never an error."""
    return search_svc.related(
        user_id, body.capture_id, body.limit, set(body.excluded_ids))


@app.get("/related")
def related_compat(
    id: str, limit: int = 5,
    user_id: str = Header(..., alias="X-User-Id"),
) -> list[dict]:
    """Compatibility for API instances rolling forward before their sidecar."""
    return search_svc.related(user_id, id, limit)


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
    with _backfill_lock:
        targets = [user_id] if user_id else rag.all_user_ids()
        embedded = extracted = 0
        cleared = 0
        failures = 0
        for uid in targets:
            # needs_index covers all three staleness cases: missing, stale content
            # hash (edited while down), and previous embedding model.
            for cid in rag.needs_index(uid):
                try:
                    if rag.index_capture(cid, uid):
                        embedded += 1
                except Exception as error:
                    failures += 1
                    print(f"[backfill] embed {cid} failed: {error}", file=sys.stderr)
            try:
                extracted += extract.backfill(uid)
            except Exception as error:
                failures += 1
                print(f"[backfill] extract user {uid} failed: {error}", file=sys.stderr)
            # Purge derived rows for captures whose text was cleared while down.
            try:
                for cid in rag.orphaned_derived(uid):
                    try:
                        rag.clear_derived(cid)
                        cleared += 1
                    except Exception as error:
                        failures += 1
                        print(f"[backfill] clear {cid} failed: {error}", file=sys.stderr)
            except Exception as error:
                failures += 1
                print(f"[backfill] list orphaned user {uid} failed: {error}", file=sys.stderr)
            # Backfill rewrote this user's embeddings/metadata; drop any cached snapshot.
            rag.invalidate_corpus(uid)
        return {"users": len(targets), "embedded": embedded,
                "extracted": extracted, "cleared": cleared, "failures": failures}


@app.post("/backfill-queue", status_code=202)
def queue_backfill(user_id: str = Header(..., alias="X-User-Id")) -> dict[str, str]:
    """Queue one bounded, deduplicated repair pass for a user.

    Imported captures are discovered from Postgres rather than carried in the
    in-memory job, and the periodic all-user pass remains the durable fallback.
    """
    with _backfill_pending_lock:
        state = _backfill_states.get(user_id)
        if state == "queued":
            return {"status": "already_queued"}
        if state == "running":
            _backfill_dirty.add(user_id)
            return {"status": "queued_again"}
        _backfill_states[user_id] = "queued"
        try:
            _backfill_queue.put_nowait(user_id)
        except queue.Full:
            _backfill_states.pop(user_id, None)
            return {"status": "periodic"}
    return {"status": "queued"}


def _backfill_user_chunk(user_id: str, limit: int = _BACKFILL_CHUNK_SIZE) -> bool:
    """Process a fair slice of one user's repair work.

    Returns whether the snapshot contained more work than this slice. Failures
    are left for the periodic repair pass instead of causing a tight retry loop.
    """
    with _backfill_lock:
        index_targets = rag.needs_index(user_id)
        extract_targets = rag.needs_extract(user_id, extract.EXTRACT_V)
        orphaned_targets = rag.orphaned_derived(user_id)
        has_more = any(len(items) > limit for items in (
            index_targets, extract_targets, orphaned_targets
        ))
        for capture_id in index_targets[:limit]:
            try:
                rag.index_capture(capture_id, user_id)
            except Exception as error:
                print(f"[backfill] embed {capture_id} failed: {error}", file=sys.stderr)
        for row in extract_targets[:limit]:
            try:
                content = row["content"]
                if content.strip():
                    rag.update_metadata(
                        row["id"], user_id, extract.extract(content), content
                    )
            except Exception as error:
                print(f"[backfill] extract {row.get('id')} failed: {error}", file=sys.stderr)
        for capture_id in orphaned_targets[:limit]:
            try:
                rag.clear_derived(capture_id)
            except Exception as error:
                print(f"[backfill] clear {capture_id} failed: {error}", file=sys.stderr)
        rag.invalidate_corpus(user_id)
        return has_more


def _run_one_backfill_job() -> None:
    user_id = _backfill_queue.get()
    has_more = False
    try:
        with _backfill_pending_lock:
            _backfill_states[user_id] = "running"
        has_more = _backfill_user_chunk(user_id)
    finally:
        with _backfill_pending_lock:
            should_requeue = has_more or user_id in _backfill_dirty
            _backfill_dirty.discard(user_id)
            if should_requeue:
                try:
                    _backfill_queue.put_nowait(user_id)
                    _backfill_states[user_id] = "queued"
                except queue.Full:
                    _backfill_states.pop(user_id, None)
            else:
                _backfill_states.pop(user_id, None)
        _backfill_queue.task_done()


def _queued_backfill_worker() -> None:
    while True:
        try:
            _run_one_backfill_job()
        except Exception as error:
            print(f"[backfill] queued run failed: {error}", file=sys.stderr)


def _periodic_backfill() -> None:
    if _BACKFILL_INTERVAL <= 0:
        return
    while True:
        time.sleep(_BACKFILL_INTERVAL)
        try:
            for user_id in rag.all_user_ids():
                queue_backfill(user_id=user_id)
        except Exception as error:
            print(f"[backfill] periodic run failed: {error}", file=sys.stderr)


def start_repair_workers() -> None:
    threading.Thread(target=_queued_backfill_worker, daemon=True).start()
    threading.Thread(target=_periodic_backfill, daemon=True).start()


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
