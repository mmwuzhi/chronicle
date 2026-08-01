-- name: StoreAuthEphemeralState :exec
WITH expired AS (
  DELETE FROM auth_ephemeral_states
  WHERE (purpose, key_hash) IN (
    SELECT purpose, key_hash
    FROM auth_ephemeral_states
    WHERE expires_at <= now()
    ORDER BY expires_at
    LIMIT 1000
  )
)
INSERT INTO auth_ephemeral_states (purpose, key_hash, payload, expires_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (purpose, key_hash) DO UPDATE
SET payload = EXCLUDED.payload,
    expires_at = EXCLUDED.expires_at,
    created_at = now();

-- name: GetAuthEphemeralState :one
SELECT payload
FROM auth_ephemeral_states
WHERE purpose = $1
  AND key_hash = $2
  AND expires_at > now();

-- name: ConsumeAuthEphemeralState :one
DELETE FROM auth_ephemeral_states
WHERE purpose = $1
  AND key_hash = $2
  AND expires_at > now()
RETURNING payload;

-- name: ConsumeMatchingAuthEphemeralState :one
DELETE FROM auth_ephemeral_states
WHERE purpose = $1
  AND key_hash = $2
  AND payload = $3
  AND expires_at > now()
RETURNING payload;

-- name: IncrementAuthRateLimit :one
WITH expired AS (
  DELETE FROM auth_rate_limits
  WHERE (scope, subject_hash) IN (
    SELECT scope, subject_hash
    FROM auth_rate_limits
    WHERE expires_at <= now()
      AND NOT (scope = $1 AND subject_hash = $2)
    ORDER BY expires_at
    LIMIT 1000
  )
)
INSERT INTO auth_rate_limits (
  scope,
  subject_hash,
  attempts,
  window_started_at,
  expires_at
)
VALUES ($1, $2, 1, now(), $3)
ON CONFLICT (scope, subject_hash) DO UPDATE
SET attempts = CASE
      WHEN auth_rate_limits.expires_at <= now() THEN 1
      ELSE auth_rate_limits.attempts + 1
    END,
    window_started_at = CASE
      WHEN auth_rate_limits.expires_at <= now() THEN now()
      ELSE auth_rate_limits.window_started_at
    END,
    expires_at = CASE
      WHEN auth_rate_limits.expires_at <= now() THEN EXCLUDED.expires_at
      ELSE auth_rate_limits.expires_at
    END
RETURNING attempts, expires_at;

-- name: ClearAuthRateLimit :exec
DELETE FROM auth_rate_limits
WHERE scope = $1 AND subject_hash = $2;
