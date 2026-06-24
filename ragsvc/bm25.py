#!/usr/bin/env python3
"""Keyword recall L1 — pure-Python BM25 with character-bigram tokenization.

Why it exists: ILIKE only matches whole substrings, so a multi-word query
("拉面 1200") fails outright and has no notion of term frequency / rarity. BM25
is the standard keyword score: more occurrences = more relevant (TF, saturating
via k1), rarer terms discriminate more (IDF), long documents are dampened (b).
It complements vector recall: BM25 catches "the words match", vectors catch "the
meaning matches"; both candidate sets go to the cross-encoder to rerank.

Why character bigrams rather than a tokenizer: CJK has no spaces, and a real
segmenter drags in a heavy dependency (jieba/sudachi). Slicing a CJK run into
adjacent 2-char groups (拉面店 → 拉面/面店) is the pg_bigm approach — uniform for
CJK, zero dependency, slightly wider recall with precision handled downstream by
rerank. ASCII runs (English/digits) are treated as whole lowercased words.
"""
from __future__ import annotations

import math
from collections import Counter

K1 = 1.5
B = 0.75


def tokenize(text: str) -> list[str]:
    """ASCII alnum runs → whole lowercased word; other alnum runs (CJK etc.) →
    character bigrams; punctuation/whitespace dropped."""
    tokens: list[str] = []
    ascii_run: list[str] = []
    cjk_run: list[str] = []

    def flush_ascii() -> None:
        if ascii_run:
            tokens.append("".join(ascii_run).lower())
            ascii_run.clear()

    def flush_cjk() -> None:
        if cjk_run:
            run = "".join(cjk_run)
            if len(run) == 1:
                tokens.append(run)
            else:
                tokens.extend(run[i:i + 2] for i in range(len(run) - 1))
            cjk_run.clear()

    for ch in text:
        if ch.isascii() and ch.isalnum():
            flush_cjk()
            ascii_run.append(ch)
        elif ch.isalnum():
            flush_ascii()
            cjk_run.append(ch)
        else:
            flush_ascii()
            flush_cjk()
    flush_ascii()
    flush_cjk()
    return tokens


def top_k(query: str, docs: list[tuple[str, str]], k: int = 10) -> list[tuple[str, float]]:
    """Score docs[(id, content)] by BM25; return the top-k (id, score>0)."""
    q_tokens = set(tokenize(query))
    if not q_tokens or not docs:
        return []

    doc_counts = [(doc_id, Counter(tokenize(content))) for doc_id, content in docs]
    n = len(doc_counts)
    avgdl = sum(sum(c.values()) for _, c in doc_counts) / n or 1.0
    df = {t: sum(1 for _, c in doc_counts if t in c) for t in q_tokens}

    scored: list[tuple[str, float]] = []
    for doc_id, counts in doc_counts:
        dl = sum(counts.values())
        s = 0.0
        for t in q_tokens:
            tf = counts.get(t, 0)
            if tf == 0:
                continue
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            s += idf * (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * dl / avgdl))
        if s > 0:
            scored.append((doc_id, s))
    scored.sort(key=lambda x: -x[1])
    return scored[:k]
