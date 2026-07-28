-- +goose Up

-- Short-lived reservation for multipart upload idempotency. It serializes the
-- external R2 write without holding a PostgreSQL connection or transaction
-- across the network request. Completed captures remain the durable replay
-- record; an expired processing reservation can be safely reclaimed.
CREATE TABLE capture_upload_operations (
    id           UUID        PRIMARY KEY,
    capture_id   UUID        NOT NULL UNIQUE,
    user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    request_hash TEXT        NOT NULL,
    lease_until  TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX capture_upload_operations_user_idx
    ON capture_upload_operations(user_id, created_at DESC);

-- +goose Down

DROP TABLE capture_upload_operations;
