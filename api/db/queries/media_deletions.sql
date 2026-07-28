-- name: ClaimCaptureMediaDeletion :one
WITH candidate AS (
    SELECT object_key
    FROM capture_media_deletions
    WHERE next_attempt_at <= now()
      AND (lease_until IS NULL OR lease_until <= now())
    ORDER BY next_attempt_at, created_at, object_key
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
UPDATE capture_media_deletions AS deletion
SET lease_until = now() + interval '5 minutes'
FROM candidate
WHERE deletion.object_key = candidate.object_key
RETURNING deletion.*;

-- name: CompleteCaptureMediaDeletion :execrows
DELETE FROM capture_media_deletions
WHERE object_key = $1
  AND lease_until = $2;

-- name: FailCaptureMediaDeletion :execrows
UPDATE capture_media_deletions
SET attempts = attempts + 1,
    next_attempt_at = now()
        + LEAST(
            interval '1 day',
            interval '1 minute' * power(2, LEAST(attempts, 10))
        ),
    lease_until = NULL,
    last_error = $3
WHERE object_key = $1
  AND lease_until = $2;

-- name: NextCaptureMediaDeletionAt :one
SELECT min(
    CASE
        WHEN lease_until IS NOT NULL AND lease_until > next_attempt_at
            THEN lease_until
        ELSE next_attempt_at
    END
)::timestamptz
FROM capture_media_deletions;
