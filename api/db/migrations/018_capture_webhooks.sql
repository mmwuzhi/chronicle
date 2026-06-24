-- +goose Up

-- Event-driven outbound (ported from rag/webhook.py). A capture that matches a
-- rule — any keyword as a substring of its content OR semantic cosine >=
-- threshold — fires a templated POST to an external URL. Matching + delivery run
-- in the ragsvc sidecar after indexing (it has the embedding); Go owns this
-- rules table and the CRUD API.
--
-- NOTE: this is workflow automation, which the product guardrails normally
-- avoid; added at the user's explicit request. Soft delete via deleted_at per
-- the project convention (never hard-DELETE user data).
CREATE TABLE capture_webhooks (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name               TEXT NOT NULL,
    target_url         TEXT NOT NULL,
    keywords           TEXT[] NOT NULL DEFAULT '{}',
    semantic_query     TEXT,
    semantic_threshold DOUBLE PRECISION NOT NULL DEFAULT 0.6,
    payload_template   TEXT NOT NULL,
    enabled            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ
);

CREATE INDEX capture_webhooks_user_idx
ON capture_webhooks (user_id)
WHERE deleted_at IS NULL;

-- +goose Down

DROP TABLE IF EXISTS capture_webhooks;
