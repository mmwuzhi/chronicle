import json

import httpx
import numpy as np
import pytest

import webhook


def test_render_json_value_level_substitution():
    frag = {
        "content": 'has "quotes"\nand a newline',
        "id": "abc",
        "created_at": "2026-06-18T00:00:00Z",
        "metadata": {"amount": 1630, "currency": "JPY"},
    }
    template = json.dumps({
        "text": "[capture.text]",
        "amount": "[capture.metadata.amount]",
        "meta": "[capture.metadata]",
        "mixed": "id=[capture.id]",
    })
    payload, is_json = webhook.render(template, frag)

    assert is_json
    # Whole-value placeholders keep their native type.
    assert payload["text"] == 'has "quotes"\nand a newline'
    assert payload["amount"] == 1630
    assert payload["meta"] == {"amount": 1630, "currency": "JPY"}
    # An embedded placeholder is string-concatenated.
    assert payload["mixed"] == "id=abc"
    # Quotes/newlines in content didn't break the payload — still valid JSON.
    json.dumps(payload)


def test_render_missing_placeholder_is_null_or_empty():
    frag = {"content": "x", "id": "1", "created_at": None, "metadata": {}}

    payload, is_json = webhook.render(json.dumps({"m": "[capture.metadata.nope]"}), frag)
    assert is_json
    assert payload["m"] is None

    text, is_json2 = webhook.render("note: [capture.metadata.nope]", frag)
    assert not is_json2
    assert text == "note: "


def test_matches_keyword_substring():
    frag = {"content": "buy 領収書 today", "embeddings": [], "metadata": None}
    rule = {"keywords": ["領収書"], "semantic_query": None, "semantic_threshold": 0.6}

    hit, score = webhook.matches(rule, frag)
    assert hit
    assert score is None  # no semantic query → no score


def test_matches_no_keyword_hit():
    frag = {"content": "nothing relevant here", "embeddings": [], "metadata": None}
    rule = {"keywords": ["receipt"], "semantic_query": None, "semantic_threshold": 0.6}

    hit, _ = webhook.matches(rule, frag)
    assert not hit


def test_unconditional_rule_matches_everything():
    frag = {"content": "anything at all", "embeddings": [], "metadata": None}
    rule = {"keywords": [], "semantic_query": None, "semantic_threshold": 0.6}

    hit, _ = webhook.matches(rule, frag)
    assert hit


def test_matches_semantic_scores_best_chunk(monkeypatch):
    # A rule fires when ANY chunk of a long capture is close enough — the score is
    # the max cosine over the capture's chunks, not a whole-document average.
    monkeypatch.setattr(webhook.rag, "active_embed_model", lambda: "m")
    aligned = np.array([1.0, 0.0], dtype=np.float32)   # cosine 1.0 with the query
    orthog = np.array([0.0, 1.0], dtype=np.float32)    # cosine 0.0
    monkeypatch.setattr(webhook, "_rule_embedding", lambda q: aligned)
    frag = {"content": "long capture", "metadata": None,
            "embeddings": [orthog.tobytes(), aligned.tobytes()]}
    rule = {"keywords": [], "semantic_query": "topic", "semantic_threshold": 0.6}

    hit, score = webhook.matches(rule, frag)
    assert hit
    assert abs(score - 1.0) < 1e-6      # best (second) chunk, not the first


def test_resolve_and_vet_blocks_internal_targets():
    # Numeric IPs resolve without DNS, so this stays offline.
    for url in [
        "http://127.0.0.1/x",
        "http://10.0.0.5/hook",
        "http://192.168.1.1/x",
        "http://169.254.169.254/latest/meta-data",  # cloud metadata
        "http://[::1]/x",
    ]:
        with pytest.raises(RuntimeError):
            webhook._resolve_and_vet(url)


def _fake_getaddrinfo(addr):
    return lambda *a, **k: [(2, 1, 6, "", (addr, 0))]


def test_post_pins_connection_to_vetted_ip(monkeypatch):
    # A public host resolves to a public IP; _post must connect to that exact IP
    # while keeping the hostname for the Host header and TLS SNI, so a second
    # lookup can't rebind the connection to an internal address.
    monkeypatch.setattr(webhook.socket, "getaddrinfo", _fake_getaddrinfo("93.184.216.34"))
    captured: dict = {}

    class _Resp:
        def raise_for_status(self):
            pass

        def close(self):
            captured["closed"] = True

    class _Client:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def build_request(self, method, url, **kw):
            captured.update(url=url, headers=kw.get("headers"),
                            extensions=kw.get("extensions"))
            return object()

        def send(self, request, **kw):
            captured["stream"] = kw.get("stream")
            return _Resp()

    monkeypatch.setattr(webhook.httpx, "Client", _Client)
    webhook._post("https://example.com/hook", {"a": 1}, True)

    assert "93.184.216.34" in captured["url"]
    assert captured["headers"]["Host"] == "example.com"
    assert captured["extensions"]["sni_hostname"] == b"example.com"
    assert captured["stream"] is True
    assert captured["closed"] is True


def test_post_rejects_dns_rebind_to_private(monkeypatch):
    # The hostname now resolves to an internal address (DNS rebind); delivery must
    # refuse before opening any connection.
    monkeypatch.setattr(webhook.socket, "getaddrinfo", _fake_getaddrinfo("10.0.0.5"))
    with pytest.raises(RuntimeError):
        webhook._post("https://rebind.example/hook", {}, True)


def test_post_rejects_plaintext_http_before_resolution(monkeypatch):
    resolve = monkeypatch.setattr(
        webhook, "_resolve_and_vet", lambda _url: (_ for _ in ()).throw(
            AssertionError("HTTP target must be rejected before DNS")
        )
    )
    assert resolve is None
    with pytest.raises(RuntimeError, match="must use https"):
        webhook._post("http://example.com/hook", {}, True)


def test_delivery_log_never_prints_target_query_secret(monkeypatch, capsys):
    secret_url = "https://hooks.example/path?token=super-secret"
    rule = {
        "id": "rule-1", "name": "safe name", "target_url": secret_url,
        "keywords": [], "semantic_query": None, "semantic_threshold": 0.6,
        "payload_template": "{}",
    }
    frag = {"content": "x", "embeddings": [], "metadata": None}
    monkeypatch.setattr(webhook.rag, "webhooks_enabled", lambda _user: [rule])
    monkeypatch.setattr(webhook.rag, "get_fragment", lambda _capture, _user: frag)

    request = httpx.Request("POST", secret_url)
    response = httpx.Response(500, request=request)
    monkeypatch.setattr(
        webhook, "_post",
        lambda *_args: (_ for _ in ()).throw(
            httpx.HTTPStatusError("failed", request=request, response=response)),
    )

    webhook.fire("capture-1", "user-1")
    logged = capsys.readouterr().err
    assert "http_500" in logged
    assert "super-secret" not in logged
    assert secret_url not in logged
