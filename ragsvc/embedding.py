"""Embedding providers and deterministic text chunking."""
from __future__ import annotations

import json
import os
import urllib.request

import numpy as np
import ollama

_OLLAMA_CLIENTS: dict[str, ollama.Client] = {}


def ollama_embed(text: str, model: str, base_url: str) -> np.ndarray:
    """Embed through a shared local Ollama client."""
    client = _OLLAMA_CLIENTS.get(base_url)
    if client is None:
        client = ollama.Client(host=base_url, trust_env=False)
        _OLLAMA_CLIENTS[base_url] = client
    response = client.embeddings(model=model, prompt=text[:4096])
    return np.array(response["embedding"], dtype=np.float32)


def openai_embed(text: str, model: str) -> np.ndarray:
    """Embed through an OpenAI-compatible ``/v1/embeddings`` endpoint."""
    base = (
        os.getenv("EMBED_BASE_URL")
        or os.getenv("OPENAI_BASE_URL")
        or "https://api.openai.com/v1"
    ).rstrip("/")
    key = os.getenv("EMBED_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
    if not key:
        raise RuntimeError(
            "embedding API key not configured (EMBED_API_KEY/OPENAI_API_KEY)"
        )
    body = json.dumps({"input": text[:8000], "model": model}).encode()
    request = urllib.request.Request(
        f"{base}/embeddings",
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
    return np.array(data["data"][0]["embedding"], dtype=np.float32)


def chunk_content(text: str, chunk_chars: int, overlap: int) -> list[str]:
    """Split text into deterministic overlapping character windows."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= chunk_chars:
        return [text]
    step = max(1, chunk_chars - overlap)
    chunks: list[str] = []
    for start in range(0, len(text), step):
        piece = text[start : start + chunk_chars].strip()
        if piece:
            chunks.append(piece)
        if start + chunk_chars >= len(text):
            break
    return chunks
