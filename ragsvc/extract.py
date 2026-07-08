#!/usr/bin/env python3
"""Capture-time extraction — fully open: the local LLM pulls whatever objective
key/values a capture literally carries.

Philosophy (unchanged from rag): a meaningful capture carries objective facts
(what was done / with whom / where / how it felt). Key names are not prescribed
— what gets pulled is decided by the sentence, which fields matter is decided by
the user's usage. Red line: only extract facts literally present; never invent,
never infer causation.

The only two structural rules (not a taxonomy):
  - amount/currency come from a currency-marker regex (deterministic numbers beat
    LLM transcription; bare ambiguous numbers are left to the semantic layer);
    when the regex hits, those keys win and the LLM cannot overwrite them.
  - extract_v is written by the system; bumping it re-extracts everything via one
    backfill command.

Backend-dependent privacy: ollama keeps text on the machine; claude (claude -p)
and api (OpenAI-compatible) send the capture text to that provider.
"""
from __future__ import annotations

import json
import os
import re
import sys

import ollama

import analysis
import rag

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
EXTRACT_MODEL = os.getenv("EXTRACT_MODEL", "qwen3.5:4b")
# Where open extraction runs: claude (the claude -p agent, no model install),
# api (an OpenAI-compatible cloud endpoint, BYOK), or ollama (a local model).
# Default claude so the service needs no embedding/LLM model installed — only the
# claude CLI.
EXTRACT_BACKEND = os.getenv("EXTRACT_BACKEND", "claude")
EXTRACT_V = 2

# Amount: digits (optional thousands commas) + an explicit currency marker.
# Order-sensitive — 日元 must precede bare 元. Bare ¥ is ambiguous (both CN/JP);
# defaults to JPY. Bare numbers with no marker are not extracted (omit over err).
_AMOUNT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"(\d[\d,]*)\s*(?:日元|日币|円|JPY)"), "JPY"),
    (re.compile(r"(\d[\d,]*)\s*(?:人民币|元|块|RMB)"), "CNY"),
    (re.compile(r"[¥￥]\s*(\d[\d,]*)"), "JPY"),
]

_FACTS_PROMPT = """把这条个人记录碎片**字面承载**的客观信息抽成一个扁平 JSON 对象，只输出 JSON：
- 键名自定（简短英文或中文），值是短字符串或数字
- 只抽原文里实际出现或直接对应的信息；禁止编造，禁止推断原因
- 纯语气/无信息的碎片输出 {{}}

例：
「今天午饭在拉面店花了1200日元」→ {{"category":"food","merchant":"拉面店","food":"拉面","meal":"午饭"}}
「今天一直在加班，很累」→ {{"activity":"加班","mood":"累"}}
「好了？」→ {{}}

碎片：「{content}」"""

_FACTS_SYSTEM = (
    "你从个人记录碎片里抽取**字面承载**的客观键值，只输出一个扁平 JSON 对象，"
    "不要解释、不要代码块、不要多余文字。"
)

# Total-line priority: a receipt transcript has several amounts (line items +
# total); the first is usually a line item — the amount on a line containing a
# total keyword is the one that books the spend.
_TOTAL_HINT = re.compile(r"合計|合计|総計|总计|小計|計|total", re.IGNORECASE)


def extract_amount(content: str) -> tuple[int | None, str | None]:
    """Regex out amount+currency (deterministic). Returns (amount, currency) or
    (None, None). Multi-amount text (receipts): total line first, else first match."""
    for line in content.splitlines():
        if _TOTAL_HINT.search(line):
            for pat, currency in _AMOUNT_PATTERNS:
                m = pat.search(line)
                if m:
                    return int(m.group(1).replace(",", "")), currency
    for pat, currency in _AMOUNT_PATTERNS:
        m = pat.search(content)
        if m:
            return int(m.group(1).replace(",", "")), currency
    return None, None


def _sanitize(data: object, taken: set[str]) -> dict:
    """Mechanical hygiene (the only guard, no semantic whitelist): flat dict,
    short keys, values str(≤30)/int/float, ≤10 keys, drop taken keys."""
    if not isinstance(data, dict):
        return {}
    out: dict = {}
    for k, v in data.items():
        if len(out) >= 10:
            break
        if not isinstance(k, str) or not k or len(k) > 20 or k in taken:
            continue
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            out[k] = v
        elif isinstance(v, str) and 0 < len(v) <= 30:
            out[k] = v
    return out


def _facts_llm(content: str, backend: str) -> dict:
    """Open extraction via a remote LLM — claude (the claude -p agent, no model
    install) or api (an OpenAI-compatible cloud endpoint, BYOK). Routed through
    analysis.llm so the claude/api call stays inside the analysis module (CLAUDE.md
    hard rule). The model may wrap JSON in prose; pull out the first object."""
    out = analysis.llm(_FACTS_SYSTEM, _FACTS_PROMPT.format(content=content[:500]),
                       backend=backend)
    m = re.search(r"\{.*\}", out, re.DOTALL)
    if not m:
        raise ValueError("no JSON object in LLM output")
    return json.loads(m.group(0))


_OLLAMA_CLIENT: ollama.Client | None = None


def _ollama_client() -> ollama.Client:
    """Shared client so backfill's back-to-back extractions reuse one HTTP
    connection. trust_env=False: local calls skip the system proxy."""
    global _OLLAMA_CLIENT
    if _OLLAMA_CLIENT is None:
        _OLLAMA_CLIENT = ollama.Client(host=OLLAMA_BASE_URL, trust_env=False)
    return _OLLAMA_CLIENT


def _facts_ollama(content: str) -> dict:
    """Local qwen, free key/value extraction. think=False is mandatory —
    format=json's grammar constraint fights the thinking phase and makes long
    receipt text pathologically slow."""
    resp = _ollama_client().chat(
        model=EXTRACT_MODEL,
        messages=[{"role": "user", "content": _FACTS_PROMPT.format(content=content[:500])}],
        format="json",
        think=False,
        options={"num_predict": 400},
        keep_alive="1m",
    )
    return json.loads(resp["message"]["content"])


def _facts(content: str) -> dict:
    """Open key/value extraction, via the configured backend."""
    if EXTRACT_BACKEND == "ollama":
        return _facts_ollama(content)
    if EXTRACT_BACKEND == "api":
        return _facts_llm(content, "api")
    return _facts_llm(content, "claude")


def extract(content: str) -> dict:
    """Extract one capture's objective metadata. An LLM failure does not affect
    the hard facts the regex already pulled — but it leaves extract_v at 0 so the
    capture is marked incomplete and backfill retries the open extraction later
    (a transient agent failure must not be recorded as a finished extraction)."""
    meta: dict = {"extract_v": EXTRACT_V}
    taken = {"extract_v"}
    amount, currency = extract_amount(content)
    if amount is not None:
        meta["amount"] = amount
        meta["currency"] = currency
        taken |= {"amount", "currency"}
    try:
        meta.update(_sanitize(_facts(content), taken))
    except Exception as e:
        meta["extract_v"] = 0  # incomplete — keep regex facts, let backfill retry
        print(f"[extract] open extraction failed (regex facts kept, will retry): {e}", file=sys.stderr)
    return meta


def backfill(user_id: str) -> int:
    """(Re-)extract every capture needing it (missing, stale version, or stale
    content hash) for one user. Returns the number processed."""
    rows = rag.needs_extract(user_id, EXTRACT_V)
    done = 0
    for r in rows:
        content = r["content"]
        if not content.strip():
            continue
        rag.update_metadata(r["id"], user_id, extract(content), content)
        done += 1
    return done
