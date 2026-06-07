package search

import (
	"context"
	"net/http"
	"strings"
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
	Transcript   *string `json:"transcript"`
	MediaUrl     *string `json:"mediaUrl"`
	MediaType    string  `json:"mediaType"`
	ClassifiedAs string  `json:"classifiedAs"`
	TaskID       *string `json:"taskId"`
	Source       string  `json:"source"`
	MatchedField string  `json:"matchedField"`
	Preview      string  `json:"preview"`
	CreatedAt    string  `json:"createdAt"`
}

type SearchTaskItem struct {
	ID        string  `json:"id"`
	ProjectID *string `json:"projectId"`
	Title     string  `json:"title"`
	Type      string  `json:"type"`
	Status    string  `json:"status"`
	DueAt     *string `json:"dueAt"`
	Preview   string  `json:"preview"`
	CreatedAt string  `json:"createdAt"`
}

type SearchLogEntryItem struct {
	ID        string  `json:"id"`
	TaskID    *string `json:"taskId"`
	Body      string  `json:"body"`
	Preview   string  `json:"preview"`
	CreatedAt string  `json:"createdAt"`
}

type SearchInput struct {
	Q string `query:"q" minLength:"1" maxLength:"100" required:"true"`
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
	query := strings.TrimSpace(input.Q)
	if query == "" {
		return nil, huma.Error422UnprocessableEntity("q must not be empty")
	}

	var (
		captures      []db.SearchCapturesRow
		tasks         []db.SearchTasksRow
		logEntries    []db.SearchLogEntriesRow
		capturesErr   error
		tasksErr      error
		logEntriesErr error
		wg            sync.WaitGroup
	)

	wg.Add(3)
	go func() {
		defer wg.Done()
		captures, capturesErr = h.q.SearchCaptures(ctx, db.SearchCapturesParams{UserID: uid, Query: query})
	}()
	go func() {
		defer wg.Done()
		tasks, tasksErr = h.q.SearchTasks(ctx, db.SearchTasksParams{UserID: uid, Query: query})
	}()
	go func() {
		defer wg.Done()
		logEntries, logEntriesErr = h.q.SearchLogEntries(ctx, db.SearchLogEntriesParams{UserID: uid, Query: query})
	}()
	wg.Wait()
	if capturesErr != nil || tasksErr != nil || logEntriesErr != nil {
		return nil, huma.Error500InternalServerError("search failed")
	}

	out := &SearchOutput{}
	out.Body.Captures = make([]SearchCaptureItem, 0, len(captures))
	for _, c := range captures {
		matchedText := c.RawText.String
		if c.MatchedField == "transcript" {
			matchedText = c.Transcript.String
		}
		item := SearchCaptureItem{
			ID:           c.ID.String(),
			MediaType:    string(c.MediaType),
			ClassifiedAs: string(c.ClassifiedAs),
			Source:       c.Source,
			MatchedField: c.MatchedField,
			Preview:      makePreview(matchedText, query),
			CreatedAt:    c.CreatedAt.Time.UTC().Format(time.RFC3339),
		}
		if c.RawText.Valid {
			item.RawText = &c.RawText.String
		}
		if c.Transcript.Valid {
			item.Transcript = &c.Transcript.String
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
			Preview:   makePreview(t.Title, query),
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
			Preview:   makePreview(e.Body, query),
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

func makePreview(text, query string) string {
	const maxRunes = 220
	runes := []rune(strings.TrimSpace(text))
	if len(runes) <= maxRunes {
		return string(runes)
	}

	lowerText := []rune(strings.ToLower(string(runes)))
	lowerQuery := []rune(strings.ToLower(strings.TrimSpace(query)))
	match := runeSliceIndex(lowerText, lowerQuery)
	start := 0
	if match > 60 {
		start = match - 60
	}
	end := min(start+maxRunes, len(runes))
	if end == len(runes) {
		start = max(0, end-maxRunes)
	}

	preview := string(runes[start:end])
	if start > 0 {
		preview = "..." + preview
	}
	if end < len(runes) {
		preview += "..."
	}
	return preview
}

func runeSliceIndex(text, query []rune) int {
	if len(query) == 0 || len(query) > len(text) {
		return 0
	}
	for i := 0; i <= len(text)-len(query); i++ {
		matched := true
		for j := range query {
			if text[i+j] != query[j] {
				matched = false
				break
			}
		}
		if matched {
			return i
		}
	}
	return 0
}
