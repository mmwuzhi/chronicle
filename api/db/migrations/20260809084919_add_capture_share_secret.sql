-- +goose Up

-- Keep the public URL secret independently recoverable by the owner. Existing
-- development rows predate this column, so backfill them with fresh randomness
-- before making the field required.
ALTER TABLE capture_shares ADD COLUMN secret TEXT;

UPDATE capture_shares
SET secret = replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

ALTER TABLE capture_shares
  ALTER COLUMN secret SET NOT NULL,
  ADD CONSTRAINT capture_shares_secret_nonempty
    CHECK (length(secret) >= 32);

-- +goose Down

ALTER TABLE capture_shares DROP COLUMN secret;
