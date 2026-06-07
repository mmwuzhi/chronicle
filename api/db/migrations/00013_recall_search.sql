-- +goose Up

CREATE INDEX captures_user_created_id_idx
ON captures(user_id, created_at DESC, id DESC);

CREATE INDEX captures_transcript_trgm
ON captures USING GIN (transcript gin_trgm_ops)
WHERE transcript IS NOT NULL;

CREATE INDEX captures_search_fts
ON captures USING GIN (
  to_tsvector('simple', COALESCE(raw_text, '') || ' ' || COALESCE(transcript, ''))
);

CREATE INDEX tasks_title_fts
ON tasks USING GIN (to_tsvector('simple', title))
WHERE deleted_at IS NULL;

CREATE INDEX logentries_body_fts
ON log_entries USING GIN (to_tsvector('simple', body))
WHERE deleted_at IS NULL;

-- +goose Down

DROP INDEX IF EXISTS logentries_body_fts;
DROP INDEX IF EXISTS tasks_title_fts;
DROP INDEX IF EXISTS captures_search_fts;
DROP INDEX IF EXISTS captures_transcript_trgm;
DROP INDEX IF EXISTS captures_user_created_id_idx;
