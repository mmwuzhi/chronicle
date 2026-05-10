-- name: CreateProject :one
INSERT INTO projects (user_id, name, color)
VALUES ($1, $2, $3)
RETURNING *;

-- name: ListProjects :many
SELECT * FROM projects
WHERE user_id = $1 AND archived = $2
ORDER BY created_at DESC;

-- name: GetProject :one
SELECT * FROM projects
WHERE id = $1 AND user_id = $2;

-- name: UpdateProject :one
UPDATE projects
SET
  name     = COALESCE(sqlc.narg('name'), name),
  color    = COALESCE(sqlc.narg('color'), color),
  archived = COALESCE(sqlc.narg('archived'), archived)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: DeleteProject :one
DELETE FROM projects
WHERE id = $1 AND user_id = $2
RETURNING id;
