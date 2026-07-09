-- name: ListOnThisDay :many
-- Captures from the same calendar day (month + day) in an earlier period —
-- "on this day" resurfacing. Today's own captures are excluded (created_at is
-- before the start of today), so this only surfaces genuinely older memories.
-- Month/day and "today" are evaluated in the server clock (UTC), matching how
-- the rest of the app stores and compares created_at.
SELECT * FROM captures
WHERE user_id = $1
  AND deleted_at IS NULL
  AND EXTRACT(MONTH FROM created_at) = EXTRACT(MONTH FROM now())
  AND EXTRACT(DAY FROM created_at) = EXTRACT(DAY FROM now())
  AND created_at < date_trunc('day', now())
ORDER BY created_at DESC
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
