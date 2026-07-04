package capture

import (
	"context"
	"errors"
	"log/slog"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
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
// inside the trash. FK ON DELETE CASCADE clears the derived rows; media in R2 is
// purged best-effort (the DB delete stays authoritative if R2 cleanup fails).

type CaptureTrashListInput struct{}

func (h *handler) listTrash(ctx context.Context, _ *CaptureTrashListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.ListTrashedCaptures(ctx, uid)
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
	mediaKey, err := h.q.PermanentDeleteCapture(ctx, db.PermanentDeleteCaptureParams{ID: id, UserID: uid})
	if err != nil {
		// No row means the capture is not in the trash (live, already purged, or
		// another owner's) — never a hard delete of a live capture.
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("trashed capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	h.purgeMedia(ctx, mediaKey)
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
	keys, err := h.q.EmptyTrash(ctx, uid)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	for _, k := range keys {
		h.purgeMedia(ctx, k)
	}
	out := &EmptyTrashOutput{}
	out.Body.Purged = len(keys)
	return out, nil
}

// purgeMedia best-effort deletes a capture's R2 object after a permanent delete.
// The DB row is already gone (authoritative); a failed object delete leaves a
// storage orphan but never blocks or reverses the delete, so we only log it.
func (h *handler) purgeMedia(ctx context.Context, key pgtype.Text) {
	if h.store == nil || h.bucket == "" || !key.Valid || key.String == "" {
		return
	}
	if _, err := h.store.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(h.bucket),
		Key:    aws.String(key.String),
	}); err != nil {
		slog.WarnContext(ctx, "permanent delete: R2 object cleanup failed", "err", err, "key", key.String)
	}
}
