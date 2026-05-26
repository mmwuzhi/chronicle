-- name: CreatePublicShare :one
INSERT INTO public_shares (report_id, slug)
VALUES ($1, $2)
RETURNING *;

-- name: GetPublicShareByReportID :one
SELECT * FROM public_shares WHERE report_id = $1;

-- name: GetPublicShareBySlug :one
SELECT * FROM public_shares WHERE slug = $1;

-- name: DeletePublicShareByReportID :exec
DELETE FROM public_shares WHERE report_id = $1;
