"""Deterministic regression evaluation for the complete search policy.

The fixture controls vector and rerank scores so CI can exercise literal,
BM25, semantic-tail, threshold, date-route, no-reranker, and low-information
behavior without a model, network, or database. Model quality is deliberately
outside this gate; this suite protects Chronicle's fusion and filtering contract
while backends change.
"""
from __future__ import annotations

import json
from pathlib import Path

import search


FIXTURE = Path(__file__).parent / "fixtures" / "search-eval.json"


def _load() -> dict:
    return json.loads(FIXTURE.read_text())


def _candidates(documents: list[dict], case: dict) -> list[dict]:
    q = case["query"].lower()
    vector_scores = case["vector_scores"]
    out: list[dict] = []
    for document in documents:
        lexical = q in document["content"].lower()
        vector_score = float(vector_scores.get(document["id"], 0.0))
        if not lexical and vector_score < search.rag.CANDIDATE_FLOOR:
            continue
        out.append({
            **document,
            "lexical": lexical,
            "vscore": vector_score,
            "rerank_text": document["content"],
        })
    out.sort(key=lambda item: (not item["lexical"], -item["vscore"]))
    return out


def _rank(case: dict, documents: list[dict], monkeypatch) -> list[str]:
    candidates = _candidates(documents, case)
    rerank_scores = case["rerank_scores"]
    documents_by_id = {document["id"]: document for document in documents}
    monkeypatch.setattr(search.rag, "search_corpus", lambda _user_id: documents)
    monkeypatch.setattr(
        search.rag,
        "candidates",
        lambda _user_id, _query, k=30: [dict(item) for item in candidates[:k]],
    )
    monkeypatch.setattr(
        search,
        "_rerank_scores",
        lambda _query, items: None
        if case.get("rerank_unavailable")
        else [float(rerank_scores.get(item["id"], 0.0)) for item in items],
    )

    def on_date(_user_id: str, date: str, limit: int) -> list[dict]:
        assert date == case.get("normalized_date")
        return [
            dict(documents_by_id[item_id])
            for item_id in case.get("date_results", [])[:limit]
        ]

    monkeypatch.setattr(search.rag, "on_date", on_date)
    return [
        item["id"]
        for item in search.search(
            "eval-user",
            case["query"],
            limit=int(case.get("limit", 10)),
        )
    ]


def test_search_policy_eval(monkeypatch) -> None:
    fixture = _load()
    documents = fixture["documents"]
    reciprocal_ranks: list[float] = []
    hit_at_1 = 0
    hit_at_3 = 0

    for case in fixture["cases"]:
        ranked = _rank(case, documents, monkeypatch)
        expected_prefix = case["expected_prefix"]
        assert ranked[:len(expected_prefix)] == expected_prefix, (
            f"{case['name']}: expected prefix {expected_prefix}, got {ranked}"
        )
        excluded = set(case.get("excluded", []))
        assert excluded.isdisjoint(ranked), (
            f"{case['name']}: excluded results present in {ranked}"
        )
        if case.get("expected_empty"):
            assert ranked == [], f"{case['name']}: expected no results, got {ranked}"

        relevant = set(case["relevant"])
        if not relevant:
            continue
        first_rank = next(
            (index for index, item_id in enumerate(ranked, start=1) if item_id in relevant),
            None,
        )
        assert first_rank is not None, f"{case['name']}: no relevant result in {ranked}"
        reciprocal_ranks.append(1.0 / first_rank)
        hit_at_1 += int(first_rank <= 1)
        hit_at_3 += int(first_rank <= 3)

    count = len(reciprocal_ranks)
    metrics = {
        "hit@1": hit_at_1 / count,
        "hit@3": hit_at_3 / count,
        "mrr": sum(reciprocal_ranks) / count,
    }
    print(
        "search eval: "
        + " ".join(f"{name}={value:.3f}" for name, value in metrics.items())
    )
    assert metrics == {"hit@1": 1.0, "hit@3": 1.0, "mrr": 1.0}
