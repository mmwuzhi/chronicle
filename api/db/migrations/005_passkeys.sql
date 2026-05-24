-- +goose Up
CREATE TABLE passkeys (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id BYTEA NOT NULL UNIQUE,
    public_key    BYTEA NOT NULL,
    aaguid        BYTEA,
    sign_count    BIGINT NOT NULL DEFAULT 0,
    name          TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON passkeys(user_id);

-- +goose Down
DROP TABLE passkeys;
