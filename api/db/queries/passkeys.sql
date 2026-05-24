-- name: CreatePasskey :one
INSERT INTO passkeys (user_id, credential_id, public_key, aaguid, sign_count, name)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: GetPasskeysByUserID :many
SELECT * FROM passkeys
WHERE user_id = $1
ORDER BY created_at;

-- name: GetPasskeyByCredentialID :one
SELECT * FROM passkeys
WHERE credential_id = $1;

-- name: UpdatePasskeySignCount :exec
UPDATE passkeys SET sign_count = $2 WHERE id = $1;

-- name: DeletePasskey :exec
DELETE FROM passkeys WHERE id = $1 AND user_id = $2;

-- name: RenamePasskey :exec
UPDATE passkeys SET name = $3 WHERE id = $1 AND user_id = $2;
