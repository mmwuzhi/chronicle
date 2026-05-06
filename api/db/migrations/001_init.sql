-- +goose Up

CREATE TABLE users (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT        NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE refresh_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT        NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked     BOOLEAN     NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON refresh_tokens(user_id);
CREATE INDEX ON refresh_tokens(token_hash);

CREATE TABLE projects (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT        NOT NULL,
    color      TEXT        NOT NULL DEFAULT '#6366f1',
    archived   BOOLEAN     NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON projects(user_id);

CREATE TYPE task_type   AS ENUM ('task', 'idea', 'routine', 'log');
CREATE TYPE task_status AS ENUM ('todo', 'in_progress', 'done', 'archived');

CREATE TABLE tasks (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    project_id UUID        REFERENCES projects(id) ON DELETE SET NULL,
    title      TEXT        NOT NULL,
    type       task_type   NOT NULL DEFAULT 'task',
    status     task_status NOT NULL DEFAULT 'todo',
    due_at     TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX ON tasks(user_id);
CREATE INDEX ON tasks(project_id);
CREATE INDEX ON tasks(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE TABLE time_blocks (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    task_id      UUID        REFERENCES tasks(id) ON DELETE SET NULL,
    started_at   TIMESTAMPTZ NOT NULL,
    ended_at     TIMESTAMPTZ,
    duration_sec INTEGER,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON time_blocks(user_id);
CREATE INDEX ON time_blocks(task_id);
CREATE INDEX ON time_blocks(user_id, started_at);

CREATE TABLE log_entries (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    task_id    UUID        REFERENCES tasks(id) ON DELETE SET NULL,
    body       TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX ON log_entries(user_id);
CREATE INDEX ON log_entries(user_id, created_at);

CREATE TYPE capture_media_type    AS ENUM ('text', 'image', 'audio');
CREATE TYPE capture_classified_as AS ENUM ('task', 'idea', 'routine', 'log', 'unclassified');

CREATE TABLE captures (
    id            UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID                  NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_text      TEXT,
    media_url     TEXT,
    media_type    capture_media_type    NOT NULL DEFAULT 'text',
    classified_as capture_classified_as NOT NULL DEFAULT 'unclassified',
    task_id       UUID                  REFERENCES tasks(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ           NOT NULL DEFAULT now()
);

CREATE INDEX ON captures(user_id);
CREATE INDEX ON captures(user_id, created_at);

CREATE TABLE weekly_reports (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    week_start DATE        NOT NULL,
    data       JSONB       NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, week_start)
);

CREATE INDEX ON weekly_reports(user_id);

CREATE TABLE public_shares (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id  UUID        NOT NULL REFERENCES weekly_reports(id) ON DELETE CASCADE,
    slug       TEXT        NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down

DROP TABLE IF EXISTS public_shares;
DROP TABLE IF EXISTS weekly_reports;
DROP TABLE IF EXISTS captures;
DROP TABLE IF EXISTS log_entries;
DROP TABLE IF EXISTS time_blocks;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS projects;
DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS users;

DROP TYPE IF EXISTS capture_classified_as;
DROP TYPE IF EXISTS capture_media_type;
DROP TYPE IF EXISTS task_status;
DROP TYPE IF EXISTS task_type;
