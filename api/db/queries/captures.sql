-- name: ListCaptures :many
SELECT * FROM captures
WHERE user_id = $1
  AND (sqlc.narg('classified_as')::text IS NULL OR classified_as::text = sqlc.narg('classified_as')::text)
ORDER BY created_at DESC;

-- name: CreateCapture :one
INSERT INTO captures (user_id, raw_text, media_url, media_type, classified_as, task_id, source)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: UpdateCapture :one
UPDATE captures
SET
  raw_text      = COALESCE(sqlc.narg('raw_text')::text,           raw_text),
  classified_as = CASE WHEN sqlc.narg('classified_as')::text IS NOT NULL
                  THEN sqlc.narg('classified_as')::capture_classified_as
                  ELSE classified_as END,
  task_id       = COALESCE(sqlc.narg('task_id')::uuid, task_id)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: DeleteCapture :one
DELETE FROM captures
WHERE id = $1 AND user_id = $2
RETURNING id;

-- name: ListCapturesInRange :many
SELECT * FROM captures
WHERE user_id = $1
  AND created_at >= $2
  AND created_at < $3
ORDER BY created_at;
