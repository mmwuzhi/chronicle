package capture

import (
	"context"
	"errors"
	"log/slog"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

// --- related captures (explicit links + semantic suggestions) ---
//
// Two complementary surfaces for the P1 "Related captures" feature: durable
// user-made links (capture_links, owned here in Postgres) and AI-suggested
// semantic neighbours (served by ragsvc, which holds the embeddings). Links are
// undirected; the SQL normalises the pair so direction never matters.

type CaptureLinkListInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) listLinks(ctx context.Context, input *CaptureLinkListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	rows, err := h.q.ListLinkedCaptures(ctx, db.ListLinkedCapturesParams{CaptureID: id, UserID: uid})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &ListOutput{Body: make([]CaptureBody, len(rows))}
	for i, c := range rows {
		out.Body[i] = toBody(c)
	}
	return out, nil
}

type CaptureLinkCreateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		TargetID string `json:"targetId" format:"uuid" doc:"The other capture to link this one to"`
	}
}

func (h *handler) addLink(ctx context.Context, input *CaptureLinkCreateInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	target, err := uuid.Parse(input.Body.TargetID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid targetId")
	}
	if id == target {
		return nil, huma.Error422UnprocessableEntity("cannot link a capture to itself")
	}
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if err := q.LockCapturePair(ctx, db.LockCapturePairParams{
			UserID: uid, X: id, Y: target,
		}); err != nil {
			return err
		}
		if err := requireOwnedCapturePair(ctx, q, uid, id, target); err != nil {
			return err
		}
		if err := q.AddCaptureLink(ctx, db.AddCaptureLinkParams{X: id, Y: target, UserID: uid}); err != nil {
			return err
		}
		return q.RemoveRelatedDismissal(ctx, db.RemoveRelatedDismissalParams{
			UserID: uid, AnchorID: id, TargetID: target,
		})
	})
	if err != nil {
		var statusErr huma.StatusError
		if errors.As(err, &statusErr) {
			return nil, statusErr
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

type CaptureLinkDeleteInput struct {
	ID       string `path:"id" format:"uuid"`
	TargetID string `path:"targetId" format:"uuid"`
}

func (h *handler) removeLink(ctx context.Context, input *CaptureLinkDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	target, err := uuid.Parse(input.TargetID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid targetId")
	}
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if err := q.LockCapturePair(ctx, db.LockCapturePairParams{
			UserID: uid, X: id, Y: target,
		}); err != nil {
			return err
		}
		if err := requireOwnedCapturePair(ctx, q, uid, id, target); err != nil {
			return err
		}
		if err := q.RemoveCaptureLink(ctx, db.RemoveCaptureLinkParams{UserID: uid, X: id, Y: target}); err != nil {
			return err
		}
		return q.AddRelatedDismissal(ctx, db.AddRelatedDismissalParams{
			UserID: uid, AnchorID: id, TargetID: target,
		})
	})
	if err != nil {
		var statusErr huma.StatusError
		if errors.As(err, &statusErr) {
			return nil, statusErr
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

type CaptureRelatedDismissalInput struct {
	ID       string `path:"id" format:"uuid"`
	TargetID string `path:"targetId" format:"uuid"`
}

func (h *handler) dismissRelated(
	ctx context.Context, input *CaptureRelatedDismissalInput,
) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	target, err := uuid.Parse(input.TargetID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid targetId")
	}
	if id == target {
		return nil, huma.Error422UnprocessableEntity("cannot dismiss a capture from itself")
	}
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if err := q.LockCapturePair(ctx, db.LockCapturePairParams{
			UserID: uid, X: id, Y: target,
		}); err != nil {
			return err
		}
		if err := requireOwnedCapturePair(ctx, q, uid, id, target); err != nil {
			return err
		}
		// A concurrent Link and Not related action has deterministic last-writer
		// semantics: dismissal removes the explicit edge before suppressing the pair.
		if err := q.RemoveCaptureLink(ctx, db.RemoveCaptureLinkParams{
			UserID: uid, X: id, Y: target,
		}); err != nil {
			return err
		}
		return q.AddRelatedDismissal(ctx, db.AddRelatedDismissalParams{
			UserID: uid, AnchorID: id, TargetID: target,
		})
	})
	if err != nil {
		var statusErr huma.StatusError
		if errors.As(err, &statusErr) {
			return nil, statusErr
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

func requireOwnedCapturePair(
	ctx context.Context, q *db.Queries, userID, first, second uuid.UUID,
) error {
	for _, captureID := range []uuid.UUID{first, second} {
		if _, err := q.GetCapture(ctx, db.GetCaptureParams{ID: captureID, UserID: userID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return huma.Error404NotFound("capture not found")
			}
			return huma.Error500InternalServerError("internal error")
		}
	}
	return nil
}

type CaptureRelatedInput struct {
	ID    string `path:"id" format:"uuid"`
	Limit int    `query:"limit" default:"5" doc:"Max suggestions to return"`
}

type RelatedCapture struct {
	ID        string  `json:"id"`
	Content   string  `json:"content"`
	CreatedAt string  `json:"createdAt"`
	Modality  string  `json:"modality"`
	Score     float64 `json:"score"`
}

type CaptureRelatedOutput struct {
	Body []RelatedCapture
}

func (h *handler) related(ctx context.Context, input *CaptureRelatedInput) (*CaptureRelatedOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	limit := input.Limit
	if limit <= 0 {
		limit = 5
	}
	if limit > 50 {
		limit = 50
	}
	if _, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	// Exclude already-linked captures (and the capture itself) from suggestions —
	// they belong in the explicit-links list, not the "you might also link" list.
	exclude := map[string]struct{}{input.ID: {}}
	linked, lerr := h.q.ListLinkedCaptures(ctx, db.ListLinkedCapturesParams{CaptureID: id, UserID: uid})
	if lerr != nil {
		// Suggestions are optional, and showing an explicit link as a suggestion is
		// worse than showing no suggestions while preferences are unavailable.
		slog.WarnContext(ctx, "related links unavailable",
			"traceId", middleware.GetTraceID(ctx), "err", lerr)
		return &CaptureRelatedOutput{Body: []RelatedCapture{}}, nil
	}
	for _, c := range linked {
		exclude[c.ID.String()] = struct{}{}
	}
	dismissed, derr := h.q.ListRelatedDismissedIDs(ctx, db.ListRelatedDismissedIDsParams{
		UserID: uid, AnchorID: id,
	})
	if derr != nil {
		// Fail this optional surface closed: an unavailable preference layer must
		// never reintroduce a pair the user explicitly rejected.
		slog.WarnContext(ctx, "related dismissals unavailable",
			"traceId", middleware.GetTraceID(ctx), "err", derr)
		return &CaptureRelatedOutput{Body: []RelatedCapture{}}, nil
	}
	for _, targetID := range dismissed {
		exclude[targetID.String()] = struct{}{}
	}
	// Ask for headroom so the post-filter still yields ~limit; degrade to empty on
	// any sidecar error (disabled, embeddings off, cold model) — suggestions are
	// optional, never an error surface.
	excludedIDs := make([]string, 0, len(exclude))
	for id := range exclude {
		excludedIDs = append(excludedIDs, id)
	}
	items, err := h.rag.Related(ctx, uid.String(), input.ID, limit, excludedIDs)
	if err != nil {
		return &CaptureRelatedOutput{Body: []RelatedCapture{}}, nil
	}
	out := &CaptureRelatedOutput{Body: make([]RelatedCapture, 0, limit)}
	for _, it := range items {
		if _, skip := exclude[it.ID]; skip {
			continue
		}
		out.Body = append(out.Body, RelatedCapture{
			ID:        it.ID,
			Content:   it.Content,
			CreatedAt: it.CreatedAt,
			Modality:  it.Modality,
			Score:     it.Score,
		})
		if len(out.Body) >= limit {
			break
		}
	}
	return out, nil
}
