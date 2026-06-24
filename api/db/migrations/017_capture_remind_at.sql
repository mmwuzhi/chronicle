-- +goose Up

-- Time-based recall (ported from rag3): a capture can carry an optional future
-- remind_at. Only the browse path filters on it (hidden until due, then
-- resurfaced); search and recall must never filter it, preserving time-window
-- completeness.
ALTER TABLE captures ADD COLUMN remind_at TIMESTAMPTZ;

CREATE INDEX captures_remind_at_idx
ON captures (user_id, remind_at)
WHERE remind_at IS NOT NULL;

-- +goose Down

DROP INDEX IF EXISTS captures_remind_at_idx;

ALTER TABLE captures DROP COLUMN IF EXISTS remind_at;
