-- +goose Up

-- User-authored negative retrieval preferences. These are derived preferences,
-- not Capture content: hard deletion is intentional and powers Undo/reset.
-- Search stores only a user-scoped hash of the normalized query; Related stores
-- directional rows in both directions so either Capture excludes the pair.
CREATE TABLE retrieval_dismissals (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  surface    TEXT NOT NULL CHECK (surface IN ('search', 'related')),
  query_hash BYTEA,
  anchor_id  UUID REFERENCES captures(id) ON DELETE CASCADE,
  target_id  UUID NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT retrieval_dismissals_shape CHECK (
    (surface = 'search' AND query_hash IS NOT NULL AND anchor_id IS NULL)
    OR
    (surface = 'related' AND query_hash IS NULL AND anchor_id IS NOT NULL
      AND anchor_id <> target_id)
  )
);

CREATE UNIQUE INDEX retrieval_dismissals_search_unique
  ON retrieval_dismissals(user_id, query_hash, target_id)
  WHERE surface = 'search';

CREATE INDEX retrieval_dismissals_search_prune
  ON retrieval_dismissals(user_id, created_at DESC)
  WHERE surface = 'search';

CREATE UNIQUE INDEX retrieval_dismissals_related_unique
  ON retrieval_dismissals(user_id, anchor_id, target_id)
  WHERE surface = 'related';

CREATE INDEX retrieval_dismissals_related_lookup
  ON retrieval_dismissals(user_id, anchor_id)
  WHERE surface = 'related';

-- +goose Down

DROP TABLE IF EXISTS retrieval_dismissals;
