import json

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
    frag = {"content": "buy 領収書 today", "embedding": None, "metadata": None}
    rule = {"keywords": ["領収書"], "semantic_query": None, "semantic_threshold": 0.6}

    hit, score = webhook.matches(rule, frag)
    assert hit
    assert score is None  # no semantic query → no score


def test_matches_no_keyword_hit():
    frag = {"content": "nothing relevant here", "embedding": None, "metadata": None}
    rule = {"keywords": ["receipt"], "semantic_query": None, "semantic_threshold": 0.6}

    hit, _ = webhook.matches(rule, frag)
    assert not hit


def test_unconditional_rule_matches_everything():
    frag = {"content": "anything at all", "embedding": None, "metadata": None}
    rule = {"keywords": [], "semantic_query": None, "semantic_threshold": 0.6}

    hit, _ = webhook.matches(rule, frag)
    assert hit


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

        def send(self, request):
            return _Resp()

    monkeypatch.setattr(webhook.httpx, "Client", _Client)
    webhook._post("https://example.com/hook", {"a": 1}, True)

    assert "93.184.216.34" in captured["url"]
    assert captured["headers"]["Host"] == "example.com"
    assert captured["extensions"]["sni_hostname"] == b"example.com"


def test_post_rejects_dns_rebind_to_private(monkeypatch):
    # The hostname now resolves to an internal address (DNS rebind); delivery must
    # refuse before opening any connection.
    monkeypatch.setattr(webhook.socket, "getaddrinfo", _fake_getaddrinfo("10.0.0.5"))
    with pytest.raises(RuntimeError):
        webhook._post("http://rebind.example/hook", {}, True)
