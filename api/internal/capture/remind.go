package capture

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

// --- reminders (time-based recall) ---
//
// Only this browse-side surface reads remind_at. Search and recall (search.sql,
// ragsvc) never filter it, preserving time-window completeness.

type CaptureRemindInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		At   *string `json:"at,omitempty" doc:"RFC3339 time to resurface this capture; omit or null to clear the reminder"`
		Hide *bool   `json:"hide,omitempty" doc:"true (default) hides the capture from browse until due; false is notify-only (stays visible, still notifies)"`
	}
}

func (h *handler) setRemind(ctx context.Context, input *CaptureRemindInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	at, err := parseRemindAt(input.Body.At)
	if err != nil {
		return nil, err
	}
	c, err := h.q.SetCaptureRemind(ctx, db.SetCaptureRemindParams{
		ID:         id,
		UserID:     uid,
		RemindAt:   at,
		RemindHide: remindHideDefault(input.Body.Hide),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(c)}, nil
}

// remindHideDefault resolves the optional hide flag: absent → true (hide until
// due, the historical behaviour); present → the caller's choice.
func remindHideDefault(hide *bool) bool {
	if hide == nil {
		return true
	}
	return *hide
}

type RemindersDueInput struct {
	Since string `query:"since" doc:"RFC3339 lower bound (exclusive); reminders due after this and up to now. Omit for all past-due."`
}

func (h *handler) dueReminders(ctx context.Context, input *RemindersDueInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	since := time.Time{} // zero value matches all past-due reminders
	if strings.TrimSpace(input.Since) != "" {
		parsed, perr := time.Parse(time.RFC3339, input.Since)
		if perr != nil {
			return nil, huma.Error422UnprocessableEntity("since must be an RFC3339 timestamp")
		}
		since = parsed
	}
	rows, err := h.q.DueReminders(ctx, db.DueRemindersParams{
		UserID: uid,
		Since:  pgtype.Timestamptz{Time: since, Valid: true},
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]CaptureBody, len(rows))}
	for i, c := range rows {
		out.Body[i] = toBody(c)
	}
	return out, nil
}

type RemindersPendingInput struct{}

func (h *handler) pendingReminders(ctx context.Context, _ *RemindersPendingInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.PendingReminders(ctx, uid)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]CaptureBody, len(rows))}
	for i, c := range rows {
		out.Body[i] = toBody(c)
	}
	return out, nil
}

func parseRemindAt(at *string) (pgtype.Timestamptz, error) {
	if at == nil || strings.TrimSpace(*at) == "" {
		return pgtype.Timestamptz{}, nil // clear the reminder
	}
	t, err := time.Parse(time.RFC3339, *at)
	if err != nil {
		return pgtype.Timestamptz{}, huma.Error422UnprocessableEntity("at must be an RFC3339 timestamp")
	}
	return pgtype.Timestamptz{Time: t, Valid: true}, nil
}
