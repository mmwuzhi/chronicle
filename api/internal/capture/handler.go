package capture

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

type handler struct {
	q   *db.Queries
	rag *ragclient.Client
}

// Register wires the capture routes. authMW (JWT only) guards every read/mutate
// route; createMW additionally accepts long-lived capture tokens (see
// auth.ValidateTokenOrPAT) and is applied ONLY to POST /captures, so a headless
// quick-capture token can append captures but cannot read, update, or delete.
func Register(api huma.API, pool *pgxpool.Pool, rag *ragclient.Client, authMW, createMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool), rag: rag}

	op := func(id, method, path, summary string) huma.Operation {
		return huma.Operation{
			OperationID: id,
			Method:      method,
			Path:        path,
			Summary:     summary,
			Tags:        []string{"captures"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-captures", http.MethodGet, "/captures", "List captures"), h.list)
	huma.Register(api, op("list-capture-page", http.MethodGet, "/captures/page", "List a page of captures"), h.listPage)
	huma.Register(api, op("get-capture-context", http.MethodGet, "/captures/context", "Get captures around an anchor"), h.context)
	createOp := op("create-capture", http.MethodPost, "/captures", "Create a capture")
	createOp.Middlewares = huma.Middlewares{createMW}
	huma.Register(api, createOp, h.create)
	huma.Register(api, op("get-capture", http.MethodGet, "/captures/{id}", "Get a single capture"), h.get)
	huma.Register(api, op("update-capture", http.MethodPatch, "/captures/{id}", "Update a capture"), h.update)
	huma.Register(api, op("retry-capture-transcription", http.MethodPost, "/captures/{id}/transcription/retry", "Retry audio or image transcription"), h.retryTranscription)
	huma.Register(api, op("set-capture-remind", http.MethodPost, "/captures/{id}/remind", "Set or clear a capture reminder"), h.setRemind)
	huma.Register(api, op("due-reminders", http.MethodGet, "/reminders/due", "List reminders that have come due"), h.dueReminders)
	huma.Register(api, op("pending-reminders", http.MethodGet, "/reminders/pending", "List not-yet-due reminders"), h.pendingReminders)
	huma.Register(api, op("delete-capture", http.MethodDelete, "/captures/{id}", "Delete a capture"), h.delete)
	huma.Register(api, op("list-trashed-captures", http.MethodGet, "/captures/trash", "List soft-deleted captures"), h.listTrash)
	huma.Register(api, op("restore-capture", http.MethodPost, "/captures/{id}/restore", "Restore a soft-deleted capture"), h.restore)
	huma.Register(api, op("list-capture-attachments", http.MethodGet, "/captures/{id}/attachments", "List external file references"), h.listAttachments)
	huma.Register(api, op("add-capture-attachment", http.MethodPost, "/captures/{id}/attachments", "Attach an external file reference"), h.addAttachment)
	huma.Register(api, op("delete-capture-attachment", http.MethodDelete, "/captures/{id}/attachments/{attachmentId}", "Remove an external file reference"), h.deleteAttachment)
	huma.Register(api, op("list-capture-links", http.MethodGet, "/captures/{id}/links", "List captures explicitly linked to this one"), h.listLinks)
	huma.Register(api, op("add-capture-link", http.MethodPost, "/captures/{id}/links", "Link this capture to another"), h.addLink)
	huma.Register(api, op("remove-capture-link", http.MethodDelete, "/captures/{id}/links/{targetId}", "Remove a link between two captures"), h.removeLink)
	huma.Register(api, op("related-captures", http.MethodGet, "/captures/{id}/related", "Semantic suggestions related to this capture"), h.related)
}

// --- shared types ---

type CaptureBody struct {
	ID                  string  `json:"id"`
	RawText             *string `json:"rawText"`
	MediaUrl            *string `json:"mediaUrl"`
	MediaType           string  `json:"mediaType"`
	ClassifiedAs        string  `json:"classifiedAs"`
	Source              string  `json:"source"`
	Transcript          *string `json:"transcript"`
	TranscriptionStatus string  `json:"transcriptionStatus"`
	TranscriptionModel  *string `json:"transcriptionModel"`
	TranscribedAt       *string `json:"transcribedAt"`
	AudioDurationSec    *int32  `json:"audioDurationSec"`
	RemindAt            *string `json:"remindAt"`
	CreatedAt           string  `json:"createdAt"`
	DeletedAt           *string `json:"deletedAt"`
}

func toBody(c db.Capture) CaptureBody {
	b := CaptureBody{
		ID:                  c.ID.String(),
		MediaType:           string(c.MediaType),
		ClassifiedAs:        string(c.ClassifiedAs),
		Source:              c.Source,
		TranscriptionStatus: string(c.TranscriptionStatus),
		CreatedAt:           c.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if c.RawText.Valid {
		b.RawText = &c.RawText.String
	}
	if c.MediaUrl.Valid {
		b.MediaUrl = &c.MediaUrl.String
	}
	if c.Transcript.Valid {
		b.Transcript = &c.Transcript.String
	}
	if c.TranscriptionModel.Valid {
		b.TranscriptionModel = &c.TranscriptionModel.String
	}
	if c.TranscribedAt.Valid {
		s := c.TranscribedAt.Time.UTC().Format(time.RFC3339)
		b.TranscribedAt = &s
	}
	if c.AudioDurationSec.Valid {
		b.AudioDurationSec = &c.AudioDurationSec.Int32
	}
	if c.RemindAt.Valid {
		s := c.RemindAt.Time.UTC().Format(time.RFC3339)
		b.RemindAt = &s
	}
	if c.DeletedAt.Valid {
		s := c.DeletedAt.Time.UTC().Format(time.RFC3339)
		b.DeletedAt = &s
	}
	return b
}

// --- list ---

type CaptureListInput struct {
	ClassifiedAs    string `query:"classifiedAs" doc:"Filter by classification: task, idea, routine, log, unclassified"`
	IncludeReminded bool   `query:"includeReminded" doc:"Include captures with a future reminder (hidden by default until due); set true for a reminder-management view"`
}

type ListOutput struct {
	Body []CaptureBody
}

func (h *handler) list(ctx context.Context, input *CaptureListInput) (*ListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.ListCaptures(ctx, db.ListCapturesParams{
		UserID:          uid,
		ClassifiedAs:    nullText(strPtr(input.ClassifiedAs)),
		IncludeReminded: input.IncludeReminded,
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

// --- create ---

type CaptureCreateInput struct {
	Body struct {
		RawText      *string `json:"rawText,omitempty"`
		MediaUrl     *string `json:"mediaUrl,omitempty"`
		MediaType    string  `json:"mediaType" enum:"text,image,audio"`
		ClassifiedAs string  `json:"classifiedAs,omitempty" enum:"task,idea,routine,log,unclassified" default:"unclassified"`
		Source       string  `json:"source,omitempty" default:"web" doc:"Capture source, for example web or desktop_quick_capture"`
		RemindAt     *string `json:"remindAt,omitempty" doc:"RFC3339 time to resurface this capture"`
	}
}

type CreateOutput struct {
	Body CaptureBody
}

func (h *handler) create(ctx context.Context, input *CaptureCreateInput) (*CreateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	classifiedAs := input.Body.ClassifiedAs
	if classifiedAs == "" {
		classifiedAs = "unclassified"
	}
	source, err := normalizeSource(input.Body.Source)
	if err != nil {
		return nil, err
	}
	if input.Body.MediaType == "text" && (input.Body.RawText == nil || strings.TrimSpace(*input.Body.RawText) == "") {
		return nil, huma.Error422UnprocessableEntity("rawText is required for text captures")
	}
	remindAt, err := parseRemindAt(input.Body.RemindAt)
	if err != nil {
		return nil, err
	}
	c, err := h.q.CreateCapture(ctx, db.CreateCaptureParams{
		UserID:       uid,
		RawText:      nullText(input.Body.RawText),
		MediaUrl:     nullText(input.Body.MediaUrl),
		MediaType:    db.CaptureMediaType(input.Body.MediaType),
		ClassifiedAs: db.CaptureClassifiedAs(classifiedAs),
		Source:       source,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	if remindAt.Valid {
		c, err = h.q.SetCaptureRemind(ctx, db.SetCaptureRemindParams{
			ID:       c.ID,
			UserID:   uid,
			RemindAt: remindAt,
		})
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
	}
	// Only index when there's text to embed; media-only captures get indexed once
	// their transcript lands (transcription worker), not here.
	if input.Body.RawText != nil && strings.TrimSpace(*input.Body.RawText) != "" {
		h.rag.Index(uid.String(), c.ID.String())
	}
	return &CreateOutput{Body: toBody(c)}, nil
}

// --- update ---

type CaptureUpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		RawText      *string `json:"rawText,omitempty"`
		Transcript   *string `json:"transcript,omitempty"`
		ClassifiedAs *string `json:"classifiedAs,omitempty" enum:"task,idea,routine,log,unclassified"`
	}
}

type UpdateOutput struct {
	Body CaptureBody
}

func (h *handler) update(ctx context.Context, input *CaptureUpdateInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	c, err := h.q.UpdateCapture(ctx, db.UpdateCaptureParams{
		ID:           id,
		UserID:       uid,
		RawText:      nullText(input.Body.RawText),
		Transcript:   nullText(input.Body.Transcript),
		ClassifiedAs: nullText(input.Body.ClassifiedAs),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	// Reindex only when the indexable text actually changed — metadata-only edits
	// (classifiedAs, taskId) must not trigger embedding + extraction.
	if input.Body.RawText != nil || input.Body.Transcript != nil {
		h.rag.Index(uid.String(), c.ID.String())
	}
	return &UpdateOutput{Body: toBody(c)}, nil
}

// --- get one ---
//
// Fetch a single capture by id. The desktop sticky surface uses this to refresh a
// pinned capture's content on launch; it also backs id-addressed deep links.
// GetCapture is scoped to the owner and excludes soft-deleted rows, so another
// user's capture or a trashed one is a 404, never a leak.

type CaptureGetInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) get(ctx context.Context, input *CaptureGetInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	c, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(c)}, nil
}

type CaptureRetryTranscriptionInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) retryTranscription(ctx context.Context, input *CaptureRetryTranscriptionInput) (*UpdateOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	c, err := h.q.RetryCaptureTranscription(ctx, db.RetryCaptureTranscriptionParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("eligible capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(c)}, nil
}

// --- reminders (time-based recall) ---
//
// Only this browse-side surface reads remind_at. Search and recall (search.sql,
// ragsvc) never filter it, preserving time-window completeness.

type CaptureRemindInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		At *string `json:"at,omitempty" doc:"RFC3339 time to resurface this capture; omit or null to clear the reminder"`
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
		ID:       id,
		UserID:   uid,
		RemindAt: at,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(c)}, nil
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

// --- trash (recover soft-deleted captures) ---
//
// Soft delete is the only deletion (project guardrail: never hard-DELETE user
// data). The trash exposes the recovery side of that: list what's deleted and
// restore it. There is deliberately no "permanent delete" / "empty trash" — that
// would be a hard DELETE.

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
	// Both ends must exist and belong to the caller before we record the edge.
	for _, cid := range []uuid.UUID{id, target} {
		if _, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: cid, UserID: uid}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, huma.Error404NotFound("capture not found")
			}
			return nil, huma.Error500InternalServerError("internal error")
		}
	}
	if err := h.q.AddCaptureLink(ctx, db.AddCaptureLinkParams{X: id, Y: target, UserID: uid}); err != nil {
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
	if err := h.q.RemoveCaptureLink(ctx, db.RemoveCaptureLinkParams{UserID: uid, X: id, Y: target}); err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

type CaptureRelatedInput struct {
	ID    string `path:"id" format:"uuid"`
	Limit int    `query:"limit" default:"10" doc:"Max suggestions to return"`
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
		limit = 10
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
	if linked, lerr := h.q.ListLinkedCaptures(ctx, db.ListLinkedCapturesParams{CaptureID: id, UserID: uid}); lerr == nil {
		for _, c := range linked {
			exclude[c.ID.String()] = struct{}{}
		}
	}
	// Ask for headroom so the post-filter still yields ~limit; degrade to empty on
	// any sidecar error (disabled, embeddings off, cold model) — suggestions are
	// optional, never an error surface.
	items, err := h.rag.Related(ctx, uid.String(), input.ID, limit+len(exclude))
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

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

var sourcePattern = regexp.MustCompile(`^[a-z][a-z0-9_:-]{0,63}$`)

func normalizeSource(source string) (string, error) {
	source = strings.TrimSpace(source)
	if source == "" {
		return "web", nil
	}
	if !sourcePattern.MatchString(source) {
		return "", huma.Error422UnprocessableEntity("source must start with a lowercase letter and contain only lowercase letters, digits, _, :, or -")
	}
	return source, nil
}
