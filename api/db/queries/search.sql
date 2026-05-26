-- name: SearchCaptures :many
SELECT * FROM captures
WHERE user_id = $1
  AND raw_text IS NOT NULL
  AND raw_text ILIKE '%' || sqlc.arg(query)::text || '%'
ORDER BY created_at DESC
LIMIT 20;

-- name: SearchTasks :many
SELECT * FROM tasks
WHERE user_id = $1
  AND deleted_at IS NULL
  AND title ILIKE '%' || sqlc.arg(query)::text || '%'
ORDER BY created_at DESC
LIMIT 20;

-- name: SearchLogEntries :many
SELECT * FROM log_entries
WHERE user_id = $1
  AND deleted_at IS NULL
  AND body ILIKE '%' || sqlc.arg(query)::text || '%'
ORDER BY created_at DESC
LIMIT 20;
