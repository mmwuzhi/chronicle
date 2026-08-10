"""Deterministic precision gate for automatic Related suggestions."""
from __future__ import annotations

from contextlib import ExitStack
from unittest.mock import patch

import rag
import search


THRESHOLDS = {
    "recall_at_5": 0.90,
    "forbidden_false_positive_rate": 0.10,
    "degraded_recall_at_5": 0.75,
}


def validate_fixture(fixture: dict) -> None:
    cases = fixture.get("relatedCases", [])
    if len(cases) < 30:
        raise AssertionError(f"Related evaluation needs at least 30 cases, got {len(cases)}")
    document_ids = {document["id"] for document in fixture["documents"]}
    for case in cases:
        referenced = {
            case["anchor"],
            *case.get("relevant", []),
            *case.get("forbidden", []),
            *case.get("vector_scores", {}).keys(),
        }
        missing = referenced - document_ids
        if missing:
            raise AssertionError(f"{case['name']}: unknown documents {sorted(missing)}")


def rank_case(case: dict, documents: list[dict]) -> list[str]:
    by_id = {document["id"]: document for document in documents}
    vector_scores = case.get("vector_scores", {})
    candidates = [
        {
            **by_id[item_id],
            "lexical": False,
            "vscore": float(score),
            "score": float(score),
            "rerank_text": by_id[item_id]["content"],
        }
        for item_id, score in vector_scores.items()
        if item_id != case["anchor"]
    ]
    candidates.sort(key=lambda item: -item["vscore"])
    rerank_scores = case.get("rerank_scores", {})
    with ExitStack() as stack:
        stack.enter_context(
            patch.object(
                rag,
                "related_candidates",
                return_value=(by_id[case["anchor"]]["content"], candidates),
            ),
        )
        if case.get("rerank_unavailable"):
            stack.enter_context(patch.object(search, "_rerank_scores", return_value=None))
        else:
            stack.enter_context(
                patch.object(
                    search,
                    "_rerank_scores",
                    side_effect=lambda _query, items: [
                        float(rerank_scores.get(item["id"], 0.0))
                        for item in items
                    ],
                ),
            )
        return [item["id"] for item in search.related("related-eval", case["anchor"])]


def evaluate(fixture: dict) -> dict[str, float | int]:
    validate_fixture(fixture)
    recalls: list[float] = []
    degraded_recalls: list[float] = []
    forbidden_returned = 0
    forbidden_total = 0
    for case in fixture["relatedCases"]:
        ranked = rank_case(case, fixture["documents"])
        expected_prefix = case.get("expected_prefix", [])
        if ranked[:len(expected_prefix)] != expected_prefix:
            raise AssertionError(
                f"{case['name']}: expected prefix {expected_prefix}, got {ranked}",
            )
        if case.get("expected_empty") and ranked:
            raise AssertionError(f"{case['name']}: expected no results, got {ranked}")
        relevant = set(case.get("relevant", []))
        forbidden = set(case.get("forbidden", []))
        forbidden_returned += len(forbidden.intersection(ranked[:5]))
        forbidden_total += len(forbidden)
        if relevant:
            recall = len(relevant.intersection(ranked[:5])) / len(relevant)
            recalls.append(recall)
            if case.get("rerank_unavailable"):
                degraded_recalls.append(recall)
    return {
        "scenario_count": len(fixture["relatedCases"]),
        "recall_at_5": sum(recalls) / len(recalls),
        "forbidden_false_positive_rate": forbidden_returned / forbidden_total,
        "degraded_recall_at_5": sum(degraded_recalls) / len(degraded_recalls),
    }


def assert_thresholds(metrics: dict[str, float | int]) -> None:
    for name, threshold in THRESHOLDS.items():
        actual = float(metrics[name])
        if name == "forbidden_false_positive_rate":
            if actual > threshold:
                raise AssertionError(f"{name}={actual:.3f} exceeds {threshold:.3f}")
        elif actual < threshold:
            raise AssertionError(f"{name}={actual:.3f} is below {threshold:.3f}")
