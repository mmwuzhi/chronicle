"""Reusable deterministic and live retrieval-quality evaluation."""
from __future__ import annotations

import json
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

import numpy as np

import rag
import search


DEFAULT_FIXTURE = Path(__file__).parent / "tests" / "fixtures" / "search-eval.json"
REQUIRED_CATEGORIES = {
    "exact",
    "typo",
    "punctuation",
    "paraphrase",
    "long_chunk",
    "date",
    "weak_semantic",
    "degraded",
}
THRESHOLDS = {
    "exact_recall_at_5": 1.0,
    "recall_at_10": 0.90,
    "mrr_at_10": 0.80,
    "forbidden_false_positive_rate": 0.10,
    "degraded_recall_at_10": 0.75,
}


def load_fixture(path: Path = DEFAULT_FIXTURE) -> dict:
    fixture = json.loads(path.read_text())
    documents: list[dict] = []
    for source in fixture["documents"]:
        document = dict(source)
        repeat = document.pop("prefixRepeat", None)
        count = int(document.pop("prefixCount", 0))
        if repeat and count:
            document["content"] = (repeat * count) + document["content"]
        documents.append(document)
    fixture["documents"] = documents
    presets = fixture.get("scorePresets", {})
    fixture["cases"] = [
        {**presets.get(case.get("preset"), {}), **case}
        for case in fixture["cases"]
    ]
    return fixture


def validate_fixture(fixture: dict) -> None:
    cases = fixture["cases"]
    if len(cases) < 40:
        raise AssertionError(f"search evaluation needs at least 40 cases, got {len(cases)}")
    categories = {category for case in cases for category in case["categories"]}
    missing = REQUIRED_CATEGORIES - categories
    if missing:
        raise AssertionError(f"search evaluation is missing categories: {sorted(missing)}")
    languages = {case["language"] for case in cases}
    if languages != {"en", "ja", "zh"}:
        raise AssertionError(f"expected en/ja/zh cases, got {sorted(languages)}")
    long_documents = [
        document
        for document in fixture["documents"]
        if len(document["content"]) > rag.CHUNK_CHARS
    ]
    if not long_documents:
        raise AssertionError("search evaluation has no capture large enough to chunk")


def _fixture_candidates(documents: list[dict], case: dict) -> list[dict]:
    query = case["query"].lower()
    vector_scores = {} if case.get("embedding_unavailable") else case.get("vector_scores", {})
    candidates: list[dict] = []
    for document in documents:
        lexical = query in document["content"].lower()
        vector_score = float(vector_scores.get(document["id"], 0.0))
        if not lexical and vector_score < rag.CANDIDATE_FLOOR:
            continue
        candidates.append({
            **document,
            "lexical": lexical,
            "vscore": vector_score,
            "rerank_text": document["content"],
        })
    candidates.sort(key=lambda item: (not item["lexical"], -item["vscore"]))
    return candidates


def _live_vector_scores(
    query: str,
    documents: list[dict],
    document_chunks: list[tuple[list[str], np.ndarray]],
) -> tuple[dict[str, float], dict[str, str]]:
    query_vector = rag.embed(query)
    scores: dict[str, float] = {}
    best_text: dict[str, str] = {}
    for document, (chunks, matrix) in zip(documents, document_chunks, strict=True):
        similarities = rag._cosines(matrix, query_vector)
        best_index = int(np.argmax(similarities))
        scores[document["id"]] = float(similarities[best_index])
        best_text[document["id"]] = chunks[best_index]
    return scores, best_text


def rank_case(
    case: dict,
    documents: list[dict],
    live: bool = False,
    live_document_chunks: list[tuple[list[str], np.ndarray]] | None = None,
) -> list[str]:
    evaluated = dict(case)
    live_best_text: dict[str, str] = {}
    if live and not case.get("embedding_unavailable"):
        if live_document_chunks is None:
            raise ValueError("live evaluation requires precomputed document embeddings")
        evaluated["vector_scores"], live_best_text = _live_vector_scores(
            case["query"],
            documents,
            live_document_chunks,
        )
    candidates = _fixture_candidates(documents, evaluated)
    for candidate in candidates:
        candidate["rerank_text"] = live_best_text.get(
            candidate["id"],
            candidate["rerank_text"],
        )
    rerank_scores = evaluated.get("rerank_scores", {})
    by_id = {document["id"]: document for document in documents}

    def on_date(
        _user_id: str, date: str, limit: int, _excluded_ids: set[str] | None = None,
    ) -> list[dict]:
        if date != evaluated.get("normalized_date"):
            return []
        return [
            dict(by_id[item_id])
            for item_id in evaluated.get("date_results", [])[:limit]
        ]

    with ExitStack() as stack:
        stack.enter_context(patch.object(rag, "search_corpus", return_value=documents))
        stack.enter_context(
            patch.object(
                rag,
                "candidates",
                return_value=[dict(item) for item in candidates[:30]],
            ),
        )
        stack.enter_context(patch.object(rag, "on_date", side_effect=on_date))
        if evaluated.get("rerank_unavailable"):
            stack.enter_context(patch.object(search, "_rerank_scores", return_value=None))
        elif not live:
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
        return [
            item["id"]
            for item in search.search("search-eval", evaluated["query"], limit=10)
        ]


def _recall(ranked: list[str], relevant: set[str], limit: int) -> float:
    if not relevant:
        return 1.0
    return len(relevant.intersection(ranked[:limit])) / len(relevant)


def evaluate(fixture: dict, live: bool = False) -> dict[str, float | int]:
    validate_fixture(fixture)
    documents = fixture["documents"]
    live_document_chunks = None
    if live:
        live_document_chunks = []
        for document in documents:
            chunks = rag.chunk_content(document["content"])
            live_document_chunks.append((
                chunks,
                np.stack([rag.embed(chunk) for chunk in chunks]),
            ))
    all_recalls: list[float] = []
    exact_recalls: list[float] = []
    degraded_recalls: list[float] = []
    reciprocal_ranks: list[float] = []
    forbidden_returned = 0
    forbidden_total = 0

    for case in fixture["cases"]:
        ranked = rank_case(
            case,
            documents,
            live=live,
            live_document_chunks=live_document_chunks,
        )
        expected_prefix = case.get("expected_prefix", [])
        if not live and ranked[:len(expected_prefix)] != expected_prefix:
            raise AssertionError(
                f"{case['name']}: expected prefix {expected_prefix}, got {ranked}",
            )
        relevant = set(case.get("relevant", []))
        forbidden = set(case.get("forbidden", []))
        if not live and case.get("expected_empty") and ranked:
            raise AssertionError(f"{case['name']}: expected no results, got {ranked}")
        forbidden_returned += len(forbidden.intersection(ranked[:10]))
        forbidden_total += len(forbidden)
        if not relevant:
            continue
        recall = _recall(ranked, relevant, 10)
        all_recalls.append(recall)
        categories = set(case["categories"])
        if "exact" in categories:
            exact_recalls.append(_recall(ranked, relevant, 5))
        if "degraded" in categories:
            degraded_recalls.append(recall)
        first_rank = next(
            (index for index, item_id in enumerate(ranked[:10], 1) if item_id in relevant),
            None,
        )
        reciprocal_ranks.append(0.0 if first_rank is None else 1.0 / first_rank)

    return {
        "scenario_count": len(fixture["cases"]),
        "exact_recall_at_5": sum(exact_recalls) / len(exact_recalls),
        "recall_at_10": sum(all_recalls) / len(all_recalls),
        "mrr_at_10": sum(reciprocal_ranks) / len(reciprocal_ranks),
        "forbidden_false_positive_rate": (
            forbidden_returned / forbidden_total if forbidden_total else 0.0
        ),
        "degraded_recall_at_10": (
            sum(degraded_recalls) / len(degraded_recalls)
        ),
    }


def assert_thresholds(metrics: dict[str, float | int]) -> None:
    for name, threshold in THRESHOLDS.items():
        actual = float(metrics[name])
        if name == "forbidden_false_positive_rate":
            if actual > threshold:
                raise AssertionError(f"{name}={actual:.3f} exceeds {threshold:.3f}")
        elif actual < threshold:
            raise AssertionError(f"{name}={actual:.3f} is below {threshold:.3f}")
