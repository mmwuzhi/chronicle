"""Hermetic retrieval-quality gate with fixed embedding and rerank scores."""
from __future__ import annotations

from search_eval import THRESHOLDS, assert_thresholds, evaluate, load_fixture


def test_search_quality_baseline() -> None:
    metrics = evaluate(load_fixture())
    print(
        "search eval: "
        + " ".join(
            f"{name}={value:.3f}" if isinstance(value, float) else f"{name}={value}"
            for name, value in metrics.items()
        ),
    )
    assert metrics["scenario_count"] >= 40
    assert_thresholds(metrics)
    assert metrics == {
        "scenario_count": 43,
        "exact_recall_at_5": 1.0,
        "recall_at_10": 1.0,
        "mrr_at_10": 1.0,
        "forbidden_false_positive_rate": 0.0,
        "degraded_recall_at_10": 1.0,
    }
    assert THRESHOLDS == {
        "exact_recall_at_5": 1.0,
        "recall_at_10": 0.90,
        "mrr_at_10": 0.80,
        "forbidden_false_positive_rate": 0.10,
        "degraded_recall_at_10": 0.75,
    }
