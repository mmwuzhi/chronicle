// Package webhook is the CRUD surface for capture webhooks. Go owns the rules
// table; the ragsvc sidecar owns matching + delivery (it has the embeddings).
// This is workflow automation, normally avoided per the product guardrails;
// present at explicit user request.
package webhook

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
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

func Register(api huma.API, pool *pgxpool.Pool, rag *ragclient.Client, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool), rag: rag}

	op := func(id, method, path, summary string) huma.Operation {
		return huma.Operation{
			OperationID: id,
			Method:      method,
			Path:        path,
			Summary:     summary,
			Tags:        []string{"webhooks"},
			Middlewares: huma.Middlewares{authMW},
		}
	}

	huma.Register(api, op("list-webhooks", http.MethodGet, "/webhooks", "List capture webhooks"), h.list)
	huma.Register(api, op("create-webhook", http.MethodPost, "/webhooks", "Create a capture webhook"), h.create)
	huma.Register(api, op("get-webhook", http.MethodGet, "/webhooks/{id}", "Get a capture webhook"), h.get)
	huma.Register(api, op("update-webhook", http.MethodPatch, "/webhooks/{id}", "Update a capture webhook"), h.update)
	huma.Register(api, op("delete-webhook", http.MethodDelete, "/webhooks/{id}", "Delete a capture webhook"), h.delete)
	huma.Register(api, op("test-webhook", http.MethodPost, "/webhooks/{id}/test", "Score a webhook against a capture"), h.test)
}

// --- types ---

type WebhookBody struct {
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	TargetURL         string   `json:"targetUrl"`
	Keywords          []string `json:"keywords"`
	SemanticQuery     *string  `json:"semanticQuery"`
	SemanticThreshold float64  `json:"semanticThreshold"`
	PayloadTemplate   string   `json:"payloadTemplate"`
	Enabled           bool     `json:"enabled"`
	CreatedAt         string   `json:"createdAt"`
}

func toBody(w db.CaptureWebhook) WebhookBody {
	b := WebhookBody{
		ID:                w.ID.String(),
		Name:              w.Name,
		TargetURL:         w.TargetUrl,
		Keywords:          w.Keywords,
		SemanticThreshold: w.SemanticThreshold,
		PayloadTemplate:   w.PayloadTemplate,
		Enabled:           w.Enabled,
		CreatedAt:         w.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if w.SemanticQuery.Valid {
		b.SemanticQuery = &w.SemanticQuery.String
	}
	return b
}

// WebhookFields is the shared writable body of create/update.
type WebhookFields struct {
	Name              string   `json:"name" minLength:"1" maxLength:"120"`
	TargetURL         string   `json:"targetUrl" format:"uri"`
	Keywords          []string `json:"keywords,omitempty"`
	SemanticQuery     *string  `json:"semanticQuery,omitempty"`
	SemanticThreshold *float64 `json:"semanticThreshold,omitempty" minimum:"0" maximum:"1"`
	PayloadTemplate   string   `json:"payloadTemplate" minLength:"1"`
	Enabled           *bool    `json:"enabled,omitempty"`
}

type WebhookOutput struct {
	Body WebhookBody
}

// --- list ---

type WebhookListInput struct{}

type WebhookListOutput struct {
	Body []WebhookBody
}

func (h *handler) list(ctx context.Context, _ *WebhookListInput) (*WebhookListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := h.q.ListWebhooks(ctx, uid)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	out := &WebhookListOutput{Body: make([]WebhookBody, len(rows))}
	for i, w := range rows {
		out.Body[i] = toBody(w)
	}
	return out, nil
}

// --- create ---

type WebhookCreateInput struct {
	Body WebhookFields
}

func (h *handler) create(ctx context.Context, input *WebhookCreateInput) (*WebhookOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	if err := validateWebhookURL(input.Body.TargetURL); err != nil {
		return nil, err
	}
	if (input.Body.Enabled == nil || *input.Body.Enabled) && !h.rag.Enabled() {
		return nil, huma.Error503ServiceUnavailable("webhook delivery requires the RAG sidecar")
	}
	w, err := h.q.CreateWebhook(ctx, db.CreateWebhookParams{
		UserID:            uid,
		Name:              input.Body.Name,
		TargetUrl:         input.Body.TargetURL,
		Keywords:          normalizeKeywords(input.Body.Keywords),
		SemanticQuery:     nullText(input.Body.SemanticQuery),
		SemanticThreshold: thresholdOrDefault(input.Body.SemanticThreshold),
		PayloadTemplate:   input.Body.PayloadTemplate,
		Enabled:           input.Body.Enabled == nil || *input.Body.Enabled,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &WebhookOutput{Body: toBody(w)}, nil
}

// --- get ---

type WebhookGetInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) get(ctx context.Context, input *WebhookGetInput) (*WebhookOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	w, err := h.q.GetWebhook(ctx, db.GetWebhookParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("webhook not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &WebhookOutput{Body: toBody(w)}, nil
}

// --- update ---

type WebhookUpdateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body WebhookFields
}

func (h *handler) update(ctx context.Context, input *WebhookUpdateInput) (*WebhookOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if err := validateWebhookURL(input.Body.TargetURL); err != nil {
		return nil, err
	}
	if (input.Body.Enabled == nil || *input.Body.Enabled) && !h.rag.Enabled() {
		return nil, huma.Error503ServiceUnavailable("webhook delivery requires the RAG sidecar")
	}
	w, err := h.q.UpdateWebhook(ctx, db.UpdateWebhookParams{
		ID:                id,
		UserID:            uid,
		Name:              input.Body.Name,
		TargetUrl:         input.Body.TargetURL,
		Keywords:          normalizeKeywords(input.Body.Keywords),
		SemanticQuery:     nullText(input.Body.SemanticQuery),
		SemanticThreshold: thresholdOrDefault(input.Body.SemanticThreshold),
		PayloadTemplate:   input.Body.PayloadTemplate,
		Enabled:           input.Body.Enabled == nil || *input.Body.Enabled,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("webhook not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &WebhookOutput{Body: toBody(w)}, nil
}

// --- delete ---

type WebhookDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) delete(ctx context.Context, input *WebhookDeleteInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err := h.q.SoftDeleteWebhook(ctx, db.SoftDeleteWebhookParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("webhook not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

// --- test (score against a capture, no delivery) ---

type WebhookTestInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		CaptureID string `json:"captureId" format:"uuid"`
	}
}

type WebhookTestOutput struct {
	Body struct {
		Matched bool     `json:"matched"`
		Score   *float64 `json:"score"`
	}
}

func (h *handler) test(ctx context.Context, input *WebhookTestInput) (*WebhookTestOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	rule, err := h.q.GetWebhook(ctx, db.GetWebhookParams{ID: id, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("webhook not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if !h.rag.Enabled() {
		return nil, huma.Error503ServiceUnavailable("scoring requires the RAG sidecar")
	}
	body := map[string]any{
		"capture_id":         input.Body.CaptureID,
		"keywords":           rule.Keywords,
		"semantic_threshold": rule.SemanticThreshold,
	}
	if rule.SemanticQuery.Valid {
		body["semantic_query"] = rule.SemanticQuery.String
	}
	res, err := h.rag.WebhookTest(ctx, uid.String(), body)
	if err != nil {
		return nil, huma.Error502BadGateway("could not score webhook")
	}
	out := &WebhookTestOutput{}
	out.Body.Matched = res.Matched
	out.Body.Score = res.Score
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

// normalizeKeywords trims each keyword and drops empties. An empty keyword must
// never reach the sidecar: its match check is `any(k in content for k in keywords)`,
// and in Python `"" in anything` is always true, which would fire the webhook on
// every capture. The UI filters this, but an API client could still send `[""]`.
func normalizeKeywords(k []string) []string {
	out := make([]string, 0, len(k))
	for _, kw := range k {
		if trimmed := strings.TrimSpace(kw); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func thresholdOrDefault(t *float64) float64 {
	if t == nil {
		return 0.6
	}
	return *t
}

// validateWebhookURL is a first-line SSRF guard: the sidecar will POST to this
// URL when a capture matches, so require transport encryption and reject literal
// private/loopback/link-local destinations (including the cloud metadata IP).
// Domain names that resolve to private addresses are not caught here — deeper
// resolve-time defense belongs at the sidecar's delivery point if needed.
func validateWebhookURL(raw string) error {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return huma.Error422UnprocessableEntity("target URL must be an absolute https URL")
	}
	if u.Scheme != "https" {
		return huma.Error422UnprocessableEntity("target URL must use https")
	}
	host := strings.ToLower(u.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return huma.Error422UnprocessableEntity("target URL must not point at localhost")
	}
	if ip := net.ParseIP(u.Hostname()); ip != nil && isDisallowedIP(ip) {
		return huma.Error422UnprocessableEntity("target URL must not point at a private or loopback address")
	}
	return nil
}

func isDisallowedIP(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() ||
		ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast()
}
