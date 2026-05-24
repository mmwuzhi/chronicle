-- name: SetTOTPSecret :exec
UPDATE users SET totp_secret = $2 WHERE id = $1;

-- name: EnableTOTP :exec
UPDATE users SET totp_enabled = true WHERE id = $1;

-- name: DisableTOTP :exec
UPDATE users SET totp_enabled = false, totp_secret = NULL WHERE id = $1;

-- name: CreateRecoveryCode :exec
INSERT INTO recovery_codes (user_id, code_hash) VALUES ($1, $2);

-- name: GetRecoveryCodes :many
SELECT * FROM recovery_codes WHERE user_id = $1;

-- name: UseRecoveryCode :exec
UPDATE recovery_codes SET used = true WHERE id = $1;

-- name: DeleteRecoveryCodes :exec
DELETE FROM recovery_codes WHERE user_id = $1;
