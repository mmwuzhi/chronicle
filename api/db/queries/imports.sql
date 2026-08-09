-- name: ClaimMarkdownImportOperation :one
WITH expired AS (
  DELETE FROM markdown_import_operations
  WHERE id IN (
    SELECT id
    FROM markdown_import_operations
    WHERE status IN ('completed', 'failed', 'undone')
      AND COALESCE(undone_at, completed_at, created_at) < now() - interval '30 days'
    ORDER BY COALESCE(undone_at, completed_at, created_at)
    LIMIT 1000
  )
)
INSERT INTO markdown_import_operations (
  id, user_id, input_hash, status, lease_until, claim_token
)
VALUES (
  sqlc.arg('id')::uuid,
  sqlc.arg('user_id')::uuid,
  sqlc.arg('input_hash')::text,
  'processing',
  now() + interval '2 hours',
  sqlc.arg('claim_token')::uuid
)
ON CONFLICT (id) DO UPDATE
SET status = 'processing',
    lease_until = now() + interval '2 hours',
    claim_token = excluded.claim_token,
    last_error = NULL
WHERE markdown_import_operations.user_id = excluded.user_id
  AND markdown_import_operations.input_hash = excluded.input_hash
  AND (
    markdown_import_operations.status = 'failed'
    OR (
      markdown_import_operations.status = 'processing'
      AND markdown_import_operations.lease_until <= now()
    )
  )
RETURNING *;

-- name: GetImportOperation :one
SELECT * FROM markdown_import_operations
WHERE id = sqlc.arg('id')::uuid;

-- name: CompleteMarkdownImportOperation :execrows
UPDATE markdown_import_operations
SET status = 'completed',
    lease_until = now(),
    result = sqlc.arg('result')::jsonb,
    created_capture_ids = sqlc.arg('created_capture_ids')::uuid[],
    completed_at = now(),
    undone_at = NULL,
    last_error = NULL
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND input_hash = sqlc.arg('input_hash')::text
  AND claim_token = sqlc.arg('claim_token')::uuid
  AND status = 'processing';

-- name: FailMarkdownImportOperation :execrows
UPDATE markdown_import_operations
SET status = 'failed',
    lease_until = now(),
    last_error = sqlc.arg('last_error')::text
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND input_hash = sqlc.arg('input_hash')::text
  AND claim_token = sqlc.arg('claim_token')::uuid
  AND status = 'processing';

-- name: SoftDeleteMarkdownImportCaptures :many
WITH deleted AS (
  UPDATE captures
  SET deleted_at = now()
  WHERE user_id = sqlc.arg('user_id')::uuid
    AND id = ANY(sqlc.arg('capture_ids')::uuid[])
    AND deleted_at IS NULL
  RETURNING id
), revoked AS (
  UPDATE capture_shares
  SET revoked_at = now()
  WHERE user_id = sqlc.arg('user_id')::uuid
    AND capture_id IN (SELECT id FROM deleted)
    AND revoked_at IS NULL
)
SELECT id FROM deleted;

-- name: MarkMarkdownImportUndone :execrows
UPDATE markdown_import_operations
SET status = 'undone',
    lease_until = now(),
    undone_at = now()
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND status = 'completed';
