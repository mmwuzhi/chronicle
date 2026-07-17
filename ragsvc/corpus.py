"""In-memory corpus structures and vector math for Chronicle retrieval."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Snapshot:
    """One user's decoded corpus and its lazily-built chunk matrix."""

    rows: list[dict]
    model: str
    built_at: float
    chunk_mat: np.ndarray | None = None
    chunk_owner: np.ndarray | None = None
    chunk_txt: list | None = None
    chunk_dim: int = 0


def snapshot_chunks(snapshot: Snapshot, dim: int, active_model: str):
    """Flatten active-model chunks into a matrix plus owner/text mappings."""
    if snapshot.chunk_mat is not None and snapshot.chunk_dim == dim:
        return snapshot.chunk_mat, snapshot.chunk_owner, snapshot.chunk_txt
    vectors: list[np.ndarray] = []
    owners: list[int] = []
    texts: list = []
    for index, row in enumerate(snapshot.rows):
        if row.get("model") != active_model:
            continue
        for embedding, text in zip(
            row.get("chunks") or [], row.get("chunk_texts") or []
        ):
            if embedding and len(embedding) // 4 == dim:
                vectors.append(np.frombuffer(embedding, dtype=np.float32))
                owners.append(index)
                texts.append(text)
    matrix = (
        np.vstack(vectors)
        if vectors
        else np.zeros((0, dim), dtype=np.float32)
    )
    owner = np.asarray(owners, dtype=np.int64)
    snapshot.chunk_mat = matrix
    snapshot.chunk_owner = owner
    snapshot.chunk_txt = texts
    snapshot.chunk_dim = dim
    return matrix, owner, texts


def cosines(matrix: np.ndarray, query_vector: np.ndarray) -> np.ndarray:
    """Exact cosine similarity. Zero-vector rows score zero."""
    if matrix.size == 0:
        return np.zeros(0, dtype=np.float32)
    normalized_query = query_vector / (np.linalg.norm(query_vector) or 1.0)
    norms = np.linalg.norm(matrix, axis=1)
    norms[norms == 0] = 1.0
    return (matrix @ normalized_query) / norms


def capture_max_sims(
    snapshot: Snapshot, query_vector: np.ndarray, active_model: str
):
    """Return max chunk cosine and best matching chunk text per capture."""
    matrix, owner, texts = snapshot_chunks(
        snapshot, len(query_vector), active_model
    )
    best = np.zeros(len(snapshot.rows), dtype=np.float32)
    best_text: list = [None] * len(snapshot.rows)
    if not matrix.shape[0]:
        return best, best_text

    similarities = cosines(matrix, query_vector)
    np.maximum.at(best, owner, similarities)
    order = np.lexsort((similarities, owner))
    sorted_owners = owner[order]
    group_last = np.flatnonzero(
        np.r_[sorted_owners[1:] != sorted_owners[:-1], True]
    )
    for position in group_last:
        chunk_index = int(order[position])
        row_index = int(sorted_owners[position])
        if (
            texts[chunk_index] is not None
            and float(similarities[chunk_index]) == float(best[row_index])
        ):
            best_text[row_index] = texts[chunk_index]
    return best, best_text
