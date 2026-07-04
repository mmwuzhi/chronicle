package capture

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

// --- external attachments (cloud-drive references) ---
//
// Chronicle stores only the pointer and display metadata. File bytes live in the
// user's cloud drive account, uploaded by a provider-specific client.

const (
	maxAttachmentNameLen = 500
	maxAttachmentURLLen  = 2048
)

type CaptureAttachmentBody struct {
	ID             string  `json:"id"`
	CaptureID      string  `json:"captureId"`
	Provider       string  `json:"provider"`
	ProviderFileID string  `json:"providerFileId"`
	Name           string  `json:"name"`
	MimeType       *string `json:"mimeType"`
	SizeBytes      *int64  `json:"sizeBytes"`
	WebURL         string  `json:"webUrl"`
	CreatedAt      string  `json:"createdAt"`
}

func attachmentToBody(a db.CaptureAttachment) CaptureAttachmentBody {
	b := CaptureAttachmentBody{
		ID:             a.ID.String(),
		CaptureID:      a.CaptureID.String(),
		Provider:       string(a.Provider),
		ProviderFileID: a.ProviderFileID,
		Name:           a.Name,
		WebURL:         a.WebUrl,
		CreatedAt:      a.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if a.MimeType.Valid {
		b.MimeType = &a.MimeType.String
	}
	if a.SizeBytes.Valid {
		b.SizeBytes = &a.SizeBytes.Int64
	}
	return b
}

type CaptureAttachmentListInput struct {
	ID string `path:"id" format:"uuid"`
}

type CaptureAttachmentListOutput struct {
	Body []CaptureAttachmentBody
}

func (h *handler) listAttachments(ctx context.Context, input *CaptureAttachmentListInput) (*CaptureAttachmentListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	rows, err := h.q.ListCaptureAttachments(ctx, db.ListCaptureAttachmentsParams{UserID: uid, CaptureID: id})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &CaptureAttachmentListOutput{Body: make([]CaptureAttachmentBody, len(rows))}
	for i, a := range rows {
		out.Body[i] = attachmentToBody(a)
	}
	return out, nil
}

type CaptureAttachmentCreateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Provider       string  `json:"provider" enum:"google_drive,onedrive,dropbox"`
		ProviderFileID string  `json:"providerFileId"`
		Name           string  `json:"name"`
		MimeType       *string `json:"mimeType,omitempty"`
		SizeBytes      *int64  `json:"sizeBytes,omitempty"`
		WebURL         string  `json:"webUrl"`
	}
}

type CaptureAttachmentCreateOutput struct {
	Body CaptureAttachmentBody
}

func (h *handler) addAttachment(ctx context.Context, input *CaptureAttachmentCreateInput) (*CaptureAttachmentCreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	params, err := attachmentParams(uid, id, input)
	if err != nil {
		return nil, err
	}
	a, err := h.q.CreateCaptureAttachment(ctx, params)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, huma.Error409Conflict("attachment already exists")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &CaptureAttachmentCreateOutput{Body: attachmentToBody(a)}, nil
}

func attachmentParams(uid, captureID uuid.UUID, input *CaptureAttachmentCreateInput) (db.CreateCaptureAttachmentParams, error) {
	provider, err := parseCloudDriveProvider(input.Body.Provider)
	if err != nil {
		return db.CreateCaptureAttachmentParams{}, err
	}
	providerFileID := strings.TrimSpace(input.Body.ProviderFileID)
	if providerFileID == "" {
		return db.CreateCaptureAttachmentParams{}, huma.Error422UnprocessableEntity("providerFileId is required")
	}
	name := strings.TrimSpace(input.Body.Name)
	if name == "" {
		return db.CreateCaptureAttachmentParams{}, huma.Error422UnprocessableEntity("name is required")
	}
	if len(name) > maxAttachmentNameLen {
		return db.CreateCaptureAttachmentParams{}, huma.Error422UnprocessableEntity("name is too long")
	}
	webURL, err := normalizeAttachmentURL(input.Body.WebURL)
	if err != nil {
		return db.CreateCaptureAttachmentParams{}, err
	}
	size := pgtype.Int8{}
	if input.Body.SizeBytes != nil {
		if *input.Body.SizeBytes < 0 {
			return db.CreateCaptureAttachmentParams{}, huma.Error422UnprocessableEntity("sizeBytes must be non-negative")
		}
		size = pgtype.Int8{Int64: *input.Body.SizeBytes, Valid: true}
	}
	return db.CreateCaptureAttachmentParams{
		UserID:         uid,
		CaptureID:      captureID,
		Provider:       provider,
		ProviderFileID: providerFileID,
		Name:           name,
		MimeType:       nullText(input.Body.MimeType),
		SizeBytes:      size,
		WebUrl:         webURL,
	}, nil
}

func parseCloudDriveProvider(provider string) (db.CloudDriveProvider, error) {
	switch db.CloudDriveProvider(strings.TrimSpace(provider)) {
	case db.CloudDriveProviderGoogleDrive:
		return db.CloudDriveProviderGoogleDrive, nil
	case db.CloudDriveProviderOnedrive:
		return db.CloudDriveProviderOnedrive, nil
	case db.CloudDriveProviderDropbox:
		return db.CloudDriveProviderDropbox, nil
	default:
		return "", huma.Error422UnprocessableEntity("provider must be google_drive, onedrive, or dropbox")
	}
}

func normalizeAttachmentURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", huma.Error422UnprocessableEntity("webUrl is required")
	}
	if len(trimmed) > maxAttachmentURLLen {
		return "", huma.Error422UnprocessableEntity("webUrl is too long")
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", huma.Error422UnprocessableEntity("webUrl must be an absolute URL")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", huma.Error422UnprocessableEntity("webUrl must use http or https")
	}
	return trimmed, nil
}

type CaptureAttachmentDeleteInput struct {
	ID           string `path:"id" format:"uuid"`
	AttachmentID string `path:"attachmentId" format:"uuid"`
}

func (h *handler) deleteAttachment(ctx context.Context, input *CaptureAttachmentDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	attachmentID, err := uuid.Parse(input.AttachmentID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid attachmentId")
	}
	if _, err := h.q.DeleteCaptureAttachment(ctx, db.DeleteCaptureAttachmentParams{ID: attachmentID, CaptureID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("attachment not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}
