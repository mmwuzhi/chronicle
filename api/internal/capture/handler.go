package capture

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

// The capture package is split by sub-domain: this file holds Register, the
// core CRUD surface, the todo facet, and shared helpers; reminders live in
// remind.go, soft delete + trash in trash.go, external attachments in
// attachments.go, explicit links + semantic suggestions in links.go, and
// cursor pagination in pagination.go.

type handler struct {
	q           *db.Queries
	pool        *pgxpool.Pool
	rag         *ragclient.Client
	frontendURL string
	// kickMediaDeletion wakes the durable R2 deletion worker after an explicit
	// permanent delete writes its tombstone.
	kickMediaDeletion func()
	// kickTranscription wakes the event-driven transcription worker after
	// retryTranscription re-queues a job (see upload.StartTranscriptionWorker).
	kickTranscription func()
	// linkFetchEnabled gates enqueuing link enrichment on create; kickLinkFetch
	// wakes the link-fetch worker (see linkfetch.StartLinkFetchWorker).
	linkFetchEnabled bool
	kickLinkFetch    func()
}

// objectDeleter is the sliver of the R2/S3 client the capture handler needs to
// purge media after a permanent delete. Nil when R2 is not configured; durable
// tombstones remain in PostgreSQL until a configured worker can drain them.
type objectDeleter interface {
	DeleteObject(ctx context.Context, in *s3.DeleteObjectInput, opts ...func(*s3.Options)) (*s3.DeleteObjectOutput, error)
}

// Register wires the capture routes. authMW (JWT only) guards every read/mutate
// route; createMW additionally accepts long-lived capture tokens (see
// auth.ValidateTokenOrPAT) and is applied ONLY to POST /captures, so a headless
// quick-capture token can append captures but cannot read, update, or delete.
//
// kickTranscription wakes the transcription worker when a retry re-queues a
// job; pass nil when transcription is disabled.
// linkFetchEnabled + kickLinkFetch wire link enrichment: when enabled, creating
// a text capture that contains a URL enqueues a background fetch and wakes the
// link-fetch worker; pass false / nil when link fetch is disabled.
func Register(api huma.API, pool *pgxpool.Pool, rag *ragclient.Client, frontendURL string, authMW, createMW func(huma.Context, func(huma.Context)), kickTranscription func(), linkFetchEnabled bool, kickLinkFetch func(), kickMediaDeletion func()) {
	if kickTranscription == nil {
		kickTranscription = func() {}
	}
	if kickLinkFetch == nil {
		kickLinkFetch = func() {}
	}
	if kickMediaDeletion == nil {
		kickMediaDeletion = func() {}
	}
	h := &handler{
		q:                 db.New(pool),
		pool:              pool,
		rag:               rag,
		frontendURL:       strings.TrimRight(frontendURL, "/"),
		kickMediaDeletion: kickMediaDeletion,
		kickTranscription: kickTranscription,
		linkFetchEnabled:  linkFetchEnabled,
		kickLinkFetch:     kickLinkFetch,
	}

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

	huma.Register(api, op("list-capture-page", http.MethodGet, "/captures/page", "List a page of captures"), h.listPage)
	huma.Register(api, op("get-capture-context", http.MethodGet, "/captures/context", "Get captures around an anchor"), h.context)
	createOp := op("create-capture", http.MethodPost, "/captures", "Create a capture")
	createOp.Middlewares = huma.Middlewares{createMW}
	huma.Register(api, createOp, h.create)
	huma.Register(api, op("create-capture-with-attachment", http.MethodPost, "/captures/with-attachment", "Atomically create a capture and external file reference"), h.createWithAttachment)
	huma.Register(api, op("get-capture", http.MethodGet, "/captures/{id}", "Get a single capture"), h.get)
	huma.Register(api, op("update-capture", http.MethodPatch, "/captures/{id}", "Update a capture"), h.update)
	huma.Register(api, op("retry-capture-transcription", http.MethodPost, "/captures/{id}/transcription/retry", "Retry audio or image transcription"), h.retryTranscription)
	huma.Register(api, op("review-today", http.MethodGet, "/review/today", "Captures to revisit today: on-this-day and a rediscover sample"), h.reviewToday)
	huma.Register(api, op("set-capture-remind", http.MethodPost, "/captures/{id}/remind", "Set or clear a capture reminder"), h.setRemind)
	huma.Register(api, op("due-reminders", http.MethodGet, "/reminders/due", "List reminders that have come due"), h.dueReminders)
	huma.Register(api, op("pending-reminders", http.MethodGet, "/reminders/pending", "List not-yet-due reminders"), h.pendingReminders)
	huma.Register(api, op("delete-capture", http.MethodDelete, "/captures/{id}", "Delete a capture"), h.delete)
	huma.Register(api, op("list-trashed-captures", http.MethodGet, "/captures/trash", "List soft-deleted captures"), h.listTrash)
	huma.Register(api, op("restore-capture", http.MethodPost, "/captures/{id}/restore", "Restore a soft-deleted capture"), h.restore)
	huma.Register(api, op("permanently-delete-capture", http.MethodDelete, "/captures/{id}/permanent", "Permanently delete a trashed capture"), h.permanentDelete)
	huma.Register(api, op("empty-trash", http.MethodPost, "/trash/empty", "Permanently delete every trashed capture"), h.emptyTrash)
	huma.Register(api, op("list-capture-attachments", http.MethodGet, "/captures/{id}/attachments", "List external file references"), h.listAttachments)
	huma.Register(api, op("add-capture-attachment", http.MethodPost, "/captures/{id}/attachments", "Attach an external file reference"), h.addAttachment)
	huma.Register(api, op("delete-capture-attachment", http.MethodDelete, "/captures/{id}/attachments/{attachmentId}", "Remove an external file reference"), h.deleteAttachment)
	huma.Register(api, op("list-capture-links", http.MethodGet, "/captures/{id}/links", "List captures explicitly linked to this one"), h.listLinks)
	huma.Register(api, op("add-capture-link", http.MethodPost, "/captures/{id}/links", "Link this capture to another"), h.addLink)
	huma.Register(api, op("remove-capture-link", http.MethodDelete, "/captures/{id}/links/{targetId}", "Remove a link between two captures"), h.removeLink)
	huma.Register(api, op("related-captures", http.MethodGet, "/captures/{id}/related", "Semantic suggestions related to this capture"), h.related)
	huma.Register(api, op("dismiss-related-capture", http.MethodPut, "/captures/{id}/related-dismissals/{targetId}", "Hide one semantic relation suggestion"), h.dismissRelated)
	huma.Register(api, op("create-capture-share", http.MethodPost, "/captures/{id}/shares", "Create or replace a read-only Capture snapshot"), h.createShare)
	huma.Register(api, op("list-capture-shares", http.MethodGet, "/shares", "List active Capture shares"), h.listShares)
	huma.Register(api, op("revoke-capture-share", http.MethodDelete, "/shares/{id}", "Revoke a Capture share"), h.revokeShare)
	huma.Register(api, huma.Operation{
		OperationID: "get-public-capture-share",
		Method:      http.MethodGet,
		Path:        "/public/shares/{id}",
		Summary:     "Read an active shared Capture snapshot",
		Tags:        []string{"shares"},
	}, h.getPublicShare)
}

// --- shared types ---

type CaptureBody struct {
	ID                  string  `json:"id"`
	RawText             *string `json:"rawText"`
	MediaUrl            *string `json:"mediaUrl"`
	MediaType           string  `json:"mediaType"`
	Source              string  `json:"source"`
	TodoAt              *string `json:"todoAt" doc:"When the capture was flagged as a todo; null means it is not a todo"`
	DoneAt              *string `json:"doneAt" doc:"When the todo was completed; null means not done (or not a todo)"`
	Transcript          *string `json:"transcript"`
	TranscriptionStatus string  `json:"transcriptionStatus"`
	TranscriptionModel  *string `json:"transcriptionModel"`
	TranscribedAt       *string `json:"transcribedAt"`
	AudioDurationSec    *int32  `json:"audioDurationSec"`
	RemindAt            *string `json:"remindAt"`
	RemindHide          bool    `json:"remindHide" doc:"When a reminder is set: true (default) hides the capture from browse until due; false keeps it visible and only notifies (notify-only)"`
	CreatedAt           string  `json:"createdAt"`
	DeletedAt           *string `json:"deletedAt"`

	Attachments []CaptureAttachmentBody `json:"attachments" doc:"External file references. Populated only by the page listing; null elsewhere — use GET /captures/{id}/attachments for other surfaces."`
}

func toBody(c db.Capture) CaptureBody {
	b := CaptureBody{
		ID:                  c.ID.String(),
		MediaType:           string(c.MediaType),
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
	if c.TodoAt.Valid {
		s := c.TodoAt.Time.UTC().Format(time.RFC3339)
		b.TodoAt = &s
	}
	if c.DoneAt.Valid {
		s := c.DoneAt.Time.UTC().Format(time.RFC3339)
		b.DoneAt = &s
	}
	b.RemindHide = c.RemindHide
	if c.DeletedAt.Valid {
		s := c.DeletedAt.Time.UTC().Format(time.RFC3339)
		b.DeletedAt = &s
	}
	return b
}

// --- list ---

// ListOutput is the shared plain-array response for the non-paginated capture
// listings (trash, links, reminders).
type ListOutput struct {
	Body []CaptureBody
}

// --- create ---

type CaptureCreateInput struct {
	IdempotencyKey string `header:"Idempotency-Key" format:"uuid"`
	Body           struct {
		RawText      *string `json:"rawText,omitempty"`
		MediaUrl     *string `json:"mediaUrl,omitempty"`
		MediaType    string  `json:"mediaType" enum:"text,image,audio"`
		ClassifiedAs *string `json:"classifiedAs,omitempty" doc:"Deprecated and ignored. Kept so pre-todo-facet clients (queued desktop offline captures) still validate."`
		Source       string  `json:"source,omitempty" default:"web" doc:"Capture source, for example web or desktop_quick_capture"`
		RemindAt     *string `json:"remindAt,omitempty" doc:"RFC3339 time to resurface this capture"`
		RemindHide   *bool   `json:"remindHide,omitempty" doc:"With remindAt: true (default) hides until due; false is notify-only (stays visible, still notifies)"`
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
	source, err := NormalizeSource(input.Body.Source)
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
	var tag todoTag
	if input.Body.RawText != nil {
		tag = parseTodoTag(*input.Body.RawText)
	}
	todoAt, doneAt := createTodoStamps(tag, time.Now())
	var operationID uuid.UUID
	if input.IdempotencyKey != "" {
		operationID, err = uuid.Parse(input.IdempotencyKey)
		if err != nil {
			return nil, huma.Error422UnprocessableEntity("Idempotency-Key must be a UUID")
		}
		if input.Body.MediaType != "text" || input.Body.RawText == nil || input.Body.MediaUrl != nil {
			return nil, huma.Error422UnprocessableEntity("Idempotency-Key is supported only for text captures")
		}
	}

	var c db.Capture
	createdNew := true
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if operationID != uuid.Nil {
			c, err = q.CreateCaptureWithID(ctx, db.CreateCaptureWithIDParams{
				ID:      operationID,
				UserID:  uid,
				RawText: *input.Body.RawText,
				Source:  source,
				TodoAt:  todoAt,
				DoneAt:  doneAt,
			})
			if errors.Is(err, pgx.ErrNoRows) {
				createdNew = false
				c, err = q.GetCaptureAnyState(ctx, db.GetCaptureAnyStateParams{
					ID: operationID, UserID: uid,
				})
			}
		} else {
			c, err = q.CreateCapture(ctx, db.CreateCaptureParams{
				UserID:    uid,
				RawText:   nullText(input.Body.RawText),
				MediaUrl:  nullText(input.Body.MediaUrl),
				MediaType: db.CaptureMediaType(input.Body.MediaType),
				Source:    source,
				TodoAt:    todoAt,
				DoneAt:    doneAt,
			})
		}
		if err != nil {
			return err
		}
		if !createdNew {
			if !idempotentTextCaptureMatches(
				c,
				*input.Body.RawText,
				source,
				remindAt,
				remindHideDefault(input.Body.RemindHide),
			) {
				return huma.Error409Conflict("Idempotency-Key was already used with another capture")
			}
			return nil
		}
		if remindAt.Valid {
			c, err = q.SetCaptureRemind(ctx, db.SetCaptureRemindParams{
				ID:         c.ID,
				UserID:     uid,
				RemindAt:   remindAt,
				RemindHide: remindHideDefault(input.Body.RemindHide),
			})
			return err
		}
		return nil
	})
	if err != nil {
		var statusErr huma.StatusError
		if errors.As(err, &statusErr) {
			return nil, statusErr
		}
		if errors.Is(err, pgx.ErrNoRows) && operationID != uuid.Nil {
			return nil, huma.Error409Conflict("Idempotency-Key already belongs to another account")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if !createdNew {
		return &CreateOutput{Body: toBody(c)}, nil
	}
	// On create the prior link_url is always absent, so reconcile just enqueues
	// a fetch when the new text carries a URL — and re-indexes once itself.
	indexed := h.reconcileLinkFetch(ctx, c)
	if indexed {
		// Reconciliation is a second DB write (queue/clear). Return the resource as
		// it exists after the whole create operation, not the pre-enqueue row.
		c, err = h.q.GetCapture(ctx, db.GetCaptureParams{ID: c.ID, UserID: uid})
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
	}
	// Only index when there's text to embed and reconcile didn't already do it
	// (indexing twice would also run the sidecar's LLM extraction twice);
	// media-only captures get indexed once their transcript lands
	// (transcription worker), not here.
	if !indexed && input.Body.RawText != nil && strings.TrimSpace(*input.Body.RawText) != "" {
		h.rag.Index(uid.String(), c.ID.String())
	}
	return &CreateOutput{Body: toBody(c)}, nil
}

func idempotentTextCaptureMatches(
	c db.Capture,
	rawText string,
	source string,
	remindAt pgtype.Timestamptz,
	remindHide bool,
) bool {
	return !c.DeletedAt.Valid &&
		c.MediaType == db.CaptureMediaTypeText &&
		c.RawText.Valid && c.RawText.String == rawText &&
		!c.MediaUrl.Valid &&
		c.Source == source &&
		c.RemindAt.Valid == remindAt.Valid &&
		(!remindAt.Valid || c.RemindAt.Time.Equal(remindAt.Time)) &&
		c.RemindHide == remindHide
}

// reconcileLinkFetch keeps link enrichment in step with the capture text (text
// is the source of truth, like the #todo tag): the fetched page text lands in
// `transcript`, making the capture findable by the page's content, not just the
// pasted URL. `c` carries the post-write row — its raw_text is the new value and
// its link_url is the prior one (no write path touches link_url but this one).
//
//   - URL added or changed  → (re)enqueue a fetch (overwrites any old transcript)
//   - URL unchanged         → no-op, so editing surrounding words never re-fetches
//   - URL removed           → clear the link-derived transcript and re-embed
//
// Returns true when it re-indexed the capture itself (enqueue or clear
// succeeded): the caller must then skip its own reindex, or one write would
// embed — and LLM-extract — the same content twice.
//
// Best-effort: a failed enqueue/clear never fails the capture write, matching
// the RAG-indexing policy.
func (h *handler) reconcileLinkFetch(ctx context.Context, c db.Capture) bool {
	if !h.linkFetchEnabled || c.MediaType != db.CaptureMediaTypeText {
		return false
	}
	newURL := ""
	if c.RawText.Valid {
		newURL = FirstURL(c.RawText.String)
	}
	oldURL := ""
	if c.LinkUrl.Valid {
		oldURL = c.LinkUrl.String
	}
	if newURL == oldURL {
		return false
	}
	if newURL != "" {
		if err := h.q.EnqueueCaptureLinkFetch(ctx, db.EnqueueCaptureLinkFetchParams{
			ID:      c.ID,
			LinkUrl: pgtype.Text{String: newURL, Valid: true},
		}); err != nil {
			return false
		}
		// Enqueue clears any old link-derived transcript immediately; re-index
		// now so search reflects the current raw text while the new fetch runs.
		h.rag.Index(c.UserID.String(), c.ID.String())
		h.kickLinkFetch()
		return true
	}
	// URL edited out: drop the stale page text and re-embed the shorter content.
	if err := h.q.ClearCaptureLinkFetch(ctx, c.ID); err != nil {
		return false
	}
	h.rag.Index(c.UserID.String(), c.ID.String())
	return true
}

// --- update ---

type CaptureUpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		RawText    *string `json:"rawText,omitempty"`
		Transcript *string `json:"transcript,omitempty"`
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
	var tag todoTag
	if input.Body.RawText != nil {
		tag = parseTodoTag(*input.Body.RawText)
	}
	c, err := h.q.UpdateCapture(ctx, db.UpdateCaptureParams{
		ID:          id,
		UserID:      uid,
		RawText:     nullText(input.Body.RawText),
		Transcript:  nullText(input.Body.Transcript),
		TodoPresent: tag.present,
		TodoDone:    tag.done,
		DoneDate:    doneDateStamp(tag.doneDate),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	// A raw_text edit can add, change, or drop the capture's URL; keep link
	// enrichment in step. Skipped for a transcript-only patch (raw_text nil).
	// Runs before the general reindex: when it enqueues or clears it re-indexes
	// once itself (post-clear, so no stale link transcript is embedded).
	indexed := false
	if input.Body.RawText != nil {
		indexed = h.reconcileLinkFetch(ctx, c)
	}
	if indexed {
		// reconcileLinkFetch performs a second DB write. Mutation consumers cache
		// this body, so serialize the final queue/transcript state, not UpdateCapture's
		// earlier RETURNING row.
		c, err = h.q.GetCapture(ctx, db.GetCaptureParams{ID: c.ID, UserID: uid})
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
	}
	// Reindex only when the indexable text actually changed and reconcile didn't
	// already do it — an empty PATCH must not trigger embedding + extraction,
	// and a URL change must not embed + LLM-extract twice.
	if !indexed && (input.Body.RawText != nil || input.Body.Transcript != nil) {
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
	h.kickTranscription()
	return &UpdateOutput{Body: toBody(c)}, nil
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

// NormalizeSource validates and defaults the stable source identifier used by
// every Capture creation path, including archive restore.
func NormalizeSource(source string) (string, error) {
	source = strings.TrimSpace(source)
	if source == "" {
		return "web", nil
	}
	if !sourcePattern.MatchString(source) {
		return "", huma.Error422UnprocessableEntity("source must start with a lowercase letter and contain only lowercase letters, digits, _, :, or -")
	}
	return source, nil
}
