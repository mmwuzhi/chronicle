-- +goose Up

ALTER TABLE captures
ADD COLUMN source TEXT NOT NULL DEFAULT 'web';

CREATE INDEX captures_user_source_created_idx ON captures(user_id, source, created_at DESC);

-- +goose Down

DROP INDEX IF EXISTS captures_user_source_created_idx;

ALTER TABLE captures
DROP COLUMN IF EXISTS source;
