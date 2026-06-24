-- name: CreateWebhook :one
INSERT INTO capture_webhooks (
  user_id, name, target_url, keywords, semantic_query, semantic_threshold,
  payload_template, enabled
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: ListWebhooks :many
SELECT * FROM capture_webhooks
WHERE user_id = $1 AND deleted_at IS NULL
ORDER BY created_at DESC;

-- name: GetWebhook :one
SELECT * FROM capture_webhooks
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;

-- name: UpdateWebhook :one
UPDATE capture_webhooks
SET name               = $3,
    target_url         = $4,
    keywords           = $5,
    semantic_query     = $6,
    semantic_threshold = $7,
    payload_template   = $8,
    enabled            = $9
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteWebhook :one
UPDATE capture_webhooks
SET deleted_at = now()
WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
RETURNING id;
