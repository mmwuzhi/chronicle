-- +goose Up

-- Explicit, user-made associations between two captures ("relate these"). The
-- product's P1 "Related captures" surface pairs durable user links with the
-- AI-suggested semantic neighbours that ragsvc serves at query time.
--
-- Undirected: the pair is normalised so the smaller UUID is always a_id, making
-- (a_id, b_id) a natural primary key that enforces uniqueness no matter which
-- capture the link was created from (the CHECK guards the normalisation).
--
-- Hard DELETE is allowed on THIS table — it is a derived association table, not a
-- user-content table. captures/log_entries keep their soft-delete guarantee. A
-- soft-deleted capture's links simply stop surfacing (the read joins captures and
-- filters deleted_at IS NULL) and reappear on restore, so no soft-delete cascade
-- is needed. The FK cascade only fires on a (never-issued) hard delete of a
-- capture.
CREATE TABLE capture_links (
  a_id       UUID NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
  b_id       UUID NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (a_id, b_id),
  CONSTRAINT capture_links_ordered CHECK (a_id < b_id)
);

CREATE INDEX capture_links_user_idx ON capture_links(user_id);
-- The PK covers a_id lookups; this covers the b_id side of the undirected join.
CREATE INDEX capture_links_b_idx ON capture_links(b_id);

-- +goose Down

DROP TABLE IF EXISTS capture_links;
