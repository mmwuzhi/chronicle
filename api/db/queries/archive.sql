-- name: ListArchiveCaptures :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
ORDER BY created_at, id;

-- name: ListArchiveCapturesPage :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND (
    sqlc.narg('after_created_at')::timestamptz IS NULL
    OR (created_at, id) > (
      sqlc.narg('after_created_at')::timestamptz,
      sqlc.arg('after_id')::uuid
    )
  )
ORDER BY created_at, id
LIMIT sqlc.arg('page_size');

-- name: ListArchiveCaptureLinks :many
SELECT * FROM capture_links
WHERE user_id = sqlc.arg('user_id')
ORDER BY created_at, a_id, b_id;

-- name: ListArchiveCaptureLinksPage :many
SELECT * FROM capture_links
WHERE user_id = sqlc.arg('user_id')
  AND (
    sqlc.narg('after_created_at')::timestamptz IS NULL
    OR (created_at, a_id, b_id) > (
      sqlc.narg('after_created_at')::timestamptz,
      sqlc.arg('after_a_id')::uuid,
      sqlc.arg('after_b_id')::uuid
    )
  )
ORDER BY created_at, a_id, b_id
LIMIT sqlc.arg('page_size');

-- name: ListArchiveCaptureAttachments :many
SELECT * FROM capture_attachments
WHERE user_id = sqlc.arg('user_id')
ORDER BY created_at, id;

-- name: ListArchiveCaptureAttachmentsPage :many
SELECT * FROM capture_attachments
WHERE user_id = sqlc.arg('user_id')
  AND (
    sqlc.narg('after_created_at')::timestamptz IS NULL
    OR (created_at, id) > (
      sqlc.narg('after_created_at')::timestamptz,
      sqlc.arg('after_id')::uuid
    )
  )
ORDER BY created_at, id
LIMIT sqlc.arg('page_size');

-- name: ListArchiveRetrievalDismissals :many
SELECT * FROM retrieval_dismissals
WHERE user_id = sqlc.arg('user_id')
ORDER BY created_at, surface, query_hash, anchor_id, target_id;

-- name: GetCaptureOwner :one
SELECT id, user_id FROM captures
WHERE id = sqlc.arg('id')::uuid;

-- name: InsertArchiveCapture :one
INSERT INTO captures (
  id, user_id, raw_text, media_url, media_type, classified_as, created_at,
  source, transcript, transcription_status, transcription_model,
  transcription_attempts, transcribed_at, next_transcription_at,
  audio_duration_sec, media_key, remind_at, deleted_at, remind_hide,
  todo_at, done_at, link_url
)
VALUES (
  sqlc.arg('id')::uuid,
  sqlc.arg('user_id')::uuid,
  sqlc.narg('raw_text')::text,
  sqlc.narg('media_url')::text,
  sqlc.arg('media_type')::capture_media_type,
  sqlc.arg('classified_as')::capture_classified_as,
  sqlc.arg('created_at')::timestamptz,
  sqlc.arg('source')::text,
  sqlc.narg('transcript')::text,
  sqlc.arg('transcription_status')::transcription_status,
  sqlc.narg('transcription_model')::text,
  sqlc.arg('transcription_attempts')::integer,
  sqlc.narg('transcribed_at')::timestamptz,
  sqlc.narg('next_transcription_at')::timestamptz,
  sqlc.narg('audio_duration_sec')::integer,
  sqlc.narg('media_key')::text,
  sqlc.narg('remind_at')::timestamptz,
  sqlc.narg('deleted_at')::timestamptz,
  sqlc.arg('remind_hide')::boolean,
  sqlc.narg('todo_at')::timestamptz,
  sqlc.narg('done_at')::timestamptz,
  sqlc.narg('link_url')::text
)
ON CONFLICT (id) DO NOTHING
RETURNING *;

-- name: InsertArchiveCaptureLink :one
INSERT INTO capture_links (a_id, b_id, user_id, created_at)
VALUES (
  LEAST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid),
  GREATEST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid),
  sqlc.arg('user_id')::uuid,
  sqlc.arg('created_at')::timestamptz
)
ON CONFLICT (a_id, b_id) DO NOTHING
RETURNING *;

-- name: InsertArchiveCaptureAttachment :one
INSERT INTO capture_attachments (
  id, user_id, capture_id, provider, provider_file_id, name, mime_type,
  size_bytes, web_url, created_at, deleted_at
)
VALUES (
  sqlc.arg('id')::uuid,
  sqlc.arg('user_id')::uuid,
  sqlc.arg('capture_id')::uuid,
  sqlc.arg('provider')::cloud_drive_provider,
  sqlc.arg('provider_file_id')::text,
  sqlc.arg('name')::text,
  sqlc.narg('mime_type')::text,
  sqlc.narg('size_bytes')::bigint,
  sqlc.arg('web_url')::text,
  sqlc.arg('created_at')::timestamptz,
  sqlc.narg('deleted_at')::timestamptz
)
ON CONFLICT DO NOTHING
RETURNING *;

-- name: InsertArchiveSearchDismissal :execrows
INSERT INTO retrieval_dismissals (
  user_id, surface, query_hash, query_text, target_id, created_at
)
SELECT
  sqlc.arg('user_id')::uuid, 'search', sqlc.arg('query_hash'),
  sqlc.arg('query_text')::text, sqlc.arg('target_id')::uuid,
  sqlc.arg('created_at')::timestamptz
WHERE EXISTS (
  SELECT 1 FROM captures
  WHERE id = sqlc.arg('target_id')::uuid AND user_id = sqlc.arg('user_id')::uuid
)
ON CONFLICT (user_id, query_hash, target_id) WHERE surface = 'search'
DO UPDATE SET query_text = EXCLUDED.query_text, created_at = EXCLUDED.created_at;

-- name: InsertArchiveRelatedDismissal :execrows
INSERT INTO retrieval_dismissals (
  user_id, surface, anchor_id, target_id, created_at
)
SELECT
  sqlc.arg('user_id')::uuid, 'related', sqlc.arg('anchor_id')::uuid,
  sqlc.arg('target_id')::uuid, sqlc.arg('created_at')::timestamptz
WHERE EXISTS (
  SELECT 1 FROM captures
  WHERE id = sqlc.arg('anchor_id')::uuid AND user_id = sqlc.arg('user_id')::uuid
)
AND EXISTS (
  SELECT 1 FROM captures
  WHERE id = sqlc.arg('target_id')::uuid AND user_id = sqlc.arg('user_id')::uuid
)
ON CONFLICT (user_id, anchor_id, target_id) WHERE surface = 'related'
DO UPDATE SET created_at = EXCLUDED.created_at;

-- name: ClaimArchiveImportOperation :one
WITH expired AS (
  DELETE FROM archive_import_operations
  WHERE id IN (
    SELECT id
    FROM archive_import_operations
    WHERE status IN ('completed', 'failed')
      AND COALESCE(completed_at, created_at) < now() - interval '30 days'
    ORDER BY COALESCE(completed_at, created_at)
    LIMIT 1000
  )
)
INSERT INTO archive_import_operations (
  id, user_id, archive_hash, status, lease_until, claim_token
)
VALUES (
  sqlc.arg('id')::uuid,
  sqlc.arg('user_id')::uuid,
  sqlc.arg('archive_hash')::text,
  'processing',
  now() + interval '2 hours',
  sqlc.arg('claim_token')::uuid
)
ON CONFLICT (id) DO UPDATE
SET status = 'processing',
    lease_until = now() + interval '2 hours',
    claim_token = excluded.claim_token,
    last_error = NULL
WHERE archive_import_operations.user_id = excluded.user_id
  AND archive_import_operations.archive_hash = excluded.archive_hash
  AND (
    archive_import_operations.status = 'failed'
    OR (
      archive_import_operations.status = 'processing'
      AND archive_import_operations.lease_until <= now()
    )
  )
RETURNING *;

-- name: GetArchiveImportOperation :one
SELECT * FROM archive_import_operations
WHERE id = sqlc.arg('id')::uuid;

-- name: CompleteArchiveImportOperation :execrows
UPDATE archive_import_operations
SET status = 'completed',
    lease_until = now(),
    id_map = sqlc.arg('id_map')::jsonb,
    result = sqlc.arg('result')::jsonb,
    completed_at = now(),
    last_error = NULL
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND archive_hash = sqlc.arg('archive_hash')::text
  AND claim_token = sqlc.arg('claim_token')::uuid
  AND status = 'processing';

-- name: FailArchiveImportOperation :execrows
UPDATE archive_import_operations
SET status = 'failed',
    lease_until = now(),
    last_error = sqlc.arg('last_error')::text
WHERE id = sqlc.arg('id')::uuid
  AND user_id = sqlc.arg('user_id')::uuid
  AND archive_hash = sqlc.arg('archive_hash')::text
  AND claim_token = sqlc.arg('claim_token')::uuid
  AND status = 'processing';
