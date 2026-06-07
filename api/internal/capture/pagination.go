package capture

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const (
	defaultPageSize = 30
	maxPageSize     = 100
	maxContextSize  = 50
)

type captureCursor struct {
	CreatedAt time.Time `json:"createdAt"`
	ID        uuid.UUID `json:"id"`
}

type CapturePageInput struct {
	ClassifiedAs string `query:"classifiedAs" doc:"Filter by classification: task, idea, routine, log, unclassified"`
	Cursor       string `query:"cursor"`
	Limit        int    `query:"limit" minimum:"1" maximum:"100" default:"30"`
}

type CapturePageBody struct {
	Items      []CaptureBody `json:"items"`
	NextCursor *string       `json:"nextCursor"`
}

type CapturePageOutput struct {
	Body CapturePageBody
}

func (h *handler) listPage(ctx context.Context, input *CapturePageInput) (*CapturePageOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	limit := input.Limit
	if limit == 0 {
		limit = defaultPageSize
	}
	if limit < 1 || limit > maxPageSize {
		return nil, huma.Error422UnprocessableEntity("limit must be between 1 and 100")
	}

	var cursorCreatedAt pgtype.Timestamptz
	var cursorID pgtype.UUID
	if input.Cursor != "" {
		cursor, err := decodeCaptureCursor(input.Cursor)
		if err != nil {
			return nil, huma.Error422UnprocessableEntity("invalid cursor")
		}
		cursorCreatedAt = pgtype.Timestamptz{Time: cursor.CreatedAt, Valid: true}
		cursorID = pgtype.UUID{Bytes: cursor.ID, Valid: true}
	}

	rows, err := h.q.ListCapturePage(ctx, db.ListCapturePageParams{
		UserID:          uid,
		ClassifiedAs:    nullText(strPtr(input.ClassifiedAs)),
		CursorCreatedAt: cursorCreatedAt,
		CursorID:        cursorID,
		PageSize:        int32(limit + 1),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	hasMore := len(rows) > limit
	if hasMore {
		rows = rows[:limit]
	}
	body := CapturePageBody{
		Items: make([]CaptureBody, len(rows)),
	}
	for i, capture := range rows {
		body.Items[i] = toBody(capture)
	}
	if hasMore && len(rows) > 0 {
		next, err := encodeCaptureCursor(rows[len(rows)-1])
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		body.NextCursor = &next
	}
	return &CapturePageOutput{Body: body}, nil
}

type CaptureContextInput struct {
	AnchorID string `query:"anchorId" format:"uuid" required:"true"`
	Before   int    `query:"before" minimum:"0" maximum:"50" default:"20"`
	After    int    `query:"after" minimum:"0" maximum:"50" default:"20"`
}

type CaptureContextBody struct {
	Items       []CaptureBody `json:"items"`
	AnchorIndex int           `json:"anchorIndex"`
	HasEarlier  bool          `json:"hasEarlier"`
	HasLater    bool          `json:"hasLater"`
}

type CaptureContextOutput struct {
	Body CaptureContextBody
}

func (h *handler) context(ctx context.Context, input *CaptureContextInput) (*CaptureContextOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	anchorID, err := uuid.Parse(input.AnchorID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid anchorId")
	}
	beforeSize, afterSize, err := contextSizes(input.Before, input.After)
	if err != nil {
		return nil, err
	}
	anchor, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: anchorID, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}

	before, err := h.q.ListCaptureContextBefore(ctx, db.ListCaptureContextBeforeParams{
		UserID:          uid,
		AnchorCreatedAt: anchor.CreatedAt,
		AnchorID:        anchor.ID,
		WindowSize:      int32(beforeSize + 1),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	after, err := h.q.ListCaptureContextAfter(ctx, db.ListCaptureContextAfterParams{
		UserID:          uid,
		AnchorCreatedAt: anchor.CreatedAt,
		AnchorID:        anchor.ID,
		WindowSize:      int32(afterSize + 1),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	hasEarlier := len(before) > beforeSize
	if hasEarlier {
		before = before[:beforeSize]
	}
	hasLater := len(after) > afterSize
	if hasLater {
		after = after[:afterSize]
	}
	reverseCaptures(before)

	items := make([]CaptureBody, 0, len(before)+1+len(after))
	for _, capture := range before {
		items = append(items, toBody(capture))
	}
	anchorIndex := len(items)
	items = append(items, toBody(anchor))
	for _, capture := range after {
		items = append(items, toBody(capture))
	}

	return &CaptureContextOutput{Body: CaptureContextBody{
		Items:       items,
		AnchorIndex: anchorIndex,
		HasEarlier:  hasEarlier,
		HasLater:    hasLater,
	}}, nil
}

func contextSizes(before, after int) (int, int, error) {
	if before < 0 || before > maxContextSize || after < 0 || after > maxContextSize {
		return 0, 0, huma.Error422UnprocessableEntity("before and after must be between 0 and 50")
	}
	return before, after, nil
}

func encodeCaptureCursor(capture db.Capture) (string, error) {
	data, err := json.Marshal(captureCursor{CreatedAt: capture.CreatedAt.Time.UTC(), ID: capture.ID})
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeCaptureCursor(value string) (captureCursor, error) {
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return captureCursor{}, err
	}
	var cursor captureCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return captureCursor{}, err
	}
	if cursor.CreatedAt.IsZero() || cursor.ID == uuid.Nil {
		return captureCursor{}, errors.New("cursor is incomplete")
	}
	return cursor, nil
}

func reverseCaptures(items []db.Capture) {
	for left, right := 0, len(items)-1; left < right; left, right = left+1, right-1 {
		items[left], items[right] = items[right], items[left]
	}
}
