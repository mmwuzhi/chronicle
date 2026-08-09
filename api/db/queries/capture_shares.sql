-- name: GetShareableCaptureForUpdate :one
-- Serialises share replacement for one Capture so concurrent creates cannot
-- leave two unrevoked links. Text-only is intentional for the first sharing
-- surface: transcripts, media, attachments, and context remain private.
SELECT *
FROM captures
WHERE id = sqlc.arg('capture_id')
  AND user_id = sqlc.arg('user_id')
  AND deleted_at IS NULL
  AND raw_text IS NOT NULL
  AND length(btrim(raw_text)) > 0
FOR UPDATE;

-- name: RevokeActiveCaptureShares :exec
UPDATE capture_shares
SET revoked_at = now()
WHERE capture_id = sqlc.arg('capture_id')
  AND user_id = sqlc.arg('user_id')
  AND revoked_at IS NULL;

-- name: CreateCaptureShare :one
INSERT INTO capture_shares (
  id, user_id, capture_id, secret, snapshot_raw_text, captured_at, expires_at
)
VALUES (
  sqlc.arg('id'), sqlc.arg('user_id'), sqlc.arg('capture_id'),
  sqlc.arg('secret'), sqlc.arg('snapshot_raw_text'), sqlc.arg('captured_at'),
  sqlc.narg('expires_at')
)
RETURNING *;

-- name: ListCaptureSharesPage :many
SELECT *
FROM capture_shares
WHERE user_id = sqlc.arg('user_id')
  AND revoked_at IS NULL
  AND (expires_at IS NULL OR expires_at > now())
  AND (
    sqlc.narg('capture_id')::uuid IS NULL
    OR capture_id = sqlc.narg('capture_id')::uuid
  )
  AND (
    sqlc.narg('cursor_created_at')::timestamptz IS NULL
    OR (created_at, id) < (
      sqlc.narg('cursor_created_at')::timestamptz,
      sqlc.narg('cursor_id')::uuid
    )
  )
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg('page_size');

-- name: RevokeCaptureShare :one
UPDATE capture_shares
SET revoked_at = now()
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
  AND revoked_at IS NULL
RETURNING id;

-- name: GetPublicCaptureShare :one
SELECT cs.*
FROM capture_shares cs
JOIN captures c ON c.id = cs.capture_id
WHERE cs.id = sqlc.arg('id')
  AND cs.revoked_at IS NULL
  AND (cs.expires_at IS NULL OR cs.expires_at > now())
  AND c.deleted_at IS NULL;
