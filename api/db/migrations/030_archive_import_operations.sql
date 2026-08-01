-- +goose Up

-- Durable identity for an archive import. The operation UUID is supplied by
-- the client and makes an ambiguous retry safe: a completed import replays its
-- stored result, while an expired/failed operation with the same archive hash
-- can be reclaimed.
CREATE TABLE IF NOT EXISTS archive_import_operations (
  id           UUID        PRIMARY KEY,
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  archive_hash TEXT        NOT NULL,
  claim_token  UUID        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'processing',
  lease_until  TIMESTAMPTZ NOT NULL,
  id_map       JSONB,
  result       JSONB,
  last_error   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,

  CONSTRAINT archive_import_operations_status
    CHECK (status IN ('processing', 'completed', 'failed')),
  CONSTRAINT archive_import_operations_hash_nonempty
    CHECK (length(archive_hash) = 64)
);

CREATE INDEX IF NOT EXISTS archive_import_operations_user_created_idx
ON archive_import_operations(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS archive_import_operations_retention_idx
ON archive_import_operations(COALESCE(completed_at, created_at))
WHERE status IN ('completed', 'failed');

-- +goose Down

DROP TABLE IF EXISTS archive_import_operations;
