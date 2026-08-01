-- +goose Up

-- Short-lived authentication state used by OAuth and WebAuthn. Keys are
-- stored as SHA-256 digests so a database read does not reveal bearer-style
-- handoff codes or challenges.
CREATE TABLE auth_ephemeral_states (
  purpose    TEXT        NOT NULL,
  key_hash   BYTEA       NOT NULL,
  payload    BYTEA       NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (purpose, key_hash),
  CONSTRAINT auth_ephemeral_states_key_hash_length
    CHECK (octet_length(key_hash) = 32)
);

CREATE INDEX auth_ephemeral_states_expires_at_idx
ON auth_ephemeral_states(expires_at);

-- Security-sensitive, low-volume limits use an anchored window. General API
-- traffic remains guarded in-process and may additionally be limited at the
-- Cloudflare edge, so normal requests do not write to PostgreSQL.
CREATE TABLE auth_rate_limits (
  scope             TEXT        NOT NULL,
  subject_hash      BYTEA       NOT NULL,
  attempts          INTEGER     NOT NULL DEFAULT 1,
  window_started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at        TIMESTAMPTZ NOT NULL,

  PRIMARY KEY (scope, subject_hash),
  CONSTRAINT auth_rate_limits_subject_hash_length
    CHECK (octet_length(subject_hash) = 32),
  CONSTRAINT auth_rate_limits_attempts_positive
    CHECK (attempts > 0)
);

CREATE INDEX auth_rate_limits_expires_at_idx
ON auth_rate_limits(expires_at);

-- +goose Down

DROP TABLE IF EXISTS auth_rate_limits;
DROP TABLE IF EXISTS auth_ephemeral_states;
