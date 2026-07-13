#!/usr/bin/env python3
"""capture matches a rule → POST to an external URL (fire-and-forget).

Ported from the rag project's webhook.py. Triggered at the tail of _index_one
(app.py) after embedding + extraction, when content, embedding and metadata are
all available. A single rule's failure only logs to stderr — capture indexing
and the other background tasks must never be blocked by an external endpoint.

Match = (any keyword is a substring of content) OR (semantic cosine >=
threshold). A rule with neither condition matches every capture. Semantic
matching is not precise — the threshold depends on the embedding model; build a
rule, then tune with POST /webhooks/{id}/test to inspect the score.

payload templates use [capture.*] placeholders. When the template is valid JSON,
substitution is value-level: a string value that is exactly one placeholder is
replaced with the native type (amount stays a number, metadata stays an object,
missing → null); a placeholder embedded in a string is string-concatenated
(missing → empty). So quotes/newlines in content can never break the payload
JSON. A non-JSON template degrades to plain text/plain substitution.

Workflow automation, normally avoided per the product guardrails; present at
explicit user request.
"""
from __future__ import annotations

import ipaddress
import json
import re
import socket
import sys
from urllib.parse import urlparse

import httpx
import numpy as np

import rag

TIMEOUT = 5.0  # the background chain is serial: a slow POST only delays the next

_PLACEHOLDER = re.compile(r"\[capture\.([A-Za-z0-9_.一-鿿]+)\]")

# semantic_query → embedding cache, so a distinct query is embedded once per
# process rather than once per capture. Keyed by (query, model).
_EMBED_CACHE: dict[tuple[str, str], np.ndarray] = {}


def _value(frag: dict, path: str) -> object:
    """Placeholder path → capture field value. Unknown/missing → None."""
    if path == "text":
        return frag["content"]
    if path in ("id", "created_at"):
        return frag.get(path)
    if path == "metadata":
        return frag.get("metadata") or {}
    if path.startswith("metadata."):
        return (frag.get("metadata") or {}).get(path[len("metadata."):])
    return None


def _as_str(v: object) -> str:
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def _render_node(node: object, frag: dict) -> object:
    if isinstance(node, str):
        m = _PLACEHOLDER.fullmatch(node)
        if m:  # whole-value placeholder: keep the native type
            return _value(frag, m.group(1))
        return _PLACEHOLDER.sub(lambda mm: _as_str(_value(frag, mm.group(1))), node)
    if isinstance(node, list):
        return [_render_node(x, frag) for x in node]
    if isinstance(node, dict):
        return {k: _render_node(v, frag) for k, v in node.items()}
    return node


def render(template: str, frag: dict) -> tuple[object, bool]:
    """Render the payload, returning (payload, is_json)."""
    try:
        parsed = json.loads(template)
    except ValueError:
        return _PLACEHOLDER.sub(
            lambda m: _as_str(_value(frag, m.group(1))), template), False
    return _render_node(parsed, frag), True


def _rule_embedding(query: str) -> np.ndarray:
    model = rag.active_embed_model()
    key = (query, model)
    if key not in _EMBED_CACHE:
        _EMBED_CACHE[key] = rag.embed(query).astype(np.float32)
    return _EMBED_CACHE[key]


def matches(rule: dict, frag: dict) -> tuple[bool, float | None]:
    """Whether a rule matches a capture, with the semantic cosine score (or None).

    The score is computed regardless of the verdict and returned so /test can
    surface it for threshold tuning."""
    score = None
    sq = rule.get("semantic_query")
    embs = frag.get("embeddings") or []
    if sq and embs:
        # Score against the best-matching chunk: a rule should fire when any part
        # of a long capture is semantically close, not only when the whole-document
        # average is. Mirrors retrieval's max-over-chunks aggregation.
        a = _rule_embedding(sq)
        an = float(np.linalg.norm(a)) or 1.0
        for e in embs:
            b = np.frombuffer(e, dtype=np.float32)
            if a.shape != b.shape:  # dims differ across embedding models → skip
                continue
            s = float(a @ b) / (an * (float(np.linalg.norm(b)) or 1.0))
            if score is None or s > score:
                score = s
    keywords = rule.get("keywords") or []
    if not keywords and not sq:
        return True, score  # unconditional rule = match everything
    if any(k in frag["content"] for k in keywords):
        return True, score
    if score is not None and score >= rule["semantic_threshold"]:
        return True, score
    return False, score


def _resolve_and_vet(url: str) -> str:
    """Resolve the URL host once, refuse private/loopback/link-local destinations,
    and return the vetted IP to connect to.

    The Go validator blocks literal private IPs at save time, but a hostname can
    resolve (or DNS-rebind) to an internal address, so the delivery point must
    re-check. Returning the exact IP we vetted — so the caller connects to it
    instead of resolving again — closes the DNS-rebind window where a second
    lookup at connection time could hand back an internal address. Raises on a
    disallowed or unresolvable host; the caller logs and skips delivery."""
    host = urlparse(url).hostname or ""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as e:
        raise RuntimeError(f"host does not resolve: {host}") from e
    vetted: str | None = None
    for info in infos:
        addr = info[4][0]
        ip = ipaddress.ip_address(addr)
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast or ip.is_unspecified):
            raise RuntimeError(f"target resolves to a disallowed address: {ip}")
        if vetted is None:
            vetted = addr
    if vetted is None:
        raise RuntimeError(f"host does not resolve: {host}")
    return vetted


def _post(url: str, payload: object, is_json: bool) -> None:
    parts = urlparse(url)
    host = parts.hostname or ""
    ip = _resolve_and_vet(url)
    # Connect to the exact IP we just vetted so a second DNS lookup can't rebind
    # the connection to an internal address; keep the hostname for the Host header,
    # TLS SNI and certificate verification. follow_redirects=False so a 30x can't
    # bounce delivery to an unvetted host either.
    netloc = f"[{ip}]" if ":" in ip else ip
    if parts.port is not None:
        netloc = f"{netloc}:{parts.port}"
    pinned_url = parts._replace(netloc=netloc).geturl()
    headers = {"Host": host}
    extensions = {"sni_hostname": host.encode("ascii")} if parts.scheme == "https" else {}
    with httpx.Client(timeout=TIMEOUT, follow_redirects=False) as client:
        if is_json:
            request = client.build_request("POST", pinned_url, json=payload,
                                           headers=headers, extensions=extensions)
        else:
            headers["Content-Type"] = "text/plain; charset=utf-8"
            request = client.build_request("POST", pinned_url,
                                           content=str(payload).encode("utf-8"),
                                           headers=headers, extensions=extensions)
        # Do not buffer an untrusted response body. Webhook delivery only needs
        # the status line; httpx's default stream=False would read an arbitrarily
        # large or never-ending body into memory before returning.
        r = client.send(request, stream=True)
        try:
            r.raise_for_status()
        finally:
            r.close()


def _delivery_error_category(error: Exception) -> str:
    """Stable diagnostics that never stringify a URL-bearing HTTPX exception."""
    if isinstance(error, httpx.HTTPStatusError):
        return f"http_{error.response.status_code}"
    if isinstance(error, httpx.TimeoutException):
        return "timeout"
    if isinstance(error, httpx.NetworkError):
        return "network"
    if isinstance(error, RuntimeError):
        return "target_rejected"
    return "delivery_failed"


def fire(capture_id: str, user_id: str) -> None:
    """Run every enabled rule for one capture: match → render → deliver.

    A single rule's failure only logs and continues to the next; this never
    raises — the capture flow and the other background tasks on the chain must
    not be affected by an external endpoint's health."""
    try:
        rules = rag.webhooks_enabled(user_id)
        if not rules:
            return
        frag = rag.get_fragment(capture_id, user_id)
    except Exception as e:  # noqa: BLE001 — best-effort, never break indexing
        print(f"[webhook] {capture_id} rule load failed: {e}", file=sys.stderr)
        return
    if frag is None:  # deleted before delivery
        return
    for rule in rules:
        try:
            hit, _ = matches(rule, frag)
            if not hit:
                continue
            payload, is_json = render(rule["payload_template"], frag)
            _post(rule["target_url"], payload, is_json)
        except Exception as e:  # noqa: BLE001
            # HTTPX errors include the full target URL, which may carry a webhook
            # secret in its query string. Log identity + category only.
            print(f"[webhook] {capture_id} rule '{rule['name']}' delivery failed "
                  f"({_delivery_error_category(e)})", file=sys.stderr)
