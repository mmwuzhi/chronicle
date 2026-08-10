-- +goose Up

-- Keep the portable normalized query alongside its account-scoped hash. The
-- text is needed only to export a user-authored preference and re-hash it for
-- the importing account; lookup continues to use query_hash.
ALTER TABLE retrieval_dismissals
  ADD COLUMN query_text TEXT;

ALTER TABLE retrieval_dismissals
  DROP CONSTRAINT retrieval_dismissals_shape;

-- Rows created by the immediately preceding migration cannot be made portable
-- because only their hash exists. Remove them instead of pretending an archive
-- can restore a preference whose query is unknowable.
DELETE FROM retrieval_dismissals
WHERE surface = 'search' AND query_text IS NULL;

ALTER TABLE retrieval_dismissals
  ADD CONSTRAINT retrieval_dismissals_shape CHECK (
    (surface = 'search' AND query_hash IS NOT NULL AND query_text IS NOT NULL
      AND anchor_id IS NULL)
    OR
    (surface = 'related' AND query_hash IS NULL AND query_text IS NULL
      AND anchor_id IS NOT NULL AND anchor_id <> target_id)
  );

-- +goose Down

ALTER TABLE retrieval_dismissals
  DROP CONSTRAINT retrieval_dismissals_shape;

ALTER TABLE retrieval_dismissals
  ADD CONSTRAINT retrieval_dismissals_shape CHECK (
    (surface = 'search' AND query_hash IS NOT NULL AND anchor_id IS NULL)
    OR
    (surface = 'related' AND query_hash IS NULL AND anchor_id IS NOT NULL
      AND anchor_id <> target_id)
  );

ALTER TABLE retrieval_dismissals
  DROP COLUMN query_text;
