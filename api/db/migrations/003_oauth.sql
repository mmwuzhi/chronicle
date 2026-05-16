-- +goose Up
ALTER TABLE users
    ALTER COLUMN password_hash DROP NOT NULL,
    ADD COLUMN oauth_provider    TEXT,
    ADD COLUMN oauth_provider_id TEXT;

CREATE UNIQUE INDEX users_oauth_idx ON users (oauth_provider, oauth_provider_id)
    WHERE oauth_provider IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS users_oauth_idx;
ALTER TABLE users
    DROP COLUMN oauth_provider,
    DROP COLUMN oauth_provider_id,
    ALTER COLUMN password_hash SET NOT NULL;
