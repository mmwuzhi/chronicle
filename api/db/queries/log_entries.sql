-- name: ListLogEntries :many
SELECT * FROM log_entries
WHERE user_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('task_id')::uuid IS NULL OR task_id = sqlc.narg('task_id')::uuid)
ORDER BY created_at DESC;

-- name: CreateLogEntry :one
INSERT INTO log_entries (user_id, task_id, body)
VALUES ($1, $2, $3)
RETURNING *;

-- name: UpdateLogEntry :one
UPDATE log_entries
SET body = $1
WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL
RETURNING *;

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
