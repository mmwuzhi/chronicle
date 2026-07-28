-- +goose Up

-- R2 deletion must survive request cancellation, process crashes, and provider
-- outages. Permanent capture deletion writes this tombstone in the same SQL
-- statement that removes the capture; a background worker deletes the object
-- and only then removes the tombstone.
CREATE TABLE capture_media_deletions (
    object_key      TEXT        PRIMARY KEY,
    attempts        INTEGER     NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until     TIMESTAMPTZ,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX capture_media_deletions_ready_idx
ON capture_media_deletions(next_attempt_at, created_at);

-- +goose Down

DROP TABLE IF EXISTS capture_media_deletions;
