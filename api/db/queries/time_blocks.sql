-- name: ListTimeBlocks :many
SELECT * FROM time_blocks
WHERE user_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('task_id')::uuid IS NULL OR task_id = sqlc.narg('task_id')::uuid)
ORDER BY started_at DESC;

-- name: CreateTimeBlock :one
INSERT INTO time_blocks (user_id, task_id, started_at, ended_at, duration_sec, input_mode)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: UpdateTimeBlock :one
UPDATE time_blocks
SET
  task_id      = COALESCE(sqlc.narg('task_id')::uuid,       task_id),
  started_at   = COALESCE(sqlc.narg('started_at')::timestamptz, started_at),
  ended_at     = COALESCE(sqlc.narg('ended_at')::timestamptz,   ended_at),
  duration_sec = COALESCE(sqlc.narg('duration_sec')::integer,   duration_sec),
  input_mode   = COALESCE(sqlc.narg('input_mode')::text, input_mode)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id') AND deleted_at IS NULL
RETURNING *;

-- name: DeleteTimeBlock :one
UPDATE time_blocks
SET deleted_at = now()
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING id;

-- name: GetTimeBlock :one
SELECT * FROM time_blocks
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;

-- name: ListTimeBlocksInRange :many
SELECT * FROM time_blocks
WHERE user_id = $1
  AND deleted_at IS NULL
  AND started_at >= $2
  AND started_at < $3
ORDER BY started_at;
