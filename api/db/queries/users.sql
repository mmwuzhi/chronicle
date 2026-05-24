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

-- name: DeleteUser :exec
DELETE FROM users WHERE id = $1;

-- name: CreateOAuthUser :one
INSERT INTO users (email, email_verified)
VALUES ($1, true)
RETURNING *;
