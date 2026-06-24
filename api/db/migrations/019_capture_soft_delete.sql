-- +goose Up

-- Soft delete for captures (project convention: never hard-DELETE user data).
-- The desktop main window and web feed both expose a delete affordance; deleting
-- must set deleted_at, not remove the row. Every user-facing read (browse, page,
-- context, reminders, keyword search) filters deleted_at IS NULL; the ragsvc
-- semantic recall path should do the same when it reads captures.
ALTER TABLE captures ADD COLUMN deleted_at TIMESTAMPTZ;

-- Partial index keeps the active-capture scans (the only ones that matter) lean.
CREATE INDEX captures_user_created_active_idx
ON captures (user_id, created_at DESC, id DESC)
WHERE deleted_at IS NULL;

-- +goose Down

DROP INDEX IF EXISTS captures_user_created_active_idx;
ALTER TABLE captures DROP COLUMN IF EXISTS deleted_at;
