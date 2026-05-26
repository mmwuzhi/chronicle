-- name: UpsertWeeklyReport :one
INSERT INTO weekly_reports (user_id, week_start, data)
VALUES ($1, $2, $3)
ON CONFLICT (user_id, week_start)
DO UPDATE SET data = $3
RETURNING *;

-- name: ListWeeklyReports :many
SELECT * FROM weekly_reports
WHERE user_id = $1
ORDER BY week_start DESC;

-- name: GetWeeklyReport :one
SELECT * FROM weekly_reports
WHERE id = $1 AND user_id = $2;

-- name: GetWeeklyReportBySlug :one
SELECT wr.* FROM weekly_reports wr
JOIN public_shares ps ON ps.report_id = wr.id
WHERE ps.slug = $1;
