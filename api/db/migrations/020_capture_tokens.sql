-- +goose Up

-- Long-lived, revocable capture tokens for headless quick-capture clients
-- (iOS Action Button shortcut, future automations). A static client cannot hold
-- the 15-min/1-hour access JWT and cannot do the refresh-cookie dance, so it
-- carries one of these tokens as `Authorization: Bearer chr_cap_...` instead.
--
-- Scope is intentionally create-only: the token middleware is wired solely onto
-- POST /captures, never onto reads, updates, deletes, reminders, or account
-- routes. A leaked token can append captures (bounded by the per-IP limiter) but
-- cannot read or exfiltrate existing data. Revocation is server-side and
-- immediate — every request looks the hash up here, with no caching.
--
-- Only the SHA-256 hash is stored (the raw value is high-entropy random, so a
-- fast hash is sufficient — same reasoning as refresh_tokens). The raw token is
-- shown to the user exactly once at creation.
CREATE TABLE capture_tokens (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   TEXT        NOT NULL UNIQUE,
    name         TEXT        NOT NULL,
    last_used_at TIMESTAMPTZ,
    revoked      BOOLEAN     NOT NULL DEFAULT false,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The settings list reads a user's tokens; the index keeps that scan lean.
CREATE INDEX capture_tokens_user_idx ON capture_tokens (user_id, created_at DESC);

-- +goose Down

DROP INDEX IF EXISTS capture_tokens_user_idx;
DROP TABLE IF EXISTS capture_tokens;
