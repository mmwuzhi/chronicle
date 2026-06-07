-- +goose Up

ALTER TABLE time_blocks
ADD COLUMN deleted_at TIMESTAMPTZ,
ADD COLUMN input_mode TEXT NOT NULL DEFAULT 'duration'
  CHECK (input_mode IN ('duration', 'range'));

ALTER TABLE log_entries
ADD COLUMN time_block_id UUID UNIQUE REFERENCES time_blocks(id) ON DELETE SET NULL;

INSERT INTO log_entries (user_id, task_id, body, created_at, time_block_id)
SELECT user_id, task_id, '', created_at, id
FROM time_blocks;

CREATE INDEX time_blocks_active_user_task_idx
ON time_blocks(user_id, task_id, started_at DESC)
WHERE deleted_at IS NULL;

-- +goose Down

DROP INDEX IF EXISTS time_blocks_active_user_task_idx;

UPDATE log_entries
SET deleted_at = now()
WHERE body = '' AND time_block_id IS NOT NULL;

ALTER TABLE log_entries
DROP COLUMN IF EXISTS time_block_id;

ALTER TABLE time_blocks
DROP COLUMN IF EXISTS input_mode,
DROP COLUMN IF EXISTS deleted_at;
