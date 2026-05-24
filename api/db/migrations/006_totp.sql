-- +goose Up
ALTER TABLE users ADD COLUMN totp_secret TEXT;
ALTER TABLE users ADD COLUMN totp_enabled BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE recovery_codes (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT NOT NULL,
    used      BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX ON recovery_codes(user_id);

-- +goose Down
DROP TABLE recovery_codes;
ALTER TABLE users DROP COLUMN totp_secret, DROP COLUMN totp_enabled;
