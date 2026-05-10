package task

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
			Tags:        []string{"tasks"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-tasks", http.MethodGet, "/tasks", "List tasks"), h.list)
	huma.Register(api, op("get-task", http.MethodGet, "/tasks/{id}", "Get a task"), h.get)
	huma.Register(api, op("create-task", http.MethodPost, "/tasks", "Create a task"), h.create)
	huma.Register(api, op("update-task", http.MethodPatch, "/tasks/{id}", "Update a task"), h.update)
	huma.Register(api, op("delete-task", http.MethodDelete, "/tasks/{id}", "Delete a task"), h.delete)
}

// --- shared types ---

type TaskBody struct {
	ID        string  `json:"id"`
	ProjectID *string `json:"projectId"`
	Title     string  `json:"title"`
	Type      string  `json:"type"`
	Status    string  `json:"status"`
	DueAt     *string `json:"dueAt"`
	CreatedAt string  `json:"createdAt"`
}

func toBody(t db.Task) TaskBody {
	b := TaskBody{
		ID:        t.ID.String(),
		Title:     t.Title,
		Type:      string(t.Type),
		Status:    string(t.Status),
		CreatedAt: t.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if t.ProjectID.Valid {
		pid := uuid.UUID(t.ProjectID.Bytes).String()
		b.ProjectID = &pid
	}
	if t.DueAt.Valid {
		s := t.DueAt.Time.UTC().Format(time.RFC3339)
		b.DueAt = &s
	}
	return b
}

// --- list ---

type ListInput struct {
	ProjectID string `query:"projectId" doc:"Filter by project (UUID)"`
	Status    string `query:"status" doc:"Filter by status: todo, in_progress, done, archived"`
	Type      string `query:"type" doc:"Filter by type: task, idea, routine, log"`
}

type ListOutput struct {
	Body []TaskBody
}

func (h *handler) list(ctx context.Context, input *ListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	var projectID *string
	if input.ProjectID != "" {
		projectID = &input.ProjectID
	}
	rows, err := h.q.ListTasks(ctx, db.ListTasksParams{
		UserID:    uid,
		ProjectID: nullUUID(projectID),
		Status:    nullText(strPtr(input.Status)),
		Type:      nullText(strPtr(input.Type)),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]TaskBody, len(rows))}
	for i, t := range rows {
		out.Body[i] = toBody(t)
	}
	return out, nil
}

// --- get ---

type GetInput struct {
	ID string `path:"id" format:"uuid"`
}

type GetOutput struct {
	Body TaskBody
}

func (h *handler) get(ctx context.Context, input *GetInput) (*GetOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	t, err := h.q.GetTask(ctx, db.GetTaskParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("task not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &GetOutput{Body: toBody(t)}, nil
}

// --- create ---

type CreateInput struct {
	Body struct {
		Title     string     `json:"title" minLength:"1" maxLength:"255"`
		Type      string     `json:"type" enum:"task,idea,routine,log"`
		ProjectID *string    `json:"projectId,omitempty" format:"uuid"`
		DueAt     *time.Time `json:"dueAt,omitempty"`
	}
}

type CreateOutput struct {
	Body TaskBody
}

func (h *handler) create(ctx context.Context, input *CreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	t, err := h.q.CreateTask(ctx, db.CreateTaskParams{
		UserID:    uid,
		ProjectID: nullUUID(input.Body.ProjectID),
		Title:     input.Body.Title,
		Type:      db.TaskType(input.Body.Type),
		DueAt:     nullTime(input.Body.DueAt),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CreateOutput{Body: toBody(t)}, nil
}

// --- update ---

type UpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Title     *string    `json:"title,omitempty" minLength:"1" maxLength:"255"`
		Status    *string    `json:"status,omitempty" enum:"todo,in_progress,done,archived"`
		Type      *string    `json:"type,omitempty" enum:"task,idea,routine,log"`
		ProjectID *string    `json:"projectId,omitempty" format:"uuid"`
		DueAt     *time.Time `json:"dueAt,omitempty"`
	}
}

type UpdateOutput struct {
	Body TaskBody
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
	t, err := h.q.UpdateTask(ctx, db.UpdateTaskParams{
		ID:        id,
		UserID:    uid,
		Title:     nullText(input.Body.Title),
		Status:    nullText(input.Body.Status),
		Type:      nullText(input.Body.Type),
		ProjectID: nullUUID(input.Body.ProjectID),
		DueAt:     nullTime(input.Body.DueAt),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("task not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(t)}, nil
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
	if _, err := h.q.DeleteTask(ctx, db.DeleteTaskParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("task not found")
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

func nullText(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
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

func nullTime(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
