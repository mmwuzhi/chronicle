-- +goose Up

-- External file references for captures. Chronicle does not store the file bytes:
-- the user uploads to their own cloud drive, and Chronicle keeps only a provider-
-- neutral pointer plus display metadata.
CREATE TYPE cloud_drive_provider AS ENUM ('google_drive', 'onedrive', 'dropbox');

CREATE TABLE capture_attachments (
  id               UUID                 PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID                 NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  capture_id       UUID                 NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
  provider         cloud_drive_provider NOT NULL,
  provider_file_id TEXT                 NOT NULL,
  name             TEXT                 NOT NULL,
  mime_type        TEXT,
  size_bytes       BIGINT,
  web_url          TEXT                 NOT NULL,
  created_at       TIMESTAMPTZ          NOT NULL DEFAULT now(),
  deleted_at       TIMESTAMPTZ,

  CONSTRAINT capture_attachments_provider_file_id_nonempty
    CHECK (length(trim(provider_file_id)) > 0),
  CONSTRAINT capture_attachments_name_nonempty
    CHECK (length(trim(name)) > 0),
  CONSTRAINT capture_attachments_size_nonnegative
    CHECK (size_bytes IS NULL OR size_bytes >= 0),
  CONSTRAINT capture_attachments_web_url_nonempty
    CHECK (length(trim(web_url)) > 0)
);

CREATE INDEX capture_attachments_capture_active_idx
ON capture_attachments (capture_id, created_at DESC, id DESC)
WHERE deleted_at IS NULL;

CREATE INDEX capture_attachments_user_active_idx
ON capture_attachments (user_id, created_at DESC, id DESC)
WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX capture_attachments_capture_provider_file_active_idx
ON capture_attachments (capture_id, provider, provider_file_id)
WHERE deleted_at IS NULL;

-- +goose Down

DROP INDEX IF EXISTS capture_attachments_capture_provider_file_active_idx;
DROP INDEX IF EXISTS capture_attachments_user_active_idx;
DROP INDEX IF EXISTS capture_attachments_capture_active_idx;
DROP TABLE IF EXISTS capture_attachments;
DROP TYPE IF EXISTS cloud_drive_provider;
