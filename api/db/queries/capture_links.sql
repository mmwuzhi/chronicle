-- name: AddCaptureLink :exec
-- Idempotent: normalises the pair (a_id < b_id) via LEAST/GREATEST so a link is
-- the same regardless of direction, then no-ops on a duplicate. The caller must
-- reject self-links (x = y) before calling; the CHECK constraint would otherwise
-- reject a_id = b_id.
INSERT INTO capture_links (a_id, b_id, user_id)
VALUES (
  LEAST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid),
  GREATEST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid),
  sqlc.arg('user_id')
)
ON CONFLICT (a_id, b_id) DO NOTHING;

-- name: LockCapturePair :exec
-- All link/dismissal mutations take the same transaction-scoped lock for an
-- undirected pair. Hash collisions only serialize unrelated pairs; they cannot
-- weaken correctness.
SELECT pg_advisory_xact_lock(hashtextextended(
  sqlc.arg('user_id')::uuid::text || ':' ||
  LEAST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid)::text || ':' ||
  GREATEST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid)::text,
  0
));

-- name: RemoveCaptureLink :exec
-- Hard delete of the normalised pair (derived association table — see migration
-- 021). user_id scoping prevents removing another user's link.
DELETE FROM capture_links
WHERE user_id = sqlc.arg('user_id')
  AND a_id = LEAST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid)
  AND b_id = GREATEST(sqlc.arg('x')::uuid, sqlc.arg('y')::uuid);

-- name: ListLinkedCaptures :many
-- Captures explicitly linked to a given capture, either direction. Joins captures
-- and filters deleted_at IS NULL, so links to a trashed capture are hidden until
-- it is restored. Newest first.
SELECT c.*
FROM captures c
JOIN capture_links l
  ON (l.a_id = c.id AND l.b_id = sqlc.arg('capture_id')::uuid)
  OR (l.b_id = c.id AND l.a_id = sqlc.arg('capture_id')::uuid)
WHERE l.user_id = sqlc.arg('user_id')
  AND c.deleted_at IS NULL
ORDER BY c.created_at DESC, c.id DESC;
