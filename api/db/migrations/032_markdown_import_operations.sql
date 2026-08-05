-- +goose Up

-- Markdown imports have different replay and undo semantics from Chronicle
-- archive restores. Keep the existing archive operation table untouched so
-- the previous API binary remains compatible during a rolling deploy or
-- rollback.
CREATE TABLE IF NOT EXISTS markdown_import_operations (
  id                  UUID        PRIMARY KEY,
  user_id             UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  input_hash          TEXT        NOT NULL,
  claim_token         UUID        NOT NULL,
  status              TEXT        NOT NULL DEFAULT 'processing',
  lease_until         TIMESTAMPTZ NOT NULL,
  result              JSONB,
  created_capture_ids UUID[]      NOT NULL DEFAULT '{}',
  last_error          TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,
  undone_at           TIMESTAMPTZ,

  CONSTRAINT markdown_import_operations_status
    CHECK (status IN ('processing', 'completed', 'failed', 'undone')),
  CONSTRAINT markdown_import_operations_hash_nonempty
    CHECK (length(input_hash) = 64)
);

CREATE INDEX IF NOT EXISTS markdown_import_operations_user_created_idx
ON markdown_import_operations(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS markdown_import_operations_retention_idx
ON markdown_import_operations(COALESCE(undone_at, completed_at, created_at))
WHERE status IN ('completed', 'failed', 'undone');

-- +goose Down

DROP TABLE IF EXISTS markdown_import_operations;
