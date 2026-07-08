#!/usr/bin/env python3
"""Query-time analysis — the "generation" half of RAG.

Flow: assemble the cluster of captures relevant to a question (semantic
neighbours ∪ recent ∪ BM25 keyword ∪ the full slice of any time window named in
the question), format each with its extracted metadata, and hand it to an LLM to
reason — and compute — over grounded detail. The LLM call sits behind llm(),
default claude -p (the user's subscription) with automatic fallback to local
Ollama. There is deliberately no intent routing and no SQL aggregation path:
factual/aggregational and interpretive/causal questions both go through the same
completeness-oriented recall, and the model does the arithmetic in place.

Citation numbering: captures are identified by UUID, which the model can't echo
reliably, so the cluster is presented to the model as #1..#N (positional) and the
answer's #N references are mapped back to the underlying capture ids.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request

import ollama

import rag

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
ANALYZER_BACKEND = os.getenv("ANALYZER_BACKEND", "claude")
ANALYZER_MODEL = os.getenv("ANALYZER_MODEL", "qwen3.5:4b")
# OpenAI-compatible chat backend (BYOK) for the api path. base/key reuse the
# shared OPENAI_* config (same key the embedding api path and Whisper use).
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
# Cap the claude -p subprocess so it can't outlive the Go gateway's per-request
# deadline (ragclient askTimeout) and leave orphaned work running. Keep it below
# that budget; raise both together if analyses legitimately need longer.
CLAUDE_TIMEOUT = int(os.getenv("CLAUDE_TIMEOUT", "20"))
# Same budget reasoning for the api backend's HTTP call — keep under Go askTimeout.
API_TIMEOUT = int(os.getenv("API_TIMEOUT", "20"))

SYSTEM = (
    "你是用户私人碎片记录的分析助手。只依据【提供的碎片】回答，绝不编造。\n"
    "只标注你真正依据的碎片编号（如 #12）；不要罗列无关或你认为没价值的碎片。\n"
    "若问题涉及合计/统计：基于碎片明细自行计算，列出参与计算的明细（#编号+数额）"
    "供核对；不同币种分开统计，绝不混加。\n"
    "若碎片不足以回答，直接说明信息不够、需要更多记录。\n"
    "回答简洁，用提问者的语言。"
)


# Hard ceiling on a time-window slice, so a pathologically large window can't
# blow the LLM context unbounded. At personal scale a named window (上个月 etc.)
# is well under this; it exists only as a safety valve.
WINDOW_HARD_CAP = 400


def assemble_cluster(user_id: str, question: str, k_sem: int = 20, k_recent: int = 20,
                     k_bm25: int = 10, cap: int = 60) -> list[rag.Fragment]:
    """Assemble the context window: the full time-window slice (if the question
    names one) plus supplementary recall — semantic neighbours ∪ recent ∪ BM25.

    The full time-window slice is what makes aggregation trustworthy: every
    capture in a named window enters the cluster so the model's total can't drop
    a row — a missed row is a silent error, worse than a visible miscalculation.
    So the window slice is added *first* and is never squeezed out by the cap;
    supplementary recall only fills whatever budget remains (cap, or the whole
    window if it is larger). Window-free questions are pure supplementary recall.
    """
    import bm25
    import dates

    # One corpus load for the whole question: the time-window slice, the BM25
    # channel, and the semantic channel (neighbors, via corpus=) all share it
    # instead of each re-pulling every capture from Postgres.
    frags = rag.search_corpus(user_id)
    by_id = {f["id"]: f for f in frags}

    window_order: list[str] = []
    window = dates.parse_range(question)
    if window:
        lo, hi = window[0].isoformat(), window[1].isoformat()
        for f in frags:
            if lo <= f["created_at"][:10] <= hi:
                window_order.append(f["id"])
    window_order = window_order[:WINDOW_HARD_CAP]
    window_set = set(window_order)

    supp_order: list[str] = []

    def add_supp(fid: str) -> None:
        if fid in by_id and fid not in window_set and fid not in supp_order:
            supp_order.append(fid)

    for f in rag.neighbors(user_id, question, k_sem, corpus=frags):
        add_supp(f.id)
    for f in rag.recent(user_id, k_recent):
        add_supp(f.id)
    for fid, _score in bm25.top_k(question, [(f["id"], f["content"]) for f in frags],
                                  k=k_bm25):
        add_supp(fid)

    budget = max(0, cap - len(window_order))
    order = window_order + supp_order[:budget]

    return [rag.Fragment(by_id[i]["id"], by_id[i]["content"], by_id[i]["created_at"],
                         by_id[i]["metadata"], by_id[i]["modality"])
            for i in order]


def _meta_suffix(meta: dict | None) -> str:
    """Compact metadata suffix (skips extract_v and empty values)."""
    if not meta:
        return ""
    parts = [f"{k}:{v}" for k, v in meta.items()
             if k != "extract_v" and v not in ("", None)]
    return " {" + ", ".join(parts) + "}" if parts else ""


def _format(frags: list[rag.Fragment]) -> str:
    """One line per capture: #<n> [date] content {metadata}. n is the 1-based
    position in the cluster — the model cites these, not the UUID."""
    return "\n".join(
        f"#{i} [{f.created_at[:10]}] {f.content}{_meta_suffix(f.metadata)}"
        for i, f in enumerate(frags, 1)
    )


def _claude(system: str, user: str) -> str:
    """Subscription path: shell out to claude -p; uses no local model memory.

    The prompt contains user-controlled capture text and questions, so the CLI is
    locked down against prompt injection: an empty tool allowlist means the model
    can run no tools (no file reads, no Bash), and --setting-sources user skips the
    project's settings/CLAUDE.md so a repo config can't re-enable any. This call is
    text-in/text-out only; a hostile capture can at worst produce a bad answer.

    The prompt is fed on stdin, not as an argv: a cluster of up to 60 capture
    bodies can exceed the OS argument-size limit (E2BIG), and argv is visible to
    other processes — private capture text must not ride there."""
    r = subprocess.run(
        ["claude", "-p", "--allowedTools", "", "--setting-sources", "user"],
        input=f"{system}\n\n{user}",
        capture_output=True, text=True, timeout=CLAUDE_TIMEOUT,
    )
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[:300] or "claude -p non-zero exit")
    out = r.stdout.strip()
    if not out:
        raise RuntimeError("claude -p produced no output")
    return out


_OLLAMA_CLIENT: ollama.Client | None = None


def _ollama_client() -> ollama.Client:
    """Shared client so repeated chat calls (per-search rerank scoring) reuse one
    HTTP connection. trust_env=False so the localhost call skips the system
    proxy."""
    global _OLLAMA_CLIENT
    if _OLLAMA_CLIENT is None:
        _OLLAMA_CLIENT = ollama.Client(host=OLLAMA_BASE_URL, trust_env=False)
    return _OLLAMA_CLIENT


def _ollama(system: str, user: str, model: str) -> str:
    """Local model."""
    resp = _ollama_client().chat(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    return resp["message"]["content"]


def _openai_compat(system: str, user: str, model: str | None = None) -> str:
    """OpenAI-compatible /v1/chat/completions (hand-rolled HTTP, zero SDK — keeps
    the seam in our own hands like the claude -p call). Covers OpenAI, Gemini's
    compat endpoint, DeepSeek, a local vLLM, etc. This is the cloud path that the
    deferred cloud form needs (no claude CLI, no Ollama)."""
    base = (os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    key = os.getenv("OPENAI_API_KEY") or ""
    model = model or OPENAI_MODEL
    if not key:
        raise RuntimeError("OPENAI_API_KEY not configured")
    body = json.dumps({"model": model, "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(
        f"{base}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=API_TIMEOUT) as r:
        data = json.load(r)
    return data["choices"][0]["message"]["content"]


def llm(system: str, user: str, backend: str | None = None,
        model: str | None = None) -> str:
    """Shared LLM entry for analyze + search rerank — claude/api calls are
    centralized here. backend defaults to ANALYZER_BACKEND; claude falls back to
    local model, api (cloud) does not (it is itself the no-local-model path)."""
    backend = backend or ANALYZER_BACKEND
    if backend == "api":
        # api uses OPENAI_MODEL, not the local ANALYZER_MODEL; pass model through
        # (None lets _openai_compat default it).
        return _openai_compat(system, user, model)
    model = model or ANALYZER_MODEL
    if backend == "claude":
        try:
            return _claude(system, user)
        except Exception as e:
            print(f"[analysis] Claude unavailable, falling back to local {model}: {e}",
                  file=sys.stderr)
            return _ollama(system, user, model)
    if backend == "ollama":
        return _ollama(system, user, model)
    raise ValueError(f"unknown backend: {backend}")


def _renumber(answer: str, cluster: list[rag.Fragment]) -> tuple[str, list[dict]]:
    """Rewrite the answer's #<n> citations (1-based positions into the prompt's
    cluster listing) to [1][2]… by order of appearance, returning only the cited
    captures with their real ids. Out-of-range #n (model hallucination) ignored."""
    order: list[int] = []
    for m in re.finditer(r"#(\d+)", answer):
        pos = int(m.group(1))
        if 1 <= pos <= len(cluster) and pos not in order:
            order.append(pos)
    num = {pos: i + 1 for i, pos in enumerate(order)}
    new_answer = re.sub(
        r"#(\d+)",
        lambda m: f"[{num[int(m.group(1))]}]" if int(m.group(1)) in num else m.group(0),
        answer,
    )
    sources = [
        {"n": num[pos], "id": cluster[pos - 1].id,
         "content": cluster[pos - 1].content, "created_at": cluster[pos - 1].created_at}
        for pos in order
    ]
    return new_answer, sources


def analyze(user_id: str, question: str) -> dict:
    """Query-time analysis for one question; returns {answer, sources:[cited]}."""
    cluster = assemble_cluster(user_id, question)
    if not cluster:
        # Nothing to reason over. Return an empty answer and let the frontend show
        # a message in the user's own language (the service has no locale here).
        return {"answer": "", "sources": []}
    user = f"问题：{question}\n\n相关碎片：\n{_format(cluster)}"
    answer = llm(SYSTEM, user)
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL).strip()
    answer, sources = _renumber(answer, cluster)
    return {"answer": answer, "sources": sources}
