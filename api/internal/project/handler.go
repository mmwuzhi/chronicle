package project

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
			Tags:        []string{"projects"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-projects", http.MethodGet, "/projects", "List projects"), h.list)
	huma.Register(api, op("create-project", http.MethodPost, "/projects", "Create a project"), h.create)
	huma.Register(api, op("update-project", http.MethodPatch, "/projects/{id}", "Update a project"), h.update)
	huma.Register(api, op("delete-project", http.MethodDelete, "/projects/{id}", "Delete a project"), h.delete)
}

// --- shared types ---

type ProjectBody struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color"`
	Archived  bool   `json:"archived"`
	CreatedAt string `json:"createdAt"`
}

func toBody(p db.Project) ProjectBody {
	return ProjectBody{
		ID:        p.ID.String(),
		Name:      p.Name,
		Color:     p.Color,
		Archived:  p.Archived,
		CreatedAt: p.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
}

// --- list ---

type ListInput struct {
	Archived bool `query:"archived" default:"false" doc:"Include archived projects"`
}

type ListOutput struct {
	Body []ProjectBody
}

func (h *handler) list(ctx context.Context, input *ListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.ListProjects(ctx, db.ListProjectsParams{
		UserID:   uid,
		Archived: input.Archived,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]ProjectBody, len(rows))}
	for i, p := range rows {
		out.Body[i] = toBody(p)
	}
	return out, nil
}

// --- create ---

type CreateInput struct {
	Body struct {
		Name  string `json:"name" minLength:"1" maxLength:"100"`
		Color string `json:"color" default:"#6366f1"`
	}
}

type CreateOutput struct {
	Body ProjectBody
}

func (h *handler) create(ctx context.Context, input *CreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	p, err := h.q.CreateProject(ctx, db.CreateProjectParams{
		UserID: uid,
		Name:   input.Body.Name,
		Color:  input.Body.Color,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CreateOutput{Body: toBody(p)}, nil
}

// --- update ---

type UpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Name     *string `json:"name,omitempty" minLength:"1" maxLength:"100"`
		Color    *string `json:"color,omitempty"`
		Archived *bool   `json:"archived,omitempty"`
	}
}

type UpdateOutput struct {
	Body ProjectBody
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
	p, err := h.q.UpdateProject(ctx, db.UpdateProjectParams{
		ID:       id,
		UserID:   uid,
		Name:     nullText(input.Body.Name),
		Color:    nullText(input.Body.Color),
		Archived: nullBool(input.Body.Archived),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("project not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(p)}, nil
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
	if _, err := h.q.DeleteProject(ctx, db.DeleteProjectParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("project not found")
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

func nullBool(b *bool) pgtype.Bool {
	if b == nil {
		return pgtype.Bool{}
	}
	return pgtype.Bool{Bool: *b, Valid: true}
}
