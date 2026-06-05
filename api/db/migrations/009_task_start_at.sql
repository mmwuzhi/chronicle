-- +goose Up
ALTER TABLE tasks ADD COLUMN start_at TIMESTAMPTZ;

-- +goose Down
ALTER TABLE tasks DROP COLUMN start_at;
