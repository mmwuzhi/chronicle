package logentry

import (
	"context"
	"errors"
	"net/http"
	"strings"
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
	q    *db.Queries
	pool *pgxpool.Pool
}

func Register(api huma.API, pool *pgxpool.Pool, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool), pool: pool}

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
	ID        string       `json:"id"`
	TaskID    *string      `json:"taskId"`
	Body      string       `json:"body"`
	Time      *LogTimeBody `json:"time,omitempty"`
	CreatedAt string       `json:"createdAt"`
}

type LogTimeBody struct {
	ID          string `json:"id"`
	StartedAt   string `json:"startedAt"`
	EndedAt     string `json:"endedAt"`
	DurationSec int32  `json:"durationSec"`
	InputMode   string `json:"inputMode"`
}

func toBody(e db.LogEntry, block *db.TimeBlock) LogEntryBody {
	b := LogEntryBody{
		ID:        e.ID.String(),
		Body:      e.Body,
		CreatedAt: e.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if e.TaskID.Valid {
		tid := uuid.UUID(e.TaskID.Bytes).String()
		b.TaskID = &tid
	}
	if block != nil {
		b.Time = &LogTimeBody{
			ID:          block.ID.String(),
			StartedAt:   block.StartedAt.Time.UTC().Format(time.RFC3339),
			EndedAt:     block.EndedAt.Time.UTC().Format(time.RFC3339),
			DurationSec: block.DurationSec.Int32,
			InputMode:   block.InputMode,
		}
	}
	return b
}

// --- list ---

type LogListInput struct {
	TaskID string `query:"taskId" doc:"Filter by task (UUID)"`
}

type ListOutput struct {
	Body []LogEntryBody
}

func (h *handler) list(ctx context.Context, input *LogListInput) (*ListOutput, error) {
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
		block, err := h.timeBlock(ctx, h.q, e)
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		out.Body[i] = toBody(e, block)
	}
	return out, nil
}

// --- create ---

type LogCreateInput struct {
	Body struct {
		TaskID *string       `json:"taskId,omitempty" format:"uuid"`
		Body   string        `json:"body,omitempty"`
		Time   *LogTimeInput `json:"time,omitempty"`
	}
}

type LogTimeInput struct {
	InputMode   string     `json:"inputMode" enum:"duration,range"`
	StartedAt   *time.Time `json:"startedAt,omitempty"`
	EndedAt     *time.Time `json:"endedAt,omitempty"`
	DurationSec int32      `json:"durationSec" minimum:"1"`
}

type CreateOutput struct {
	Body LogEntryBody
}

func (h *handler) create(ctx context.Context, input *LogCreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	body := strings.TrimSpace(input.Body.Body)
	if body == "" && input.Body.Time == nil {
		return nil, huma.Error422UnprocessableEntity("body or time is required")
	}
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	defer tx.Rollback(ctx)
	q := h.q.WithTx(tx)
	block, err := h.createTimeBlock(ctx, q, uid, input.Body.TaskID, input.Body.Time)
	if err != nil {
		return nil, err
	}
	e, err := q.CreateLogEntry(ctx, db.CreateLogEntryParams{
		UserID:      uid,
		TaskID:      nullUUID(input.Body.TaskID),
		Body:        body,
		TimeBlockID: timeBlockID(block),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CreateOutput{Body: toBody(e, block)}, nil
}

// --- update ---

type LogUpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Body       *string       `json:"body,omitempty"`
		Time       *LogTimeInput `json:"time,omitempty"`
		RemoveTime bool          `json:"removeTime,omitempty"`
	}
}

type UpdateOutput struct {
	Body LogEntryBody
}

func (h *handler) update(ctx context.Context, input *LogUpdateInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	defer tx.Rollback(ctx)
	q := h.q.WithTx(tx)
	existing, err := q.GetLogEntry(ctx, db.GetLogEntryParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	body := existing.Body
	if input.Body.Body != nil {
		body = strings.TrimSpace(*input.Body.Body)
	}
	block, err := h.timeBlock(ctx, q, existing)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	clearTime := false
	if input.Body.RemoveTime && block != nil {
		if _, err := q.DeleteTimeBlock(ctx, db.DeleteTimeBlockParams{ID: block.ID, UserID: uid}); err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		block = nil
		clearTime = true
	}
	if input.Body.Time != nil {
		if block == nil {
			block, err = h.createTimeBlock(ctx, q, uid, taskIDString(existing.TaskID), input.Body.Time)
		} else {
			block, err = h.updateTimeBlock(ctx, q, uid, *block, input.Body.Time)
		}
		if err != nil {
			return nil, err
		}
	}
	if body == "" && block == nil {
		return nil, huma.Error422UnprocessableEntity("body or time is required")
	}
	e, err := q.UpdateLogEntry(ctx, db.UpdateLogEntryParams{
		Body:           body,
		ID:             id,
		UserID:         uid,
		ClearTimeBlock: clearTime,
		TimeBlockID:    timeBlockID(block),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(e, block)}, nil
}

// --- delete ---

type LogDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) delete(ctx context.Context, input *LogDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	defer tx.Rollback(ctx)
	q := h.q.WithTx(tx)
	entry, err := q.GetLogEntry(ctx, db.GetLogEntryParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if entry.TimeBlockID.Valid {
		if _, err := q.DeleteTimeBlock(ctx, db.DeleteTimeBlockParams{ID: entry.TimeBlockID.Bytes, UserID: uid}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error500InternalServerError("internal error")
		}
	}
	if _, err := q.DeleteLogEntry(ctx, db.DeleteLogEntryParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("log entry not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

func (h *handler) createTimeBlock(
	ctx context.Context,
	q *db.Queries,
	uid uuid.UUID,
	taskID *string,
	input *LogTimeInput,
) (*db.TimeBlock, error) {
	if input == nil {
		return nil, nil
	}
	startedAt, endedAt, err := validateLogTime(input)
	if err != nil {
		return nil, err
	}
	block, err := q.CreateTimeBlock(ctx, db.CreateTimeBlockParams{
		UserID:      uid,
		TaskID:      nullUUID(taskID),
		StartedAt:   pgtype.Timestamptz{Time: startedAt, Valid: true},
		EndedAt:     pgtype.Timestamptz{Time: endedAt, Valid: true},
		DurationSec: pgtype.Int4{Int32: input.DurationSec, Valid: true},
		InputMode:   input.InputMode,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &block, nil
}

func (h *handler) updateTimeBlock(
	ctx context.Context,
	q *db.Queries,
	uid uuid.UUID,
	block db.TimeBlock,
	input *LogTimeInput,
) (*db.TimeBlock, error) {
	startedAt, endedAt, err := validateLogTime(input)
	if err != nil {
		return nil, err
	}
	updated, err := q.UpdateTimeBlock(ctx, db.UpdateTimeBlockParams{
		StartedAt:   pgtype.Timestamptz{Time: startedAt, Valid: true},
		EndedAt:     pgtype.Timestamptz{Time: endedAt, Valid: true},
		DurationSec: pgtype.Int4{Int32: input.DurationSec, Valid: true},
		InputMode:   pgtype.Text{String: input.InputMode, Valid: true},
		ID:          block.ID,
		UserID:      uid,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &updated, nil
}

func validateLogTime(input *LogTimeInput) (time.Time, time.Time, error) {
	if input.DurationSec <= 0 {
		return time.Time{}, time.Time{}, huma.Error422UnprocessableEntity("durationSec must be positive")
	}
	switch input.InputMode {
	case "duration":
		endedAt := time.Now().UTC()
		return endedAt.Add(-time.Duration(input.DurationSec) * time.Second), endedAt, nil
	case "range":
		if input.StartedAt == nil || input.EndedAt == nil || !input.EndedAt.After(*input.StartedAt) {
			return time.Time{}, time.Time{}, huma.Error422UnprocessableEntity("range requires an end after start")
		}
		if time.Duration(input.DurationSec)*time.Second > input.EndedAt.Sub(*input.StartedAt) {
			return time.Time{}, time.Time{}, huma.Error422UnprocessableEntity("duration cannot exceed the selected range")
		}
		return input.StartedAt.UTC(), input.EndedAt.UTC(), nil
	default:
		return time.Time{}, time.Time{}, huma.Error422UnprocessableEntity("inputMode must be duration or range")
	}
}

func (h *handler) timeBlock(ctx context.Context, q *db.Queries, entry db.LogEntry) (*db.TimeBlock, error) {
	if !entry.TimeBlockID.Valid {
		return nil, nil
	}
	block, err := q.GetTimeBlock(ctx, db.GetTimeBlockParams{ID: entry.TimeBlockID.Bytes, UserID: entry.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &block, nil
}

func timeBlockID(block *db.TimeBlock) pgtype.UUID {
	if block == nil {
		return pgtype.UUID{}
	}
	return pgtype.UUID{Bytes: block.ID, Valid: true}
}

func taskIDString(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	value := uuid.UUID(id.Bytes).String()
	return &value
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
