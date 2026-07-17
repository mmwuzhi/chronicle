import search


def test_snippet_centers_literal_match_and_caps_length():
    text = "前文" * 80 + "目标短语" + "后文" * 80
    snippet = search._snippet(text, "目标短语", max_chars=60)
    assert "目标短语" in snippet
    assert snippet.startswith("…") and snippet.endswith("…")
    assert len(snippet.removeprefix("…").removesuffix("…")) <= 60


def test_public_results_expose_evidence_and_hide_internal_fields():
    result = search._public_results(
        [{
            "id": "one",
            "content": "whole capture",
            "rerank_text": "best matching chunk",
            "created_at": "2026-07-16T00:00:00Z",
            "modality": "text",
            "score": 0.8,
            "lexical": False,
            "vscore": 0.9,
        }],
        "matching",
    )[0]
    assert result["snippet"] == "best matching chunk"
    assert "rerank_text" not in result
    assert "vscore" not in result
