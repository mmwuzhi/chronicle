-- name: CreateOAuthAccount :one
INSERT INTO oauth_accounts (user_id, provider, provider_id)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetOAuthAccountsByUserID :many
SELECT * FROM oauth_accounts
WHERE user_id = $1
ORDER BY created_at;

-- name: GetOAuthAccount :one
SELECT * FROM oauth_accounts
WHERE provider = $1 AND provider_id = $2;

-- name: DeleteOAuthAccount :exec
DELETE FROM oauth_accounts
WHERE id = $1 AND user_id = $2;

-- name: GetUserByOAuth :one
SELECT u.* FROM users u
JOIN oauth_accounts oa ON oa.user_id = u.id
WHERE oa.provider = $1 AND oa.provider_id = $2;
