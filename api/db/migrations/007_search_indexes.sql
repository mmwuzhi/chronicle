-- +goose Up
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX captures_rawtext_trgm  ON captures    USING GIN (raw_text gin_trgm_ops) WHERE raw_text IS NOT NULL;
CREATE INDEX tasks_title_trgm        ON tasks       USING GIN (title    gin_trgm_ops);
CREATE INDEX logentries_body_trgm    ON log_entries USING GIN (body     gin_trgm_ops);

-- +goose Down
DROP INDEX IF EXISTS captures_rawtext_trgm;
DROP INDEX IF EXISTS tasks_title_trgm;
DROP INDEX IF EXISTS logentries_body_trgm;
