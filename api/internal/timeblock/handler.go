package timeblock

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
			Tags:        []string{"time-blocks"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-time-blocks", http.MethodGet, "/time-blocks", "List time blocks"), h.list)
	huma.Register(api, op("create-time-block", http.MethodPost, "/time-blocks", "Create a time block"), h.create)
	huma.Register(api, op("update-time-block", http.MethodPatch, "/time-blocks/{id}", "Update a time block"), h.update)
	huma.Register(api, op("delete-time-block", http.MethodDelete, "/time-blocks/{id}", "Delete a time block"), h.delete)
}

// --- shared types ---

type TimeBlockBody struct {
	ID          string  `json:"id"`
	TaskID      *string `json:"taskId"`
	StartedAt   string  `json:"startedAt"`
	EndedAt     *string `json:"endedAt"`
	DurationSec *int32  `json:"durationSec"`
	InputMode   string  `json:"inputMode"`
	CreatedAt   string  `json:"createdAt"`
}

func toBody(t db.TimeBlock) TimeBlockBody {
	b := TimeBlockBody{
		ID:        t.ID.String(),
		StartedAt: t.StartedAt.Time.UTC().Format(time.RFC3339),
		CreatedAt: t.CreatedAt.Time.UTC().Format(time.RFC3339),
		InputMode: t.InputMode,
	}
	if t.TaskID.Valid {
		tid := uuid.UUID(t.TaskID.Bytes).String()
		b.TaskID = &tid
	}
	if t.EndedAt.Valid {
		s := t.EndedAt.Time.UTC().Format(time.RFC3339)
		b.EndedAt = &s
	}
	if t.DurationSec.Valid {
		v := t.DurationSec.Int32
		b.DurationSec = &v
	}
	return b
}

// --- list ---

type TimeBlockListInput struct {
	TaskID string `query:"taskId" doc:"Filter by task (UUID)"`
}

type ListOutput struct {
	Body []TimeBlockBody
}

func (h *handler) list(ctx context.Context, input *TimeBlockListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	var taskID *string
	if input.TaskID != "" {
		taskID = &input.TaskID
	}
	rows, err := h.q.ListTimeBlocks(ctx, db.ListTimeBlocksParams{
		UserID: uid,
		TaskID: nullUUID(taskID),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]TimeBlockBody, len(rows))}
	for i, t := range rows {
		out.Body[i] = toBody(t)
	}
	return out, nil
}

// --- create ---

type TimeBlockCreateInput struct {
	Body struct {
		TaskID      *string    `json:"taskId,omitempty" format:"uuid"`
		StartedAt   *time.Time `json:"startedAt,omitempty"`
		EndedAt     *time.Time `json:"endedAt,omitempty"`
		DurationSec *int32     `json:"durationSec,omitempty"`
		InputMode   string     `json:"inputMode,omitempty" enum:"duration,range"`
	}
}

type CreateOutput struct {
	Body TimeBlockBody
}

func (h *handler) create(ctx context.Context, input *TimeBlockCreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	startedAt := time.Now()
	if input.Body.StartedAt != nil {
		startedAt = *input.Body.StartedAt
	}
	inputMode := input.Body.InputMode
	if inputMode == "" {
		inputMode = "duration"
	}
	t, err := h.q.CreateTimeBlock(ctx, db.CreateTimeBlockParams{
		UserID:      uid,
		TaskID:      nullUUID(input.Body.TaskID),
		StartedAt:   pgtype.Timestamptz{Time: startedAt, Valid: true},
		EndedAt:     nullTime(input.Body.EndedAt),
		DurationSec: nullInt4(input.Body.DurationSec),
		InputMode:   inputMode,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CreateOutput{Body: toBody(t)}, nil
}

// --- update ---

type TimeBlockUpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		TaskID      *string    `json:"taskId,omitempty" format:"uuid"`
		StartedAt   *time.Time `json:"startedAt,omitempty"`
		EndedAt     *time.Time `json:"endedAt,omitempty"`
		DurationSec *int32     `json:"durationSec,omitempty"`
		InputMode   *string    `json:"inputMode,omitempty" enum:"duration,range"`
	}
}

type UpdateOutput struct {
	Body TimeBlockBody
}

func (h *handler) update(ctx context.Context, input *TimeBlockUpdateInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	t, err := h.q.UpdateTimeBlock(ctx, db.UpdateTimeBlockParams{
		ID:          id,
		UserID:      uid,
		TaskID:      nullUUID(input.Body.TaskID),
		StartedAt:   nullTime(input.Body.StartedAt),
		EndedAt:     nullTime(input.Body.EndedAt),
		DurationSec: nullInt4(input.Body.DurationSec),
		InputMode:   nullText(input.Body.InputMode),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("time block not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(t)}, nil
}

// --- delete ---

type TimeBlockDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) delete(ctx context.Context, input *TimeBlockDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err := h.q.DeleteTimeBlock(ctx, db.DeleteTimeBlockParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("time block not found")
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

func nullTime(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

func nullInt4(n *int32) pgtype.Int4 {
	if n == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *n, Valid: true}
}

func nullText(value *string) pgtype.Text {
	if value == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *value, Valid: true}
}
