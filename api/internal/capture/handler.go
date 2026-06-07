package capture

import (
	"context"
	"errors"
	"net/http"
	"regexp"
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
			Tags:        []string{"captures"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-captures", http.MethodGet, "/captures", "List captures"), h.list)
	huma.Register(api, op("list-capture-page", http.MethodGet, "/captures/page", "List a page of captures"), h.listPage)
	huma.Register(api, op("get-capture-context", http.MethodGet, "/captures/context", "Get captures around an anchor"), h.context)
	huma.Register(api, op("create-capture", http.MethodPost, "/captures", "Create a capture"), h.create)
	huma.Register(api, op("update-capture", http.MethodPatch, "/captures/{id}", "Update a capture"), h.update)
	huma.Register(api, op("retry-capture-transcription", http.MethodPost, "/captures/{id}/transcription/retry", "Retry audio transcription"), h.retryTranscription)
	huma.Register(api, op("delete-capture", http.MethodDelete, "/captures/{id}", "Delete a capture"), h.delete)
}

// --- shared types ---

type CaptureBody struct {
	ID                  string  `json:"id"`
	RawText             *string `json:"rawText"`
	MediaUrl            *string `json:"mediaUrl"`
	MediaType           string  `json:"mediaType"`
	ClassifiedAs        string  `json:"classifiedAs"`
	TaskID              *string `json:"taskId"`
	Source              string  `json:"source"`
	Transcript          *string `json:"transcript"`
	TranscriptionStatus string  `json:"transcriptionStatus"`
	TranscriptionModel  *string `json:"transcriptionModel"`
	TranscribedAt       *string `json:"transcribedAt"`
	AudioDurationSec    *int32  `json:"audioDurationSec"`
	CreatedAt           string  `json:"createdAt"`
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
	if c.TaskID.Valid {
		tid := uuid.UUID(c.TaskID.Bytes).String()
		b.TaskID = &tid
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
	return b
}

// --- list ---

type CaptureListInput struct {
	ClassifiedAs string `query:"classifiedAs" doc:"Filter by classification: task, idea, routine, log, unclassified"`
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
		UserID:       uid,
		ClassifiedAs: nullText(strPtr(input.ClassifiedAs)),
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
		ClassifiedAs string  `json:"classifiedAs" enum:"task,idea,routine,log,unclassified" default:"unclassified"`
		TaskID       *string `json:"taskId,omitempty" format:"uuid"`
		Source       string  `json:"source,omitempty" default:"web" doc:"Capture source, for example web or desktop_quick_capture"`
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
	c, err := h.q.CreateCapture(ctx, db.CreateCaptureParams{
		UserID:       uid,
		RawText:      nullText(input.Body.RawText),
		MediaUrl:     nullText(input.Body.MediaUrl),
		MediaType:    db.CaptureMediaType(input.Body.MediaType),
		ClassifiedAs: db.CaptureClassifiedAs(classifiedAs),
		TaskID:       nullUUID(input.Body.TaskID),
		Source:       source,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
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
		TaskID       *string `json:"taskId,omitempty" format:"uuid"`
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
		TaskID:       nullUUID(input.Body.TaskID),
	})
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
			return nil, huma.Error404NotFound("eligible audio capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &UpdateOutput{Body: toBody(c)}, nil
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
