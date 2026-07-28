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

// --- delete ---

type CaptureDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) delete(ctx context.Context, input *CaptureDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err := h.q.DeleteCapture(ctx, db.DeleteCaptureParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	h.invalidateCorpus(ctx, uid)
	return nil, nil
}

// --- trash (recover or permanently remove soft-deleted captures) ---
//
// Normal delete is always soft (project guardrail: the DELETE route never hard-
// DELETEs user data). The trash is the recovery surface: list what's deleted and
// restore it. It also offers the escape hatch the guardrail carves out — an
// explicit, trash-only permanent delete / empty-trash for content the user truly
// wants gone (a mistaken or sensitive capture). This mirrors the macOS "Recently
// Deleted" model: soft by default, hard only on a deliberate second action from
// inside the trash. FK ON DELETE CASCADE clears the derived rows; media keys are
// retained transactionally in a durable outbox until R2 confirms deletion.

type CaptureTrashListInput struct{}

// maxTrashList caps the trash listing so a user who never empties the trash
// can't grow the response without bound. Older rows stay restorable once the
// newer ones are purged or restored; empty-trash always clears everything.
const maxTrashList = 500

func (h *handler) listTrash(ctx context.Context, _ *CaptureTrashListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.ListTrashedCaptures(ctx, db.ListTrashedCapturesParams{
		UserID:      uid,
		ResultLimit: maxTrashList,
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

type CaptureRestoreInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) restore(ctx context.Context, input *CaptureRestoreInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	c, err := h.q.RestoreCapture(ctx, db.RestoreCaptureParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("deleted capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	h.invalidateCorpus(ctx, uid)
	return &UpdateOutput{Body: toBody(c)}, nil
}

type CapturePermanentDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) permanentDelete(ctx context.Context, input *CapturePermanentDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	_, err = h.q.PermanentDeleteCapture(ctx, db.PermanentDeleteCaptureParams{ID: id, UserID: uid})
	if err != nil {
		// No row means the capture is not in the trash (live, already purged, or
		// another owner's) — never a hard delete of a live capture.
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("trashed capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	h.kickMediaDeletion()
	h.invalidateCorpus(ctx, uid)
	return nil, nil
}

type CaptureEmptyTrashInput struct{}

type EmptyTrashOutput struct {
	Body struct {
		Purged int `json:"purged" doc:"Number of captures permanently removed"`
	}
}

func (h *handler) emptyTrash(ctx context.Context, _ *CaptureEmptyTrashInput) (*EmptyTrashOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	ids, err := h.q.EmptyTrash(ctx, uid)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	h.kickMediaDeletion()
	h.invalidateCorpus(ctx, uid)
	out := &EmptyTrashOutput{}
	out.Body.Purged = len(ids)
	return out, nil
}

func (h *handler) invalidateCorpus(ctx context.Context, uid uuid.UUID) {
	if err := h.rag.Invalidate(ctx, uid.String()); err != nil {
		slog.WarnContext(
			ctx, "rag corpus invalidation failed",
			"traceId", middleware.GetTraceID(ctx),
			"userId", uid,
			"err", err,
		)
	}
}
