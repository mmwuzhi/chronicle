package search

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type handler struct {
	q *db.Queries
}

func Register(api huma.API, pool *pgxpool.Pool, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool)}
	huma.Register(api, huma.Operation{
		OperationID: "search",
		Method:      http.MethodGet,
		Path:        "/search",
		Summary:     "Search across captures, tasks, and log entries",
		Tags:        []string{"search"},
		Middlewares: huma.Middlewares{authMW},
	}, h.search)
}

// --- types ---

type SearchCaptureItem struct {
	ID           string  `json:"id"`
	RawText      *string `json:"rawText"`
	MediaUrl     *string `json:"mediaUrl"`
	MediaType    string  `json:"mediaType"`
	ClassifiedAs string  `json:"classifiedAs"`
	TaskID       *string `json:"taskId"`
	CreatedAt    string  `json:"createdAt"`
}

type SearchTaskItem struct {
	ID        string  `json:"id"`
	ProjectID *string `json:"projectId"`
	Title     string  `json:"title"`
	Type      string  `json:"type"`
	Status    string  `json:"status"`
	DueAt     *string `json:"dueAt"`
	CreatedAt string  `json:"createdAt"`
}

type SearchLogEntryItem struct {
	ID        string  `json:"id"`
	TaskID    *string `json:"taskId"`
	Body      string  `json:"body"`
	CreatedAt string  `json:"createdAt"`
}

type SearchInput struct {
	Q string `query:"q" minLength:"1" maxLength:"100"`
}

type SearchOutput struct {
	Body struct {
		Captures   []SearchCaptureItem  `json:"captures"`
		Tasks      []SearchTaskItem     `json:"tasks"`
		LogEntries []SearchLogEntryItem `json:"logEntries"`
	}
}

// --- handler ---

func (h *handler) search(ctx context.Context, input *SearchInput) (*SearchOutput, error) {
	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	var (
		captures   []db.Capture
		tasks      []db.Task
		logEntries []db.LogEntry
		wg         sync.WaitGroup
	)

	wg.Add(3)
	go func() {
		defer wg.Done()
		captures, _ = h.q.SearchCaptures(ctx, db.SearchCapturesParams{UserID: uid, Query: input.Q})
	}()
	go func() {
		defer wg.Done()
		tasks, _ = h.q.SearchTasks(ctx, db.SearchTasksParams{UserID: uid, Query: input.Q})
	}()
	go func() {
		defer wg.Done()
		logEntries, _ = h.q.SearchLogEntries(ctx, db.SearchLogEntriesParams{UserID: uid, Query: input.Q})
	}()
	wg.Wait()

	out := &SearchOutput{}
	out.Body.Captures = make([]SearchCaptureItem, 0, len(captures))
	for _, c := range captures {
		item := SearchCaptureItem{
			ID:           c.ID.String(),
			MediaType:    string(c.MediaType),
			ClassifiedAs: string(c.ClassifiedAs),
			CreatedAt:    c.CreatedAt.Time.UTC().Format(time.RFC3339),
		}
		if c.RawText.Valid {
			item.RawText = &c.RawText.String
		}
		if c.MediaUrl.Valid {
			item.MediaUrl = &c.MediaUrl.String
		}
		if c.TaskID.Valid {
			tid := uuid.UUID(c.TaskID.Bytes).String()
			item.TaskID = &tid
		}
		out.Body.Captures = append(out.Body.Captures, item)
	}

	out.Body.Tasks = make([]SearchTaskItem, 0, len(tasks))
	for _, t := range tasks {
		item := SearchTaskItem{
			ID:        t.ID.String(),
			Title:     t.Title,
			Type:      string(t.Type),
			Status:    string(t.Status),
			CreatedAt: t.CreatedAt.Time.UTC().Format(time.RFC3339),
		}
		if t.ProjectID.Valid {
			pid := uuid.UUID(t.ProjectID.Bytes).String()
			item.ProjectID = &pid
		}
		if t.DueAt.Valid {
			s := t.DueAt.Time.UTC().Format(time.RFC3339)
			item.DueAt = &s
		}
		out.Body.Tasks = append(out.Body.Tasks, item)
	}

	out.Body.LogEntries = make([]SearchLogEntryItem, 0, len(logEntries))
	for _, e := range logEntries {
		item := SearchLogEntryItem{
			ID:        e.ID.String(),
			Body:      e.Body,
			CreatedAt: e.CreatedAt.Time.UTC().Format(time.RFC3339),
		}
		if e.TaskID.Valid {
			tid := uuid.UUID(e.TaskID.Bytes).String()
			item.TaskID = &tid
		}
		out.Body.LogEntries = append(out.Body.LogEntries, item)
	}

	return out, nil
}
