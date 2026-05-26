package report

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type handler struct {
	q         *db.Queries
	geminiKey string
}

func Register(api huma.API, pool *pgxpool.Pool, geminiKey string, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool), geminiKey: geminiKey}

	op := func(id, method, path, summary string, auth bool) huma.Operation {
		o := huma.Operation{
			OperationID: id,
			Method:      method,
			Path:        path,
			Summary:     summary,
			Tags:        []string{"reports"},
		}
		if auth {
			o.Middlewares = huma.Middlewares{authMW}
		}
		return o
	}

	huma.Register(api, op("generate-report", http.MethodPost, "/reports/generate", "Generate weekly report", true), h.generate)
	huma.Register(api, op("list-reports", http.MethodGet, "/reports", "List weekly reports", true), h.list)
	huma.Register(api, op("get-report", http.MethodGet, "/reports/{id}", "Get weekly report", true), h.get)
	huma.Register(api, op("share-report", http.MethodPost, "/reports/{id}/share", "Create public share", true), h.share)
	huma.Register(api, op("unshare-report", http.MethodDelete, "/reports/{id}/share", "Remove public share", true), h.unshare)
	huma.Register(api, op("get-shared-report", http.MethodGet, "/share/{slug}", "Get public report", false), h.getShared)
}

// --- types ---

type ReportStats struct {
	TasksCreated      int `json:"tasksCreated"`
	TasksDone         int `json:"tasksDone"`
	TotalTimeSec      int `json:"totalTimeSec"`
	CapturesCreated   int `json:"capturesCreated"`
	LogEntriesWritten int `json:"logEntriesWritten"`
}

type TaskSummary struct {
	Title       string `json:"title"`
	Status      string `json:"status"`
	ProjectName string `json:"projectName"`
	TimeSec     int    `json:"timeSec"`
}

type ReportData struct {
	Summary string        `json:"summary"`
	Stats   ReportStats   `json:"stats"`
	Tasks   []TaskSummary `json:"tasks"`
}

type ReportBody struct {
	ID        string     `json:"id"`
	WeekStart string     `json:"weekStart"`
	Data      ReportData `json:"data"`
	ShareSlug *string    `json:"shareSlug"`
	CreatedAt string     `json:"createdAt"`
}

// --- generate ---

type GenerateOutput struct {
	Body ReportBody
}

func (h *handler) generate(ctx context.Context, _ *struct{}) (*GenerateOutput, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	weekStart, weekEnd := currentWeekBounds()

	// Fetch week data
	tasks, _ := h.q.ListTasksInRange(ctx, db.ListTasksInRangeParams{
		UserID:      uid,
		CreatedAt:   pgtype.Timestamptz{Time: weekStart, Valid: true},
		CreatedAt_2: pgtype.Timestamptz{Time: weekEnd, Valid: true},
	})
	captures, _ := h.q.ListCapturesInRange(ctx, db.ListCapturesInRangeParams{
		UserID:      uid,
		CreatedAt:   pgtype.Timestamptz{Time: weekStart, Valid: true},
		CreatedAt_2: pgtype.Timestamptz{Time: weekEnd, Valid: true},
	})
	entries, _ := h.q.ListLogEntriesInRange(ctx, db.ListLogEntriesInRangeParams{
		UserID:      uid,
		CreatedAt:   pgtype.Timestamptz{Time: weekStart, Valid: true},
		CreatedAt_2: pgtype.Timestamptz{Time: weekEnd, Valid: true},
	})
	blocks, _ := h.q.ListTimeBlocksInRange(ctx, db.ListTimeBlocksInRangeParams{
		UserID:      uid,
		StartedAt:   pgtype.Timestamptz{Time: weekStart, Valid: true},
		StartedAt_2: pgtype.Timestamptz{Time: weekEnd, Valid: true},
	})

	// Build time per task map
	timePerTask := map[uuid.UUID]int{}
	totalTime := 0
	for _, b := range blocks {
		if b.TaskID.Valid && b.DurationSec.Valid {
			timePerTask[b.TaskID.Bytes] += int(b.DurationSec.Int32)
			totalTime += int(b.DurationSec.Int32)
		} else if b.DurationSec.Valid {
			totalTime += int(b.DurationSec.Int32)
		}
	}

	// Fetch projects for name lookup
	projects, _ := h.q.ListProjects(ctx, db.ListProjectsParams{UserID: uid})
	projectNames := map[uuid.UUID]string{}
	for _, p := range projects {
		projectNames[p.ID] = p.Name
	}

	// Build task summaries
	taskSummaries := make([]TaskSummary, 0, len(tasks))
	doneCount := 0
	for _, t := range tasks {
		if string(t.Status) == "done" {
			doneCount++
		}
		projName := ""
		if t.ProjectID.Valid {
			projName = projectNames[t.ProjectID.Bytes]
		}
		taskSummaries = append(taskSummaries, TaskSummary{
			Title:       t.Title,
			Status:      string(t.Status),
			ProjectName: projName,
			TimeSec:     timePerTask[t.ID],
		})
	}

	stats := ReportStats{
		TasksCreated:      len(tasks),
		TasksDone:         doneCount,
		TotalTimeSec:      totalTime,
		CapturesCreated:   len(captures),
		LogEntriesWritten: len(entries),
	}

	summary := h.generateSummary(ctx, weekStart, weekEnd, taskSummaries, entries, captures, stats)

	data := ReportData{Summary: summary, Stats: stats, Tasks: taskSummaries}
	dataJSON, err := json.Marshal(data)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	pgWeekStart := pgtype.Date{Time: weekStart, Valid: true}
	report, err := h.q.UpsertWeeklyReport(ctx, db.UpsertWeeklyReportParams{
		UserID:    uid,
		WeekStart: pgWeekStart,
		Data:      dataJSON,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to save report")
	}

	share, _ := h.q.GetPublicShareByReportID(ctx, report.ID)
	body := toReportBody(report, data, share)
	return &GenerateOutput{Body: body}, nil
}

// --- list ---

type ListOutput struct {
	Body []ReportBody
}

func (h *handler) list(ctx context.Context, _ *struct{}) (*ListOutput, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	reports, err := h.q.ListWeeklyReports(ctx, uid)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	result := make([]ReportBody, 0, len(reports))
	for _, r := range reports {
		var data ReportData
		_ = json.Unmarshal(r.Data, &data)
		share, _ := h.q.GetPublicShareByReportID(ctx, r.ID)
		result = append(result, toReportBody(r, data, share))
	}
	return &ListOutput{Body: result}, nil
}

// --- get ---

type GetInput struct {
	ID string `path:"id"`
}

type GetOutput struct {
	Body ReportBody
}

func (h *handler) get(ctx context.Context, input *GetInput) (*GetOutput, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	rid, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	report, err := h.q.GetWeeklyReport(ctx, db.GetWeeklyReportParams{ID: rid, UserID: uid})
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	var data ReportData
	_ = json.Unmarshal(report.Data, &data)
	share, _ := h.q.GetPublicShareByReportID(ctx, report.ID)
	return &GetOutput{Body: toReportBody(report, data, share)}, nil
}

// --- share ---

type ShareInput struct {
	ID string `path:"id"`
}

type ShareOutput struct {
	Body struct {
		Slug string `json:"slug"`
	}
}

func (h *handler) share(ctx context.Context, input *ShareInput) (*ShareOutput, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	rid, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	// Confirm report belongs to user
	if _, err := h.q.GetWeeklyReport(ctx, db.GetWeeklyReportParams{ID: rid, UserID: uid}); err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	// Return existing share if present
	if existing, err := h.q.GetPublicShareByReportID(ctx, rid); err == nil {
		out := &ShareOutput{}
		out.Body.Slug = existing.Slug
		return out, nil
	}

	slug := randomSlug()
	ps, err := h.q.CreatePublicShare(ctx, db.CreatePublicShareParams{ReportID: rid, Slug: slug})
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to create share")
	}
	out := &ShareOutput{}
	out.Body.Slug = ps.Slug
	return out, nil
}

// --- unshare ---

type UnshareInput struct {
	ID string `path:"id"`
}

func (h *handler) unshare(ctx context.Context, input *UnshareInput) (*struct{}, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	rid, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	if _, err := h.q.GetWeeklyReport(ctx, db.GetWeeklyReportParams{ID: rid, UserID: uid}); err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	_ = h.q.DeletePublicShareByReportID(ctx, rid)
	return nil, nil
}

// --- getShared (public) ---

type GetSharedInput struct {
	Slug string `path:"slug"`
}

type GetSharedOutput struct {
	Body ReportBody
}

func (h *handler) getShared(ctx context.Context, input *GetSharedInput) (*GetSharedOutput, error) {
	report, err := h.q.GetWeeklyReportBySlug(ctx, input.Slug)
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}

	var data ReportData
	_ = json.Unmarshal(report.Data, &data)

	share, _ := h.q.GetPublicShareBySlug(ctx, input.Slug)
	return &GetSharedOutput{Body: toReportBody(report, data, share)}, nil
}

// --- helpers ---

func currentWeekBounds() (start, end time.Time) {
	now := time.Now().UTC()
	weekday := int(now.Weekday())
	if weekday == 0 {
		weekday = 7
	}
	start = time.Date(now.Year(), now.Month(), now.Day()-weekday+1, 0, 0, 0, 0, time.UTC)
	end = start.AddDate(0, 0, 7)
	return
}

func randomSlug() string {
	return fmt.Sprintf("%x", uuid.New().NodeID())[:8]
}

func toReportBody(r db.WeeklyReport, data ReportData, share db.PublicShare) ReportBody {
	body := ReportBody{
		ID:        r.ID.String(),
		WeekStart: r.WeekStart.Time.Format("2006-01-02"),
		Data:      data,
		CreatedAt: r.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if share.ID != (uuid.UUID{}) {
		s := share.Slug
		body.ShareSlug = &s
	}
	return body
}

// --- Gemini summary ---

type geminiContent struct {
	Parts []geminiPart `json:"parts"`
}

type geminiPart struct {
	Text string `json:"text"`
}

type geminiRequest struct {
	SystemInstruction geminiContent   `json:"system_instruction"`
	Contents          []geminiContent `json:"contents"`
}

type geminiResponse struct {
	Candidates []struct {
		Content struct {
			Parts []geminiPart `json:"parts"`
		} `json:"content"`
	} `json:"candidates"`
}

func (h *handler) generateSummary(
	ctx context.Context,
	weekStart, weekEnd time.Time,
	tasks []TaskSummary,
	entries []db.LogEntry,
	captures []db.Capture,
	stats ReportStats,
) string {
	if h.geminiKey == "" {
		return ""
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("Week: %s to %s\n\n", weekStart.Format("Jan 2"), weekEnd.AddDate(0, 0, -1).Format("Jan 2, 2006")))
	sb.WriteString(fmt.Sprintf("Total time tracked: %dh %dm\n", stats.TotalTimeSec/3600, (stats.TotalTimeSec%3600)/60))
	sb.WriteString(fmt.Sprintf("Captures created: %d\n", stats.CapturesCreated))
	sb.WriteString(fmt.Sprintf("Log entries written: %d\n\n", stats.LogEntriesWritten))

	if len(tasks) > 0 {
		sb.WriteString("Tasks:\n")
		for _, t := range tasks {
			proj := ""
			if t.ProjectName != "" {
				proj = " [" + t.ProjectName + "]"
			}
			sb.WriteString(fmt.Sprintf("- %s%s (status: %s, time: %dmin)\n", t.Title, proj, t.Status, t.TimeSec/60))
		}
		sb.WriteString("\n")
	}

	if len(entries) > 0 {
		sb.WriteString("Log entries:\n")
		for i, e := range entries {
			if i >= 10 {
				break
			}
			body := e.Body
			if len(body) > 150 {
				body = body[:150] + "..."
			}
			sb.WriteString("- " + body + "\n")
		}
		sb.WriteString("\n")
	}

	if len(captures) > 0 {
		sb.WriteString("Captures:\n")
		for i, c := range captures {
			if i >= 10 {
				break
			}
			if c.RawText.Valid && c.RawText.String != "" {
				text := c.RawText.String
				if len(text) > 100 {
					text = text[:100] + "..."
				}
				sb.WriteString("- " + text + "\n")
			}
		}
	}

	systemPrompt := "You are a personal productivity assistant. Write a concise weekly progress summary in 2-3 short paragraphs based on the data provided. Be specific about accomplishments, highlight key themes, and be encouraging. Match the language used in the user's notes."

	reqBody, err := json.Marshal(geminiRequest{
		SystemInstruction: geminiContent{Parts: []geminiPart{{Text: systemPrompt}}},
		Contents:          []geminiContent{{Parts: []geminiPart{{Text: sb.String()}}}},
	})
	if err != nil {
		return ""
	}

	url := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=%s", h.geminiKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return ""
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		return ""
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var gemResp geminiResponse
	if err := json.Unmarshal(body, &gemResp); err != nil || len(gemResp.Candidates) == 0 || len(gemResp.Candidates[0].Content.Parts) == 0 {
		return ""
	}
	return gemResp.Candidates[0].Content.Parts[0].Text
}
