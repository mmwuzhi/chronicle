package logentry

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type handler struct {
	q *db.Queries
}

func Register(api huma.API, pool *pgxpool.Pool, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool)}

	op := func(id, method, path, summary string) huma.Operation {
		return huma.Operation{
			OperationID: id,
			Method:      method,
			Path:        path,
			Summary:     summary,
			Tags:        []string{"log-entries"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-log-entries", http.MethodGet, "/log-entries", "List log entries"), h.list)
	huma.Register(api, op("create-log-entry", http.MethodPost, "/log-entries", "Create a log entry"), h.create)
	huma.Register(api, op("update-log-entry", http.MethodPatch, "/log-entries/{id}", "Update a log entry"), h.update)
	huma.Register(api, op("delete-log-entry", http.MethodDelete, "/log-entries/{id}", "Delete a log entry"), h.delete)
}

// --- shared types ---

type LogEntryBody struct {
	ID        string  `json:"id"`
	TaskID    *string `json:"taskId"`
	Body      string  `json:"body"`
	CreatedAt string  `json:"createdAt"`
}

func toBody(e db.LogEntry) LogEntryBody {
	b := LogEntryBody{
		ID:        e.ID.String(),
		Body:      e.Body,
		CreatedAt: e.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if e.TaskID.Valid {
		tid := uuid.UUID(e.TaskID.Bytes).String()
		b.TaskID = &tid
	}
	return b
}

// --- list ---

type ListInput struct {
	TaskID string `query:"taskId" doc:"Filter by task (UUID)"`
}

type ListOutput struct {
	Body []LogEntryBody
}

func (h *handler) list(ctx context.Context, input *ListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	var taskID *string
	if input.TaskID != "" {
		taskID = &input.TaskID
	}
	rows, err := h.q.ListLogEntries(ctx, db.ListLogEntriesParams{
		UserID: uid,
		TaskID: nullUUID(taskID),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]LogEntryBody, len(rows))}
	for i, e := range rows {
		out.Body[i] = toBody(e)
	}
	return out, nil
}

// --- create ---

type CreateInput struct {
	Body struct {
		TaskID *string `json:"taskId,omitempty" format:"uuid"`
		Body   string  `json:"body" minLength:"1"`
	}
}

type CreateOutput struct {
	Body LogEntryBody
}

func (h *handler) create(ctx context.Context, input *CreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	e, err := h.q.CreateLogEntry(ctx, db.CreateLogEntryParams{
		UserID: uid,
		TaskID: nullUUID(input.Body.TaskID),
		Body:   input.Body.Body,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CreateOutput{Body: toBody(e)}, nil
}

// --- update ---

type UpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Body string `json:"body" minLength:"1"`
	}
}

type UpdateOutput struct {
	Body LogEntryBody
}

func (h *handler) update(ctx context.Context, input *UpdateInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	e, err := h.q.UpdateLogEntry(ctx, db.UpdateLogEntryParams{
		Body:   input.Body.Body,
		ID:     id,
		UserID: uid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(e)}, nil
}

// --- delete ---

type DeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) delete(ctx context.Context, input *DeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err := h.q.DeleteLogEntry(ctx, db.DeleteLogEntryParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

// --- helpers ---

func userID(ctx context.Context) (uuid.UUID, error) {
	id := middleware.GetUserID(ctx)
	if id == "" {
		return uuid.UUID{}, huma.Error401Unauthorized("unauthorized")
	}
	uid, err := uuid.Parse(id)
	if err != nil {
		return uuid.UUID{}, huma.Error401Unauthorized("unauthorized")
	}
	return uid, nil
}

func nullUUID(s *string) pgtype.UUID {
	if s == nil {
		return pgtype.UUID{}
	}
	id, err := uuid.Parse(*s)
	if err != nil {
		return pgtype.UUID{}
	}
	return pgtype.UUID{Bytes: id, Valid: true}
}
