-- +goose Up

-- notify ⊥ hide decoupling for reminders. remind_at alone conflated two things:
-- "notify me at T" and "hide this from browse until T". This splits off the
-- visibility half.
--
--   remind_hide = true  (default) — the existing behaviour: a capture with a
--                        future remind_at is hidden from the browse list until it
--                        comes due, then resurfaces.
--   remind_hide = false — notify-only: the capture stays in the browse list the
--                        whole time and STILL fires its notification at remind_at.
--                        The use case is a pinned desktop sticky that should get a
--                        ping without disappearing.
--
-- Only the browse-side read (ListCaptures/ListCapturePage) consults this column.
-- Notification scheduling (DueReminders/PendingReminders) never looks at it, so
-- notify-only reminders still fire. Default true keeps every existing row's
-- behaviour unchanged.
ALTER TABLE captures ADD COLUMN remind_hide BOOLEAN NOT NULL DEFAULT true;

-- +goose Down

ALTER TABLE captures DROP COLUMN remind_hide;
