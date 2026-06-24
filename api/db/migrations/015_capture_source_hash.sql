-- +goose Up

-- Track which content version each derived row was built from, so the RAG
-- backfill can detect *stale* embeddings/metadata (a capture edited while the
-- sidecar was down keeps its old vector) — not just missing ones. The sidecar
-- stores md5 of the capture's indexable content here and backfill re-indexes any
-- row whose stored hash no longer matches the current content.

ALTER TABLE capture_embeddings ADD COLUMN source_hash TEXT;
ALTER TABLE capture_metadata ADD COLUMN source_hash TEXT;

-- +goose Down

ALTER TABLE capture_metadata DROP COLUMN IF EXISTS source_hash;
ALTER TABLE capture_embeddings DROP COLUMN IF EXISTS source_hash;
