-- name: CreateTask :one
INSERT INTO tasks (user_id, project_id, title, type, start_at, due_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: ListTasks :many
SELECT * FROM tasks
WHERE user_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('project_id')::uuid IS NULL OR project_id = sqlc.narg('project_id')::uuid)
  AND (sqlc.narg('status')::text IS NULL OR status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('type')::text IS NULL OR type::text = sqlc.narg('type')::text)
ORDER BY created_at DESC;

-- name: GetTask :one
SELECT * FROM tasks
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;

-- name: UpdateTask :one
UPDATE tasks
SET
  title      = COALESCE(sqlc.narg('title'), title),
  status     = CASE WHEN sqlc.narg('status')::text IS NOT NULL
               THEN sqlc.narg('status')::task_status
               ELSE status END,
  type       = CASE WHEN sqlc.narg('type')::text IS NOT NULL
               THEN sqlc.narg('type')::task_type
               ELSE type END,
  project_id = COALESCE(sqlc.narg('project_id')::uuid, project_id),
  start_at   = CASE WHEN sqlc.arg('clear_start_at')::boolean
               THEN NULL
               ELSE COALESCE(sqlc.narg('start_at')::timestamptz, start_at) END,
  due_at     = CASE WHEN sqlc.arg('clear_due_at')::boolean
               THEN NULL
               ELSE COALESCE(sqlc.narg('due_at')::timestamptz, due_at) END,
  media_url  = COALESCE(sqlc.narg('media_url'), media_url),
  media_type = COALESCE(sqlc.narg('media_type'), media_type)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id') AND deleted_at IS NULL
RETURNING *;

-- name: DeleteTask :one
UPDATE tasks
SET deleted_at = now()
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING id;

-- name: ListTasksInRange :many
SELECT * FROM tasks
WHERE user_id = $1
  AND deleted_at IS NULL
  AND created_at >= $2
  AND created_at < $3
ORDER BY created_at;
