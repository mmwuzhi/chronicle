-- +goose Up
CREATE TABLE oauth_accounts (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider    TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_id)
);

CREATE INDEX ON oauth_accounts(user_id);

INSERT INTO oauth_accounts (user_id, provider, provider_id)
SELECT id, oauth_provider, oauth_provider_id FROM users
WHERE oauth_provider IS NOT NULL AND oauth_provider_id IS NOT NULL;

ALTER TABLE users DROP COLUMN oauth_provider, DROP COLUMN oauth_provider_id;

-- +goose Down
ALTER TABLE users
    ADD COLUMN oauth_provider    TEXT,
    ADD COLUMN oauth_provider_id TEXT;

UPDATE users u SET
    oauth_provider = oa.provider,
    oauth_provider_id = oa.provider_id
FROM (
    SELECT DISTINCT ON (user_id) user_id, provider, provider_id
    FROM oauth_accounts ORDER BY user_id, created_at DESC
) oa
WHERE oa.user_id = u.id;

CREATE UNIQUE INDEX users_oauth_idx ON users (oauth_provider, oauth_provider_id)
    WHERE oauth_provider IS NOT NULL;

DROP TABLE oauth_accounts;
