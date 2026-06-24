#!/usr/bin/env python3
"""Detect locally available AI backends — for settings display ("which AI is
present, which feature uses which") and for the rerank 'auto' mode.

Read-only, side-effect-free, never raises:
  - claude: is the CLI on PATH (analysis's `claude -p` relies on it).
  - ollama: hit /api/tags for downloaded models (urllib + timeout, no dependency
    on the ollama package just to probe).
"""
from __future__ import annotations

import json
import os
import shutil
import urllib.request

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")


def claude_available() -> bool:
    return shutil.which("claude") is not None


def api_available() -> bool:
    """An OpenAI-compatible key is configured → the api backend can run. Boolean
    only; the key itself is never returned."""
    return bool(os.getenv("OPENAI_API_KEY"))


def _ollama_status() -> tuple[bool, list[str]]:
    try:
        with urllib.request.urlopen(f"{OLLAMA_BASE_URL}/api/tags", timeout=2) as r:
            data = json.load(r)
        return True, [m["name"] for m in data.get("models", []) if "name" in m]
    except Exception:
        return False, []


def detect_backends() -> dict:
    """{claude:{available}, api:{available}, ollama:{available, models[]}}.
    Read-only, never raises."""
    ok, models = _ollama_status()
    return {
        "claude": {"available": claude_available()},
        "api": {"available": api_available()},
        "ollama": {"available": ok, "models": models},
    }
