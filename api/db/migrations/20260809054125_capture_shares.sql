-- +goose Up

-- A share is an explicit, revocable, immutable text snapshot of one Capture.
-- It is deliberately separate from captures: ordinary Capture URLs remain
-- private, and later edits cannot silently publish new text through an old link.
CREATE TABLE capture_shares (
  id                UUID        PRIMARY KEY,
  user_id           UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  capture_id        UUID        NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
  snapshot_raw_text TEXT        NOT NULL,
  captured_at       TIMESTAMPTZ NOT NULL,
  expires_at        TIMESTAMPTZ,
  revoked_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT capture_shares_snapshot_nonempty
    CHECK (length(btrim(snapshot_raw_text)) > 0)
);

-- A Capture has at most one link that has not been explicitly revoked. Expired
-- links remain as audit history in the database but are not returned to clients.
CREATE UNIQUE INDEX capture_shares_one_unrevoked_per_capture
ON capture_shares(capture_id)
WHERE revoked_at IS NULL;

CREATE INDEX capture_shares_user_created_idx
ON capture_shares(user_id, created_at DESC);

-- +goose Down

DROP TABLE IF EXISTS capture_shares;
