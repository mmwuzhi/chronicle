-- name: ListOnThisDay :many
-- Captures from the same calendar day (month + day) in an earlier period —
-- "on this day" resurfacing. Today's own captures are excluded (created_at is
-- before the start of today), so this only surfaces genuinely older memories.
-- Month/day and "today" are evaluated in the caller's local calendar using
-- timezone_offset_minutes (same sign as JavaScript getTimezoneOffset: UTC minus
-- local). created_at stays stored in UTC; the offset is only for calendar-day
-- comparison.
WITH clock AS (
  SELECT
    now() AS now_utc,
    make_interval(mins => sqlc.arg('timezone_offset_minutes')::int) AS tz_offset
)
SELECT c.* FROM captures c, clock
WHERE user_id = $1
  AND deleted_at IS NULL
  AND EXTRACT(MONTH FROM c.created_at - clock.tz_offset) = EXTRACT(MONTH FROM clock.now_utc - clock.tz_offset)
  AND EXTRACT(DAY FROM c.created_at - clock.tz_offset) = EXTRACT(DAY FROM clock.now_utc - clock.tz_offset)
  AND c.created_at - clock.tz_offset < date_trunc('day', clock.now_utc - clock.tz_offset)
ORDER BY c.created_at DESC
LIMIT sqlc.arg('result_limit');

-- name: ListRediscover :many
-- A random handful of older captures (created more than a week ago) for
-- serendipitous recall — this is what keeps the review panel populated when
-- "on this day" is sparse in a young library. ORDER BY random() is fine at
-- personal scale; this is never a hot path.
SELECT * FROM captures
WHERE user_id = $1
  AND deleted_at IS NULL
  AND created_at < now() - interval '7 days'
ORDER BY random()
LIMIT sqlc.arg('result_limit');
