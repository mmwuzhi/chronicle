-- +goose Up

CREATE TYPE transcription_status AS ENUM (
  'none',
  'pending',
  'processing',
  'completed',
  'failed',
  'skipped'
);

ALTER TABLE captures
ADD COLUMN transcript TEXT,
ADD COLUMN transcription_status transcription_status NOT NULL DEFAULT 'none',
ADD COLUMN transcription_model TEXT,
ADD COLUMN transcription_attempts INTEGER NOT NULL DEFAULT 0,
ADD COLUMN transcribed_at TIMESTAMPTZ,
ADD COLUMN next_transcription_at TIMESTAMPTZ,
ADD COLUMN audio_duration_sec INTEGER,
ADD COLUMN media_key TEXT;

CREATE INDEX captures_pending_transcription_idx
ON captures(next_transcription_at, created_at)
WHERE transcription_status IN ('pending', 'processing');

-- +goose Down

DROP INDEX IF EXISTS captures_pending_transcription_idx;

ALTER TABLE captures
DROP COLUMN IF EXISTS media_key,
DROP COLUMN IF EXISTS audio_duration_sec,
DROP COLUMN IF EXISTS next_transcription_at,
DROP COLUMN IF EXISTS transcribed_at,
DROP COLUMN IF EXISTS transcription_attempts,
DROP COLUMN IF EXISTS transcription_model,
DROP COLUMN IF EXISTS transcription_status,
DROP COLUMN IF EXISTS transcript;

DROP TYPE IF EXISTS transcription_status;
