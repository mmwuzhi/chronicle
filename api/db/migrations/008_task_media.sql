-- +goose Up
ALTER TABLE tasks ADD COLUMN media_url  TEXT;
ALTER TABLE tasks ADD COLUMN media_type TEXT;

-- +goose Down
ALTER TABLE tasks DROP COLUMN media_url;
ALTER TABLE tasks DROP COLUMN media_type;
