-- +goose Up

-- The #todo text tag is now the todo facet's only entry point: todo_at/done_at
-- are derived from the raw text on every save (see internal/capture/todotag.go).
-- Backfill the tag into every capture that was flagged through the old
-- button/endpoint path, so no todo-ness lives only in the columns: open todos
-- get " #todo", completed ones " #todo(done:YYYY-MM-DD)" dated from done_at.
-- Trashed captures are included so a restore stays consistent. The guard regex
-- skips texts that already carry one of the exact runtime-valid shapes: #todo,
-- #todo(done), or #todo(done:YYYY-MM-DD). The trailing boundary deliberately
-- excludes '(' so malformed parameters such as #todo(later) do not make a row
-- look canonical; those rows receive a valid tag and become text/column-consistent.
UPDATE captures
SET raw_text = CASE
      WHEN raw_text IS NULL OR raw_text = '' THEN ''
      ELSE raw_text || ' '
    END ||
    CASE
      WHEN done_at IS NOT NULL
        THEN '#todo(done:' || to_char(done_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') || ')'
      ELSE '#todo'
    END
WHERE todo_at IS NOT NULL
  AND (
    raw_text IS NULL
    OR raw_text !~ '(^|[[:space:]])#todo(\(done(:[0-9]{4}-[0-9]{2}-[0-9]{2})?\))?([^[:alnum:]_(-]|$)'
  );

-- +goose Down

-- Best-effort reversal: strip one trailing #todo token (the shape Up appended).
-- Hand-typed tags elsewhere in the text are left alone; Up never modified
-- todo_at/done_at, so the columns still carry the pre-tag state.
UPDATE captures
SET raw_text = NULLIF(regexp_replace(raw_text, '[[:space:]]*#todo(\(done(:\d{4}-\d{2}-\d{2})?\))?$', ''), '')
WHERE todo_at IS NOT NULL AND raw_text IS NOT NULL;
