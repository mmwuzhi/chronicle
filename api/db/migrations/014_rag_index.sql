-- +goose Up

-- Derived RAG index over captures. Owned by the Python ragsvc sidecar, which
-- reads captures and writes these two tables. embedding is a raw float32 byte
-- blob (same approach as the rag project's SQLite BLOB): ragsvc loads all of a
-- user's vectors and does an exact numpy cosine scan. pgvector is the documented
-- scale-up trigger, deliberately deferred. user_id is denormalized for fast
-- per-user load and so ragsvc never needs to join back to captures for scoping.

CREATE TABLE capture_embeddings (
  capture_id  UUID PRIMARY KEY REFERENCES captures(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  embedding   BYTEA NOT NULL,
  model       TEXT NOT NULL,
  embed_v     INTEGER NOT NULL DEFAULT 1,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX capture_embeddings_user_idx ON capture_embeddings(user_id);

CREATE TABLE capture_metadata (
  capture_id  UUID PRIMARY KEY REFERENCES captures(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  data        JSONB NOT NULL DEFAULT '{}',
  extract_v   INTEGER NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX capture_metadata_user_idx ON capture_metadata(user_id);

-- Runtime config for the RAG service (e.g. rerank_backend). Global, single-row
-- key/value; mirrors the rag project's app_config so search can switch the
-- rerank backend without an env change + restart.
CREATE TABLE rag_config (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- +goose Down

DROP TABLE IF EXISTS rag_config;
DROP TABLE IF EXISTS capture_metadata;
DROP TABLE IF EXISTS capture_embeddings;
