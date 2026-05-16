-- +goose Up
ALTER TABLE users
    ADD COLUMN email_verified         BOOLEAN     NOT NULL DEFAULT false,
    ADD COLUMN email_verify_token     TEXT,
    ADD COLUMN password_reset_token   TEXT,
    ADD COLUMN password_reset_expires TIMESTAMPTZ;

-- +goose Down
ALTER TABLE users
    DROP COLUMN email_verified,
    DROP COLUMN email_verify_token,
    DROP COLUMN password_reset_token,
    DROP COLUMN password_reset_expires;
