-- name: ListCaptures :many
SELECT * FROM captures
WHERE user_id = $1
  AND (sqlc.narg('classified_as')::text IS NULL OR classified_as::text = sqlc.narg('classified_as')::text)
ORDER BY created_at DESC;

-- name: ListCapturePage :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND (
    sqlc.narg('classified_as')::text IS NULL
    OR classified_as::text = sqlc.narg('classified_as')::text
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

-- name: GetCapture :one
SELECT * FROM captures
WHERE id = $1 AND user_id = $2;

-- name: ListCaptureContextBefore :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND (created_at, id) < (
    sqlc.arg('anchor_created_at')::timestamptz,
    sqlc.arg('anchor_id')::uuid
  )
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg('window_size');

-- name: ListCaptureContextAfter :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND (created_at, id) > (
    sqlc.arg('anchor_created_at')::timestamptz,
    sqlc.arg('anchor_id')::uuid
  )
ORDER BY created_at ASC, id ASC
LIMIT sqlc.arg('window_size');

-- name: CreateCapture :one
INSERT INTO captures (user_id, raw_text, media_url, media_type, classified_as, task_id, source)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: CreateUploadedCapture :one
INSERT INTO captures (
  user_id,
  media_url,
  media_type,
  classified_as,
  source,
  media_key,
  audio_duration_sec,
  transcription_status,
  next_transcription_at
)
VALUES (
  $1,
  $2,
  $3,
  'unclassified',
  'web',
  $4,
  $5,
  CASE
    WHEN $3::capture_media_type = 'audio'
      AND $5::integer IS NOT NULL
      AND $5::integer <= 300
      AND sqlc.arg('transcription_enabled')::boolean
    THEN 'pending'::transcription_status
    WHEN $3::capture_media_type = 'audio'
    THEN 'skipped'::transcription_status
    ELSE 'none'::transcription_status
  END,
  CASE
    WHEN $3::capture_media_type = 'audio'
      AND $5::integer IS NOT NULL
      AND $5::integer <= 300
      AND sqlc.arg('transcription_enabled')::boolean
    THEN now()
    ELSE NULL
  END
)
RETURNING *;

-- name: UpdateCapture :one
UPDATE captures
SET
  raw_text      = COALESCE(sqlc.narg('raw_text')::text,           raw_text),
  transcript    = COALESCE(sqlc.narg('transcript')::text,         transcript),
  classified_as = CASE WHEN sqlc.narg('classified_as')::text IS NOT NULL
                  THEN sqlc.narg('classified_as')::capture_classified_as
                  ELSE classified_as END,
  task_id       = COALESCE(sqlc.narg('task_id')::uuid, task_id)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: RetryCaptureTranscription :one
UPDATE captures
SET transcription_status = 'pending',
    transcription_attempts = 0,
    next_transcription_at = now()
WHERE id = $1
  AND user_id = $2
  AND media_type = 'audio'
  AND audio_duration_sec IS NOT NULL
  AND audio_duration_sec <= 300
RETURNING *;

-- name: ClaimPendingTranscription :one
UPDATE captures
SET transcription_status = 'processing',
    transcription_attempts = transcription_attempts + 1,
    next_transcription_at = now() + interval '10 minutes'
WHERE id = (
  SELECT id
  FROM captures
  WHERE transcription_status IN ('pending', 'processing')
    AND next_transcription_at <= now()
  ORDER BY next_transcription_at, created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING *;

-- name: CompleteCaptureTranscription :exec
UPDATE captures
SET transcript = $2,
    transcription_status = 'completed',
    transcription_model = $3,
    transcribed_at = now(),
    next_transcription_at = NULL
WHERE id = $1;

-- name: FailCaptureTranscription :exec
UPDATE captures
SET transcription_status = CASE
      WHEN transcription_attempts >= 4 THEN 'failed'::transcription_status
      ELSE 'pending'::transcription_status
    END,
    next_transcription_at = CASE transcription_attempts
      WHEN 1 THEN now() + interval '1 minute'
      WHEN 2 THEN now() + interval '5 minutes'
      WHEN 3 THEN now() + interval '30 minutes'
      ELSE NULL
    END
WHERE id = $1;

-- name: DeleteCapture :one
DELETE FROM captures
WHERE id = $1 AND user_id = $2
RETURNING id;

-- name: ListCapturesInRange :many
SELECT * FROM captures
WHERE user_id = $1
  AND created_at >= $2
  AND created_at < $3
ORDER BY created_at;
