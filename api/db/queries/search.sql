-- name: SearchCaptures :many
-- params computes the literal-substring pattern once: ILIKE wildcards in the
-- user's query (% _ \) are escaped so they match themselves instead of acting
-- as wildcards — an unescaped "%" would ILIKE-match every capture and inflate
-- its relevance as a fake literal hit. FTS and similarity() keep the raw query.
WITH params AS (
  SELECT
    sqlc.arg(query)::text AS q,
    '%' || replace(replace(replace(sqlc.arg(query)::text,
      '\', '\\'), '%', '\%'), '_', '\_') || '%' AS q_like
),
ranked AS (
  SELECT
    captures.*,
    CASE
      WHEN raw_text ILIKE params.q_like THEN 'rawText'
      WHEN transcript ILIKE params.q_like THEN 'transcript'
      WHEN ts_rank_cd(
        to_tsvector('simple', COALESCE(raw_text, '')),
        websearch_to_tsquery('simple', params.q)
      ) >= ts_rank_cd(
        to_tsvector('simple', COALESCE(transcript, '')),
        websearch_to_tsquery('simple', params.q)
      ) THEN 'rawText'
      ELSE 'transcript'
    END AS matched_field,
    (
      CASE
        WHEN raw_text ILIKE params.q_like THEN 2.0
        WHEN transcript ILIKE params.q_like THEN 1.8
        ELSE 0.0
      END
      + GREATEST(
          similarity(COALESCE(raw_text, ''), params.q),
          similarity(COALESCE(transcript, ''), params.q)
        )
      + ts_rank_cd(
          to_tsvector('simple', COALESCE(raw_text, '') || ' ' || COALESCE(transcript, '')),
          websearch_to_tsquery('simple', params.q)
        )
    )::double precision AS relevance
  FROM captures, params
  WHERE user_id = sqlc.arg(user_id)
    AND deleted_at IS NULL
    AND (
      raw_text ILIKE params.q_like
      OR transcript ILIKE params.q_like
      OR to_tsvector(
        'simple',
        COALESCE(raw_text, '') || ' ' || COALESCE(transcript, '')
      ) @@ websearch_to_tsquery('simple', params.q)
    )
)
SELECT * FROM ranked
ORDER BY relevance DESC, created_at DESC
LIMIT sqlc.arg('result_limit');
