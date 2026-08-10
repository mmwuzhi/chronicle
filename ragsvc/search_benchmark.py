#!/usr/bin/env python3
"""Run the committed retrieval corpus with fixed scores or live model scores."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from search_eval import assert_thresholds, evaluate, load_fixture
from related_eval import assert_thresholds as assert_related_thresholds
from related_eval import evaluate as evaluate_related


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="use configured embedding/rerank backends")
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path(__file__).parent / "tests" / "fixtures" / "search-baseline.json",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    fixture = load_fixture()
    metrics = evaluate(fixture, live=args.live)
    report = {
        "mode": "live" if args.live else "fixed",
        "metrics": metrics,
    }
    if not args.live:
        report["related_metrics"] = evaluate_related(fixture)
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    print(encoded, end="")
    if args.output:
        args.output.write_text(encoded)

    if not args.live:
        assert_thresholds(metrics)
        assert_related_thresholds(report["related_metrics"])
        return 0

    baseline = json.loads(args.baseline.read_text())["metrics"]
    regressions: list[str] = []
    for name in (
        "exact_recall_at_5",
        "recall_at_10",
        "mrr_at_10",
        "degraded_recall_at_10",
    ):
        if float(metrics[name]) < float(baseline[name]) - 0.02:
            regressions.append(
                f"{name}: {float(metrics[name]):.3f} < "
                f"{float(baseline[name]) - 0.02:.3f}",
            )
    false_positive_limit = float(baseline["forbidden_false_positive_rate"]) + 0.02
    if float(metrics["forbidden_false_positive_rate"]) > false_positive_limit:
        regressions.append(
            "forbidden_false_positive_rate: "
            f"{float(metrics['forbidden_false_positive_rate']):.3f} > "
            f"{false_positive_limit:.3f}",
        )
    if regressions:
        raise SystemExit("live search benchmark regressed:\n" + "\n".join(regressions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
