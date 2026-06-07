-- name: ListLogEntries :many
SELECT * FROM log_entries
WHERE user_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('task_id')::uuid IS NULL OR task_id = sqlc.narg('task_id')::uuid)
ORDER BY created_at DESC;

-- name: CreateLogEntry :one
INSERT INTO log_entries (user_id, task_id, body, time_block_id)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: UpdateLogEntry :one
UPDATE log_entries
SET body = $1,
    time_block_id = CASE
      WHEN sqlc.arg('clear_time_block')::boolean THEN NULL
      ELSE COALESCE(sqlc.narg('time_block_id')::uuid, time_block_id)
    END
WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL
RETURNING *;

-- name: GetLogEntry :one
SELECT * FROM log_entries
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;

-- name: DeleteLogEntry :one
UPDATE log_entries
SET deleted_at = now()
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING id;

-- name: ListLogEntriesInRange :many
SELECT * FROM log_entries
WHERE user_id = $1
  AND deleted_at IS NULL
  AND created_at >= $2
  AND created_at < $3
ORDER BY created_at;
