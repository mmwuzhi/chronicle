-- +goose Up

-- Collapse the productivity model into captures (Chronicle's capture-first
-- direction). Non-deleted tasks and log entries are MIGRATED into captures,
-- preserving the task's status/start/due/project/tracked time as a searchable
-- text footer. That footer is lossy, so the full source tables are ALSO archived
-- to recoverable archived_* tables before being dropped — together that means no
-- structured field is lost. weekly_reports / public_shares are derived/sharing
-- surfaces captures don't carry and are archived the same way.
--
-- Forward-only: see the Down section. Migrated captures are not yet embedded /
-- extracted — run the RAG backfill (POST /backfill) afterward to index them.

-- Active tasks / log_entries are migrated into captures below, but the capture
-- footer is lossy: due_at keeps only its date (the time is dropped), and the task
-- UUID / project_id link and a log's task_id are not represented at all. DROP TABLE
-- would then lose those structured fields outright (and hard-delete soft-deleted
-- rows, which carry deleted_at). Archive the ENTIRE tables first — active,
-- soft-deleted, and all — so every structured field stays recoverable, the same
-- wholesale approach used for time_blocks / projects below. The captures are the
-- capture-first surface; these archive tables are the recoverable source of truth.
CREATE TABLE archived_tasks AS SELECT * FROM tasks;
CREATE TABLE archived_log_entries AS SELECT * FROM log_entries;
-- Archive the ENTIRE time_blocks table before the DROP. The migration only folds
-- an aggregate [tracked: Xh Ym] per active task into the capture footer, which is
-- lossy: each block's individual started_at/ended_at and duration would be gone
-- forever once time_blocks is dropped. Archiving every row (active, soft-deleted,
-- and parent-task-soft-deleted alike) preserves the raw time-tracking history —
-- the same wholesale approach used for archived_projects below. The footer stays a
-- convenience view; this table is the recoverable source of truth.
CREATE TABLE archived_time_blocks AS SELECT * FROM time_blocks;

-- CREATE TABLE AS copies data but not constraints, so the archive tables lose the
-- user_id → users(id) ON DELETE CASCADE that the source tables had. Account
-- deletion (DELETE FROM users) relies on that cascade; restore it so a user's
-- archived rows are removed when they delete their account (no orphaned PII).
ALTER TABLE archived_tasks       ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE archived_log_entries ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE archived_time_blocks ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- tasks → captures (active only). type maps 1:1 onto capture_classified_as; media
-- carried; created_at preserved; a footer carries the fields captures lacks.
WITH tracked AS (
  SELECT task_id, SUM(COALESCE(duration_sec, 0)) AS secs
  FROM time_blocks
  WHERE task_id IS NOT NULL AND deleted_at IS NULL   -- exclude soft-deleted time
  GROUP BY task_id
)
INSERT INTO captures (user_id, raw_text, media_url, media_type, classified_as, source, created_at)
SELECT
  t.user_id,
  t.title || E'\n\n— ' || concat_ws(' ',
    CASE WHEN p.name IS NOT NULL THEN '[project: ' || p.name || ']' END,
    '[status: ' || t.status::text || ']',
    -- start_at (migration 009) is a real task field; without this clause the DROP
    -- below would lose every active task's scheduled start time. Carry it in the
    -- footer alongside [due:], including the time component since a start time is
    -- meaningful, not just a date.
    CASE WHEN t.start_at IS NOT NULL THEN '[start: ' || to_char(t.start_at, 'YYYY-MM-DD HH24:MI') || ']' END,
    CASE WHEN t.due_at IS NOT NULL THEN '[due: ' || to_char(t.due_at, 'YYYY-MM-DD') || ']' END,
    CASE WHEN tr.secs > 0
      THEN '[tracked: ' || (tr.secs / 3600) || 'h ' || ((tr.secs % 3600) / 60) || 'm]'
    END
  ),
  t.media_url,
  CASE WHEN t.media_type IN ('text', 'image', 'audio')
    THEN t.media_type::capture_media_type ELSE 'text' END,
  t.type::text::capture_classified_as,
  'migrated',
  t.created_at
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
LEFT JOIN tracked tr ON tr.task_id = t.id
WHERE t.deleted_at IS NULL;

-- log_entries → captures (active, non-empty body only). Migration 012 created a
-- body='' log entry per time_block as a time-tracking record; those carry no
-- content (their duration is already in the task [tracked] footer), so skip them
-- rather than create empty "— [on: task]" noise captures.
INSERT INTO captures (user_id, raw_text, media_type, classified_as, source, created_at)
SELECT
  l.user_id,
  l.body || COALESCE(E'\n\n— [on: ' || t.title || ']', ''),
  'text',
  'log',
  'migrated',
  l.created_at
FROM log_entries l
LEFT JOIN tasks t ON t.id = l.task_id
WHERE l.deleted_at IS NULL AND btrim(l.body) <> '';

-- Sever the capture→task link, then drop the productivity tables (FK order).
-- The task_status / task_type enums are intentionally NOT dropped: the
-- archived_tasks preservation table keeps its status/type columns of those types,
-- so the enums must outlive the source table.
ALTER TABLE captures DROP COLUMN task_id;

-- projects carry no deleted_at (only `archived`), and a task-less project produces
-- no migrated capture, so DROP would hard-delete its name/color/archived outright.
-- Archive the whole table first (recoverable) so no user data is lost, matching the
-- archived_tasks/log_entries/time_blocks tables created above. The user_id →
-- users(id) cascade is restored (CREATE TABLE AS drops constraints) so a user's
-- archived projects are removed when they delete their account.
CREATE TABLE archived_projects AS SELECT * FROM projects;
ALTER TABLE archived_projects ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- weekly_reports.data (the report JSONB snapshot) and public_shares.slug (live
-- share links) are user-owned and not derivable once tasks/time_blocks are gone,
-- so archive both before the DROP — same no-data-loss principle as archived_*
-- above, not an "outright" drop. public_shares has no user_id of its own, so pull
-- it through report_id while weekly_reports still exists; that lets the archive
-- carry user_id and keep the account-deletion cascade (no orphaned PII).
CREATE TABLE archived_weekly_reports AS SELECT * FROM weekly_reports;
ALTER TABLE archived_weekly_reports ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
CREATE TABLE archived_public_shares AS
  SELECT ps.*, wr.user_id FROM public_shares ps
  JOIN weekly_reports wr ON wr.id = ps.report_id;
ALTER TABLE archived_public_shares ADD FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

DROP TABLE public_shares;
DROP TABLE weekly_reports;
DROP TABLE log_entries;
DROP TABLE time_blocks;
DROP TABLE tasks;
DROP TABLE projects;

-- +goose Down

-- +goose StatementBegin
DO $$
BEGIN
  RAISE EXCEPTION 'Migration 016 is forward-only: tasks/projects/log_entries/time_blocks/weekly_reports/public_shares were merged into captures and dropped (soft-deleted rows archived to archived_*). Restore from the pre-migration pg_dump backup instead.';
END $$;
-- +goose StatementEnd
