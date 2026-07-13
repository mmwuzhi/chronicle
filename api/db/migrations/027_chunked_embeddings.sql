-- +goose Up

-- Chunked embeddings. A capture's indexable content is now split into
-- overlapping windows, each embedded on its own, so a long capture (a fetched
-- link page, a long transcript) is findable by ANY of its parts instead of
-- through a single whole-document vector that blurs them together. Short
-- captures stay a single chunk — identical to the pre-chunking behaviour.
--
-- capture_embeddings goes from one row per capture to one row per
-- (capture_id, chunk_idx). chunk_text keeps the exact fragment so retrieval can
-- hand the matched piece — not the document's truncated opening — to the
-- reranker. model / source_hash stay per row but are written identically across
-- a capture's chunks (index_capture replaces the whole set in one transaction).
--
-- embed_v marks the format: existing rows are embed_v=1 (single vector,
-- chunk_idx 0, chunk_text NULL); the sidecar now writes embed_v=2, and
-- needs_index treats embed_v<2 as stale, so a one-time `just rag-backfill`
-- re-chunks the whole corpus after this migration. Until then old single-vector
-- rows still serve recall (they keep a valid model + source_hash), so search
-- never goes dark during the transition.

ALTER TABLE capture_embeddings DROP CONSTRAINT capture_embeddings_pkey;
ALTER TABLE capture_embeddings ADD COLUMN chunk_idx INTEGER NOT NULL DEFAULT 0;
ALTER TABLE capture_embeddings ADD COLUMN chunk_text TEXT;
ALTER TABLE capture_embeddings ADD PRIMARY KEY (capture_id, chunk_idx);

-- +goose Down

-- The pre-chunk service cannot distinguish chunk 0 from a whole-document vector:
-- model/source_hash still look current, so retaining chunk 0 would make its
-- backfill incorrectly skip long captures. Drop every derived vector; the old
-- needs_index path then sees a missing row and rebuilds one full-document vector.
ALTER TABLE capture_embeddings DROP CONSTRAINT capture_embeddings_pkey;
DELETE FROM capture_embeddings;
ALTER TABLE capture_embeddings DROP COLUMN chunk_text;
ALTER TABLE capture_embeddings DROP COLUMN chunk_idx;
ALTER TABLE capture_embeddings ADD PRIMARY KEY (capture_id);
