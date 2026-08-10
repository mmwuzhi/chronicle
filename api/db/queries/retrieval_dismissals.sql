-- name: AddSearchDismissal :exec
INSERT INTO retrieval_dismissals (user_id, surface, query_hash, query_text, target_id)
VALUES (
  sqlc.arg('user_id'), 'search', sqlc.arg('query_hash'),
  sqlc.arg('query_text'), sqlc.arg('target_id')
)
ON CONFLICT (user_id, query_hash, target_id) WHERE surface = 'search'
DO UPDATE SET created_at = now();

-- name: LockSearchDismissals :exec
-- Serialize a user's feedback mutations so the retention bound is strict even
-- when several devices add/remove preferences concurrently.
SELECT pg_advisory_xact_lock(hashtextextended(
  'search-dismissals:' || sqlc.arg('user_id')::uuid::text,
  0
));

-- name: PruneSearchDismissals :exec
-- Search feedback is useful recent history, not an unbounded event log. ctid is
-- safe here because selection and deletion happen in one statement.
DELETE FROM retrieval_dismissals d
WHERE d.ctid IN (
  SELECT victim.ctid
  FROM retrieval_dismissals victim
  WHERE victim.user_id = sqlc.arg('user_id')
    AND victim.surface = 'search'
  ORDER BY victim.created_at DESC, victim.query_hash, victim.target_id
  OFFSET sqlc.arg('keep_limit')
);

-- name: RemoveSearchDismissal :exec
DELETE FROM retrieval_dismissals
WHERE user_id = sqlc.arg('user_id')
  AND surface = 'search'
  AND query_hash = sqlc.arg('query_hash')
  AND target_id = sqlc.arg('target_id');

-- name: ListSearchDismissedIDs :many
-- The normal search path needs only stable IDs. Keeping content out of this
-- query prevents large Capture bodies from amplifying every search request.
SELECT c.id
FROM retrieval_dismissals d
JOIN captures c ON c.id = d.target_id AND c.user_id = d.user_id
WHERE d.user_id = sqlc.arg('user_id')
  AND d.surface = 'search'
  AND d.query_hash = sqlc.arg('query_hash')
  AND c.deleted_at IS NULL
ORDER BY d.created_at, d.target_id;

-- name: ListSearchDismissedCaptures :many
-- Recovery returns every live preference (the table is retention-bounded), but
-- only a bounded preview of each Capture. Restoring uses the ID; the full body
-- is neither needed nor safe to materialize here.
SELECT
  c.id,
  left(COALESCE(NULLIF(c.transcript, ''), c.raw_text, ''), 512)::text AS content,
  c.created_at,
  c.media_type
FROM retrieval_dismissals d
JOIN captures c ON c.id = d.target_id AND c.user_id = d.user_id
WHERE d.user_id = sqlc.arg('user_id')
  AND d.surface = 'search'
  AND d.query_hash = sqlc.arg('query_hash')
  AND c.deleted_at IS NULL
ORDER BY d.created_at, d.target_id;

-- name: AddRelatedDismissal :exec
INSERT INTO retrieval_dismissals (user_id, surface, anchor_id, target_id)
VALUES
  (sqlc.arg('user_id'), 'related', sqlc.arg('anchor_id')::uuid, sqlc.arg('target_id')),
  (sqlc.arg('user_id'), 'related', sqlc.arg('target_id'), sqlc.arg('anchor_id')::uuid)
ON CONFLICT (user_id, anchor_id, target_id) WHERE surface = 'related'
DO NOTHING;

-- name: RemoveRelatedDismissal :exec
DELETE FROM retrieval_dismissals
WHERE user_id = sqlc.arg('user_id')
  AND surface = 'related'
  AND (
    (anchor_id = sqlc.arg('anchor_id')::uuid AND target_id = sqlc.arg('target_id'))
    OR
    (anchor_id = sqlc.arg('target_id') AND target_id = sqlc.arg('anchor_id')::uuid)
  );

-- name: ListRelatedDismissedIDs :many
SELECT target_id
FROM retrieval_dismissals
WHERE user_id = sqlc.arg('user_id')
  AND surface = 'related'
  AND anchor_id = sqlc.arg('anchor_id')::uuid
ORDER BY created_at, target_id;
