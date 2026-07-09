-- +goose Up

-- Link enrichment: a text capture that carries a URL gets the page's readable
-- text fetched into `transcript`, so the capture becomes findable by what the
-- page says — not just the bare URL the user pasted. It reuses the transcript
-- modality end to end: `transcript` already feeds both the FTS index
-- (00013_recall_search) and the RAG embedding (ragsvc `_CONTENT`), so no
-- search/embedding change is needed.
--
-- The fetch is scheduled through the existing transcription_status machine.
-- A link job is a capture with NO media_key; a media transcription (Whisper/
-- OCR) has one. The two workers partition the same queue by that column.
ALTER TABLE captures ADD COLUMN link_url TEXT;

-- The link-fetch worker's claim index: pending/processing text captures (no
-- media). Mirrors captures_pending_transcription_idx, partitioned by
-- media_key IS NULL so the two workers never scan each other's rows.
CREATE INDEX captures_pending_linkfetch_idx
ON captures (next_transcription_at, created_at)
WHERE transcription_status IN ('pending', 'processing') AND media_key IS NULL;

-- +goose Down

DROP INDEX IF EXISTS captures_pending_linkfetch_idx;
ALTER TABLE captures DROP COLUMN IF EXISTS link_url;
