-- name: ReserveCaptureUploadOperation :one
INSERT INTO capture_upload_operations (
  id, capture_id, user_id, request_hash, lease_until
) SELECT
  sqlc.arg('id')::uuid,
  sqlc.arg('capture_id')::uuid,
  sqlc.arg('user_id')::uuid,
  sqlc.arg('request_hash')::text,
  now() + interval '1 minute'
WHERE NOT EXISTS (
  SELECT 1 FROM captures WHERE captures.id = sqlc.arg('capture_id')::uuid
)
ON CONFLICT (id) DO UPDATE
SET lease_until = now() + interval '1 minute'
WHERE capture_upload_operations.user_id = excluded.user_id
  AND capture_upload_operations.request_hash = excluded.request_hash
  AND capture_upload_operations.completed_at IS NULL
  AND capture_upload_operations.lease_until <= now()
RETURNING *;

-- name: GetCaptureUploadOperation :one
SELECT * FROM capture_upload_operations
WHERE id = sqlc.arg('id')::uuid;

-- name: ReleaseCaptureUploadOperation :execrows
UPDATE capture_upload_operations
SET lease_until = now()
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND request_hash = sqlc.arg('request_hash')::text
  AND completed_at IS NULL;

-- name: CompleteCaptureUploadOperation :execrows
UPDATE capture_upload_operations
SET completed_at = now(), lease_until = now()
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND request_hash = sqlc.arg('request_hash')::text
  AND completed_at IS NULL;
