-- name: SearchCaptures :many
WITH ranked AS (
  SELECT
    captures.*,
    CASE
      WHEN raw_text ILIKE '%' || sqlc.arg(query)::text || '%' THEN 'rawText'
      WHEN transcript ILIKE '%' || sqlc.arg(query)::text || '%' THEN 'transcript'
      WHEN ts_rank_cd(
        to_tsvector('simple', COALESCE(raw_text, '')),
        websearch_to_tsquery('simple', sqlc.arg(query)::text)
      ) >= ts_rank_cd(
        to_tsvector('simple', COALESCE(transcript, '')),
        websearch_to_tsquery('simple', sqlc.arg(query)::text)
      ) THEN 'rawText'
      ELSE 'transcript'
    END AS matched_field,
    (
      CASE
        WHEN raw_text ILIKE '%' || sqlc.arg(query)::text || '%' THEN 2.0
        WHEN transcript ILIKE '%' || sqlc.arg(query)::text || '%' THEN 1.8
        ELSE 0.0
      END
      + GREATEST(
          similarity(COALESCE(raw_text, ''), sqlc.arg(query)::text),
          similarity(COALESCE(transcript, ''), sqlc.arg(query)::text)
        )
      + ts_rank_cd(
          to_tsvector('simple', COALESCE(raw_text, '') || ' ' || COALESCE(transcript, '')),
          websearch_to_tsquery('simple', sqlc.arg(query)::text)
        )
    )::double precision AS relevance
  FROM captures
  WHERE user_id = sqlc.arg(user_id)
    AND deleted_at IS NULL
    AND (
      raw_text ILIKE '%' || sqlc.arg(query)::text || '%'
      OR transcript ILIKE '%' || sqlc.arg(query)::text || '%'
      OR to_tsvector(
        'simple',
        COALESCE(raw_text, '') || ' ' || COALESCE(transcript, '')
      ) @@ websearch_to_tsquery('simple', sqlc.arg(query)::text)
    )
)
SELECT * FROM ranked
ORDER BY relevance DESC, created_at DESC
LIMIT 20;
