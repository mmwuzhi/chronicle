-- +goose Up

-- Replace the decorative classified_as enum (task/idea/routine/log/unclassified,
-- inherited verbatim from the pre-016 task app) with the todo facet: two nullable
-- timestamps encoding three states — (NULL, NULL) plain capture, (t, NULL) open
-- todo, (t, t') completed todo. Classification carried no behavior anywhere in
-- the system; todo-ness is the one classification that does (checkbox, progress),
-- so it becomes a facet column like remind_at instead of a taxonomy.
ALTER TABLE captures ADD COLUMN todo_at TIMESTAMPTZ;
ALTER TABLE captures ADD COLUMN done_at TIMESTAMPTZ;

-- Captures the user had classified as 'task' are the actionable ones: carry them
-- over as open todos, dating the flag from capture creation. The idea/routine/log
-- labels are retired from product behavior — they were display-only, the 016
-- migration footer text (e.g. "[status: ...]") stays searchable in raw_text, and
-- the compatibility column plus archived_tasks preserve every original value.
UPDATE captures SET todo_at = created_at WHERE classified_as = 'task';

-- "Only todos complete": the schema itself declares that done is an attribute of
-- the todo facet, not of capture-ness.
ALTER TABLE captures ADD CONSTRAINT captures_done_implies_todo
  CHECK (done_at IS NULL OR todo_at IS NOT NULL);

-- Keep classified_as and its enum as compatibility-only storage during this
-- first production rollout. New code never reads or writes the field, but
-- retaining it avoids destructive schema change and preserves rollback data.

-- Serves the browse-path todo filter (open/done tabs). Partial: most captures
-- are not todos.
CREATE INDEX captures_todo_idx ON captures (user_id, todo_at)
  WHERE todo_at IS NOT NULL AND deleted_at IS NULL;

-- +goose Down

-- The compatibility classified_as column was retained by Up, so reversal only
-- removes the additive todo facet.
DROP INDEX IF EXISTS captures_todo_idx;

ALTER TABLE captures DROP CONSTRAINT captures_done_implies_todo;
ALTER TABLE captures DROP COLUMN done_at;
ALTER TABLE captures DROP COLUMN todo_at;
