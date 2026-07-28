-- name: CreateUser :one
INSERT INTO users (email, password_hash)
VALUES ($1, $2)
RETURNING *;

-- name: GetUserByEmail :one
SELECT * FROM users
WHERE email = $1
LIMIT 1;

-- name: GetUserByID :one
SELECT * FROM users
WHERE id = $1
LIMIT 1;

-- name: SetEmailVerifyToken :exec
UPDATE users SET email_verify_token = $2 WHERE id = $1;

-- name: VerifyEmail :one
UPDATE users
SET email_verified = true, email_verify_token = NULL
WHERE email_verify_token = $1 AND email_verified = false
RETURNING *;

-- name: SetPasswordResetToken :exec
UPDATE users
SET password_reset_token = $2, password_reset_expires = $3
WHERE email = $1;

-- name: GetUserByPasswordResetToken :one
SELECT * FROM users
WHERE password_reset_token = $1
  AND password_reset_expires > now();

-- name: UpdatePassword :exec
UPDATE users
SET password_hash = $2, password_reset_token = NULL, password_reset_expires = NULL
WHERE id = $1;

-- name: DeleteUser :one
-- Account deletion cascades through captures, so retain every R2 key in the
-- same statement before deleting the user. The media worker owns the durable
-- provider cleanup after the database privacy boundary is complete.
WITH media AS (
  SELECT media_key
  FROM captures
  WHERE user_id = sqlc.arg('id')
    AND media_key IS NOT NULL
    AND media_key <> ''
  FOR UPDATE
),
queued AS (
  INSERT INTO capture_media_deletions (object_key)
  SELECT media_key FROM media
  ON CONFLICT (object_key) DO NOTHING
),
deleted AS (
  DELETE FROM users
  WHERE users.id = sqlc.arg('id')
  RETURNING users.id
)
SELECT id FROM deleted;

-- name: CreateOAuthUser :one
INSERT INTO users (email, email_verified)
VALUES ($1, true)
RETURNING *;
