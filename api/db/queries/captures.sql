-- name: ListCapturePage :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND deleted_at IS NULL
  AND (
    sqlc.narg('todo')::text IS NULL
    OR (sqlc.narg('todo')::text = 'open' AND todo_at IS NOT NULL AND done_at IS NULL)
    OR (sqlc.narg('todo')::text = 'done' AND done_at IS NOT NULL)
  )
  AND (
    sqlc.narg('cursor_created_at')::timestamptz IS NULL
    OR (created_at, id) < (
      sqlc.narg('cursor_created_at')::timestamptz,
      sqlc.narg('cursor_id')::uuid
    )
  )
  AND (
    sqlc.arg('include_reminded')::boolean
    OR remind_at IS NULL
    OR remind_at <= now()
    OR NOT remind_hide
  )
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg('page_size');

-- name: GetCapture :one
SELECT * FROM captures
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;

-- name: ListCaptureContextBefore :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND deleted_at IS NULL
  AND (created_at, id) < (
    sqlc.arg('anchor_created_at')::timestamptz,
    sqlc.arg('anchor_id')::uuid
  )
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg('window_size');

-- name: ListCaptureContextAfter :many
SELECT * FROM captures
WHERE user_id = sqlc.arg('user_id')
  AND deleted_at IS NULL
  AND (created_at, id) > (
    sqlc.arg('anchor_created_at')::timestamptz,
    sqlc.arg('anchor_id')::uuid
  )
ORDER BY created_at ASC, id ASC
LIMIT sqlc.arg('window_size');

-- name: CreateCapture :one
-- todo_at/done_at are derived from the raw text by the handler (the #todo tag
-- is the todo facet's only entry point; see internal/capture/todotag.go).
INSERT INTO captures (user_id, raw_text, media_url, media_type, source, todo_at, done_at)
VALUES ($1, $2, $3, $4, $5, sqlc.narg('todo_at')::timestamptz, sqlc.narg('done_at')::timestamptz)
RETURNING *;

-- name: CreateUploadedCapture :one
-- raw_text is the composer draft sent along with the upload; like
-- CreateCapture, todo_at/done_at are derived from it by the handler (the
-- #todo tag is the todo facet's only entry point; see
-- internal/capture/todotag.go).
INSERT INTO captures (
  user_id,
  media_url,
  media_type,
  source,
  media_key,
  audio_duration_sec,
  raw_text,
  todo_at,
  done_at,
  transcription_status,
  next_transcription_at
)
VALUES (
  $1,
  $2,
  $3,
  'web',
  $4,
  $5,
  sqlc.narg('raw_text')::text,
  sqlc.narg('todo_at')::timestamptz,
  sqlc.narg('done_at')::timestamptz,
  CASE
    WHEN $3::capture_media_type = 'audio'
      AND $5::integer IS NOT NULL
      AND $5::integer <= 300
      AND sqlc.arg('transcription_enabled')::boolean
    THEN 'pending'::transcription_status
    WHEN $3::capture_media_type = 'audio'
    THEN 'skipped'::transcription_status
    WHEN $3::capture_media_type = 'image'
      AND sqlc.arg('vision_enabled')::boolean
    THEN 'pending'::transcription_status
    WHEN $3::capture_media_type = 'image'
    THEN 'skipped'::transcription_status
    ELSE 'none'::transcription_status
  END,
  CASE
    WHEN $3::capture_media_type = 'audio'
      AND $5::integer IS NOT NULL
      AND $5::integer <= 300
      AND sqlc.arg('transcription_enabled')::boolean
    THEN now()
    WHEN $3::capture_media_type = 'image'
      AND sqlc.arg('vision_enabled')::boolean
    THEN now()
    ELSE NULL
  END
)
RETURNING *;

-- name: UpdateCapture :one
-- When raw_text changes, todo_at/done_at follow the text (the #todo tag is
-- authoritative; the handler parses it into todo_present/todo_done/done_date).
-- A transcript-only patch (raw_text IS NULL) leaves both stamps untouched.
-- todo_at keeps its original value while the tag stays present (first-entry
-- index); done_at takes the tag's explicit date when given, else keeps the
-- existing stamp, else now(). The CHECK (done_at IS NULL OR todo_at IS NOT
-- NULL) holds because the parser only reports done on a present tag.
UPDATE captures
SET
  raw_text      = COALESCE(sqlc.narg('raw_text')::text,   raw_text),
  transcript    = COALESCE(sqlc.narg('transcript')::text, transcript),
  todo_at = CASE
    WHEN sqlc.narg('raw_text')::text IS NULL THEN todo_at
    WHEN NOT sqlc.arg('todo_present')::boolean THEN NULL
    ELSE COALESCE(todo_at, now())
  END,
  done_at = CASE
    WHEN sqlc.narg('raw_text')::text IS NULL THEN done_at
    WHEN NOT sqlc.arg('todo_done')::boolean THEN NULL
    WHEN sqlc.narg('done_date')::timestamptz IS NOT NULL THEN sqlc.narg('done_date')::timestamptz
    ELSE COALESCE(done_at, now())
  END
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id') AND deleted_at IS NULL
RETURNING *;

-- name: RetryCaptureTranscription :one
UPDATE captures
SET transcription_status = 'pending',
    transcription_attempts = 0,
    next_transcription_at = now()
WHERE id = $1
  AND user_id = $2
  AND deleted_at IS NULL
  AND (
    -- audio: same size guard the create path applies before queueing
    (media_type = 'audio' AND audio_duration_sec IS NOT NULL AND audio_duration_sec <= 300)
    -- image OCR has no duration guard; the worker routes it to vision transcription
    OR media_type = 'image'
  )
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
    AND deleted_at IS NULL
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

-- name: MinScheduledTranscriptionIn :one
-- Seconds until the earliest not-yet-claimable transcription work comes due: a
-- failed attempt's backoff retry, or a 'processing' lease that would come free
-- after a crash. The worker reads this after every drain so its wake-up timer
-- never forgets a retry scheduled by an earlier drain. Zero when nothing is
-- scheduled. The subtraction happens here because claimability is judged by
-- the database clock — computing it against the Go clock skews the wait by
-- whatever the two clocks disagree on.
SELECT COALESCE(EXTRACT(EPOCH FROM MIN(next_transcription_at) - now()), 0)::float8 AS next_in_seconds
FROM captures
WHERE transcription_status IN ('pending', 'processing')
  AND deleted_at IS NULL
  AND next_transcription_at > now();

-- name: SkipCaptureTranscription :exec
-- Mark a capture's transcription skipped and clear its retry schedule, so it
-- leaves the worker queue. Used to enforce the vision opt-out at the sink: an
-- image that reached 'pending' (e.g. via retry) while VISION_ENABLED is off is
-- skipped instead of being sent to the vision provider.
UPDATE captures
SET transcription_status = 'skipped',
    next_transcription_at = NULL
WHERE id = $1;

-- name: DeleteCapture :one
-- Soft delete (project convention: never hard-DELETE user data). Idempotent —
-- a second delete of the same id matches no row (deleted_at already set) and
-- returns pgx.ErrNoRows, which the handler maps to 404.
UPDATE captures
SET deleted_at = now()
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING id;

-- name: ListTrashedCaptures :many
-- Soft-deleted captures, for the trash view. Most-recently-deleted first.
SELECT * FROM captures
WHERE user_id = $1 AND deleted_at IS NOT NULL
ORDER BY deleted_at DESC, id DESC;

-- name: RestoreCapture :one
-- Undo a soft delete. Idempotent — restoring a live capture matches no row and
-- returns pgx.ErrNoRows, which the handler maps to 404. The embedding/metadata
-- side rows were never dropped on soft delete, so no reindex is needed.
UPDATE captures
SET deleted_at = NULL
WHERE id = $1 AND user_id = $2 AND deleted_at IS NOT NULL
RETURNING *;

-- name: PermanentDeleteCapture :one
-- Hard delete, allowed ONLY from the trash (deleted_at IS NOT NULL) as an
-- explicit user action — the macOS "Recently Deleted" model: normal delete is
-- soft, the trash offers permanent removal for content the user truly wants gone
-- (a mistaken or sensitive capture). FK ON DELETE CASCADE clears the derived rows
-- (capture_links, capture_attachments, capture_embeddings, capture_metadata).
-- Returns media_key so the handler can best-effort delete the R2 object too.
-- No row (live capture or wrong owner) → pgx.ErrNoRows → 404.
DELETE FROM captures
WHERE id = $1 AND user_id = $2 AND deleted_at IS NOT NULL
RETURNING media_key;

-- name: EmptyTrash :many
-- Hard delete every trashed capture for the user (explicit "empty trash").
-- Same cascade semantics as PermanentDeleteCapture. Returns each media_key so the
-- handler can best-effort purge the R2 objects; the row count is the purged total.
DELETE FROM captures
WHERE user_id = $1 AND deleted_at IS NOT NULL
RETURNING media_key;

-- name: ListCapturesInRange :many
SELECT * FROM captures
WHERE user_id = $1
  AND deleted_at IS NULL
  AND created_at >= $2
  AND created_at < $3
ORDER BY created_at;

-- name: SetCaptureRemind :one
-- Set or clear (remind_at = NULL) a capture's reminder. Independent of content
-- edits so the semantics stay separate. Only the browse path filters on this;
-- search/recall never do.
--
-- remind_hide splits notify from hide: true (default) hides the capture from
-- browse until due; false keeps it visible the whole time yet still notifies
-- (notify-only). When the reminder is cleared (remind_at = NULL) the flag is
-- moot — a null remind_at is always shown regardless of remind_hide.
UPDATE captures
SET remind_at = sqlc.narg('remind_at')::timestamptz,
    remind_hide = sqlc.arg('remind_hide')::boolean
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id') AND deleted_at IS NULL
RETURNING *;

-- name: DueReminders :many
-- Reminders that came due in (since, now] — left-open to avoid re-notifying the
-- same one (since = caller's last check), right-closed to include "due right now".
-- Newest first for the feed's "due" section.
SELECT * FROM captures
WHERE user_id = $1
  AND deleted_at IS NULL
  AND remind_at IS NOT NULL
  AND remind_at > sqlc.arg('since')::timestamptz
  AND remind_at <= now()
ORDER BY remind_at DESC;

-- name: PendingReminders :many
-- All not-yet-due reminders (remind_at > now), so the desktop app can reconcile
-- its scheduled OS notifications on launch.
SELECT * FROM captures
WHERE user_id = $1
  AND deleted_at IS NULL
  AND remind_at IS NOT NULL
  AND remind_at > now()
ORDER BY remind_at;
