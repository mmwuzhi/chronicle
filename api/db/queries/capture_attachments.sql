-- name: ListCaptureAttachments :many
SELECT ca.*
FROM capture_attachments ca
JOIN captures c ON c.id = ca.capture_id
WHERE ca.user_id = sqlc.arg('user_id')
  AND ca.capture_id = sqlc.arg('capture_id')
  AND ca.deleted_at IS NULL
  AND c.user_id = sqlc.arg('user_id')
  AND c.deleted_at IS NULL
ORDER BY ca.created_at DESC, ca.id DESC;

-- name: ListCaptureAttachmentsByCaptureIDs :many
-- Batch fetch for the capture page listing: one query for a whole page of
-- captures instead of one per capture. No captures join needed — the page
-- query already established ownership and liveness of every id passed in.
SELECT ca.* FROM capture_attachments ca
WHERE ca.user_id = $1
  AND ca.capture_id = ANY(sqlc.arg('capture_ids')::uuid[])
  AND ca.deleted_at IS NULL
ORDER BY ca.created_at DESC, ca.id DESC;

-- name: CreateCaptureAttachment :one
INSERT INTO capture_attachments (
  user_id,
  capture_id,
  provider,
  provider_file_id,
  name,
  mime_type,
  size_bytes,
  web_url
)
SELECT
  sqlc.arg('user_id')::uuid,
  sqlc.arg('capture_id')::uuid,
  sqlc.arg('provider')::cloud_drive_provider,
  sqlc.arg('provider_file_id')::text,
  sqlc.arg('name')::text,
  sqlc.narg('mime_type')::text,
  sqlc.narg('size_bytes')::bigint,
  sqlc.arg('web_url')::text
FROM captures c
WHERE c.id = sqlc.arg('capture_id')
  AND c.user_id = sqlc.arg('user_id')
  AND c.deleted_at IS NULL
RETURNING *;

-- name: DeleteCaptureAttachment :one
UPDATE capture_attachments ca
SET deleted_at = now()
FROM captures c
WHERE ca.id = sqlc.arg('id')
  AND ca.capture_id = sqlc.arg('capture_id')
  AND ca.user_id = sqlc.arg('user_id')
  AND ca.deleted_at IS NULL
  AND c.id = ca.capture_id
  AND c.user_id = sqlc.arg('user_id')
  AND c.deleted_at IS NULL
RETURNING ca.id;
