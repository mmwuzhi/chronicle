-- name: CreateCaptureToken :one
INSERT INTO capture_tokens (user_id, token_hash, name)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetCaptureTokenByHash :one
SELECT * FROM capture_tokens
WHERE token_hash = $1
  AND revoked = false
LIMIT 1;

-- name: ListCaptureTokensByUser :many
SELECT id, name, last_used_at, created_at FROM capture_tokens
WHERE user_id = $1
  AND revoked = false
ORDER BY created_at DESC;

-- name: RevokeCaptureToken :exec
UPDATE capture_tokens
SET revoked = true
WHERE id = $1
  AND user_id = $2;

-- name: TouchCaptureTokenLastUsed :exec
UPDATE capture_tokens
SET last_used_at = now()
WHERE id = $1;
