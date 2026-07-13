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
-- Media transcription only (media_key IS NOT NULL). Text captures with a URL
-- share this status column for link enrichment; ClaimPendingLinkFetch claims
-- those. The media_key split keeps the two workers off each other's rows.
UPDATE captures
SET transcription_status = 'processing',
    transcription_attempts = transcription_attempts + 1,
    next_transcription_at = now() + interval '10 minutes'
WHERE id = (
  SELECT id
  FROM captures
  WHERE transcription_status IN ('pending', 'processing')
    AND media_key IS NOT NULL
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
  AND media_key IS NOT NULL
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

-- name: EnqueueCaptureLinkFetch :exec
-- Record the URL detected in a text capture and hand it to the link-fetch worker
-- via the shared transcription_status machine. media_key IS NULL guards it to
-- text captures (a media capture's queue slot belongs to transcription). Clear
-- any old link-derived transcript immediately so search never keeps matching a
-- stale page while the new URL is pending or has failed.
UPDATE captures
SET link_url = $2,
    transcript = NULL,
    transcription_status = 'pending',
    transcription_model = NULL,
    transcribed_at = NULL,
    transcription_attempts = 0,
    next_transcription_at = now()
WHERE id = $1 AND media_key IS NULL AND deleted_at IS NULL;

-- name: BackfillLinkFetchQueue :execrows
-- One-time enqueue of pre-existing text captures that carry a URL but were never
-- link-enriched. Run once when the link-fetch worker starts, so history is only
-- touched when the feature is actually enabled. The coarse `~*` presence check
-- just gates entry to the queue; the worker derives the exact URL from the text
-- (capture.FirstURL) — the URL grammar stays defined once, in Go.
UPDATE captures
SET transcription_status = 'pending',
    transcription_attempts = 0,
    next_transcription_at = now()
WHERE media_key IS NULL
  AND deleted_at IS NULL
  AND transcript IS NULL
  AND transcription_status = 'none'
  AND raw_text ~* 'https?://';

-- name: ClaimPendingLinkFetch :one
-- Link enrichment only (media_key IS NULL). Symmetric to
-- ClaimPendingTranscription; the media_key split keeps the two workers from
-- claiming each other's rows out of the shared status column.
UPDATE captures
SET transcription_status = 'processing',
    transcription_attempts = transcription_attempts + 1,
    next_transcription_at = now() + interval '10 minutes'
WHERE id = (
  SELECT id
  FROM captures
  WHERE transcription_status IN ('pending', 'processing')
    AND media_key IS NULL
    AND deleted_at IS NULL
    AND next_transcription_at <= now()
  ORDER BY next_transcription_at, created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING *;

-- name: PrepareCaptureLinkFetch :execrows
-- Pin the URL a claimed job is about to fetch. Backfilled jobs enter the queue
-- with link_url NULL and derive the exact target from raw_text in Go; persisting
-- it before the network request gives every terminal write a generation token.
-- If an edit already superseded this claim (status is no longer processing or a
-- different URL is stored), zero rows are updated and the stale worker stops.
UPDATE captures
SET link_url = sqlc.arg('link_url')::text
WHERE id = sqlc.arg('id')
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND transcription_status = 'processing'
  AND (link_url IS NULL OR link_url = sqlc.arg('link_url')::text);

-- name: SkipUnresolvedLinkFetch :execrows
-- A coarse SQL backfill match contained no URL accepted by the Go grammar. Only
-- skip the still-current NULL-link claim; if the user added a real URL after the
-- claim, EnqueueCaptureLinkFetch has already replaced both link_url and status.
UPDATE captures
SET transcription_status = 'skipped',
    next_transcription_at = NULL
WHERE id = sqlc.arg('id')
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND link_url IS NULL
  AND transcription_status = 'processing';

-- name: MinScheduledLinkFetchIn :one
-- Seconds until the earliest not-yet-claimable link-fetch job comes due (failure
-- backoff or a crashed 'processing' lease). Link-job counterpart to
-- MinScheduledTranscriptionIn; see its comment for why the clock math is in SQL.
SELECT COALESCE(EXTRACT(EPOCH FROM MIN(next_transcription_at) - now()), 0)::float8 AS next_in_seconds
FROM captures
WHERE transcription_status IN ('pending', 'processing')
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND next_transcription_at > now();

-- name: CompleteCaptureLinkFetch :execrows
-- Store the fetched page text as the capture's transcript (now its indexable
-- content) and record the resolved URL, so a backfilled row that entered the
-- queue without link_url ends up with the URL the worker actually fetched.
-- The URL + processing predicate is a compare-and-set lease: an older request
-- that finishes after the user changed/removed the URL must not restore stale
-- content or cancel the replacement job.
UPDATE captures
SET transcript = $2,
    link_url = $3,
    transcription_status = 'completed',
    transcription_model = $4,
    transcribed_at = now(),
    next_transcription_at = NULL
WHERE id = $1
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND link_url = $3
  AND transcription_status = 'processing';

-- name: FailCaptureLinkFetch :execrows
-- Link-job counterpart to FailCaptureTranscription, guarded by the URL lease so
-- an old failed request cannot strand a newly-enqueued URL (whose attempts were
-- reset to zero) with a NULL retry time.
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
WHERE id = sqlc.arg('id')
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND link_url = sqlc.arg('link_url')::text
  AND transcription_status = 'processing';

-- name: SkipCaptureLinkFetch :execrows
-- A successfully fetched page had no extractable text. Like complete/fail, only
-- the still-current claimed URL may leave the queue.
UPDATE captures
SET transcription_status = 'skipped',
    next_transcription_at = NULL
WHERE id = sqlc.arg('id')
  AND media_key IS NULL
  AND deleted_at IS NULL
  AND link_url = sqlc.arg('link_url')::text
  AND transcription_status = 'processing';

-- name: ClearCaptureLinkFetch :exec
-- The URL was edited out of a text capture: drop the link-derived transcript and
-- its scheduling so search matches the text again (text is the source of truth,
-- like the #todo tag). Guarded to text captures (media_key IS NULL), whose
-- transcript can only be link-derived — a media capture's transcript is
-- Whisper/OCR output and must never be cleared here.
UPDATE captures
SET link_url = NULL,
    transcript = NULL,
    transcription_status = 'none',
    transcription_model = NULL,
    transcribed_at = NULL,
    transcription_attempts = 0,
    next_transcription_at = NULL
WHERE id = $1 AND media_key IS NULL AND deleted_at IS NULL;

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
-- Capped: a user who never empties the trash would otherwise grow this
-- response without bound. Older trashed rows stay restorable one-by-one once
-- the newer ones are purged, and empty-trash always clears everything.
SELECT * FROM captures
WHERE user_id = $1 AND deleted_at IS NOT NULL
ORDER BY deleted_at DESC, id DESC
LIMIT sqlc.arg('result_limit');

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
