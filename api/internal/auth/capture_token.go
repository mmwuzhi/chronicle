package auth

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

// Capture tokens are long-lived, revocable, create-only credentials for headless
// quick-capture clients (e.g. the iOS Action Button shortcut). Minting requires a
// real signed-in session — these routes sit behind the JWT authMW — and the raw
// token is returned exactly once. See ValidateTokenOrPAT and capture.Register for
// how the token is scoped to POST /captures only.

type CaptureTokenCreateInput struct {
	Body struct {
		Name string `json:"name" minLength:"1" maxLength:"100" doc:"Label to recognize this token, e.g. 'iPhone Action Button'"`
	}
}

type CaptureTokenCreateOutput struct {
	Body struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Token string `json:"token" doc:"The raw token, shown only once. Copy it now — it cannot be retrieved again."`
	}
}

func (h *handler) createCaptureToken(ctx context.Context, input *CaptureTokenCreateInput) (*CaptureTokenCreateOutput, error) {
	traceID := middleware.GetTraceID(ctx)
	uid, err := uuid.Parse(middleware.GetUserID(ctx))
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	name := strings.TrimSpace(input.Body.Name)
	if name == "" {
		return nil, huma.Error422UnprocessableEntity("name is required")
	}

	raw, hashed, err := NewCaptureToken()
	if err != nil {
		slog.ErrorContext(ctx, "failed to generate capture token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	tok, err := h.q.CreateCaptureToken(ctx, db.CreateCaptureTokenParams{
		UserID:    uid,
		TokenHash: hashed,
		Name:      name,
	})
	if err != nil {
		slog.ErrorContext(ctx, "failed to store capture token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &CaptureTokenCreateOutput{}
	out.Body.ID = tok.ID.String()
	out.Body.Name = tok.Name
	out.Body.Token = raw
	return out, nil
}

type CaptureTokenListInput struct{}

type captureTokenSummary struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	CreatedAt  string  `json:"createdAt"`
	LastUsedAt *string `json:"lastUsedAt,omitempty"`
}

type CaptureTokenListOutput struct {
	Body struct {
		Tokens []captureTokenSummary `json:"tokens"`
	}
}

func (h *handler) listCaptureTokens(ctx context.Context, _ *CaptureTokenListInput) (*CaptureTokenListOutput, error) {
	traceID := middleware.GetTraceID(ctx)
	uid, err := uuid.Parse(middleware.GetUserID(ctx))
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	rows, err := h.q.ListCaptureTokensByUser(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to list capture tokens", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &CaptureTokenListOutput{}
	out.Body.Tokens = make([]captureTokenSummary, len(rows))
	for i, r := range rows {
		s := captureTokenSummary{
			ID:        r.ID.String(),
			Name:      r.Name,
			CreatedAt: r.CreatedAt.Time.UTC().Format(time.RFC3339),
		}
		if r.LastUsedAt.Valid {
			t := r.LastUsedAt.Time.UTC().Format(time.RFC3339)
			s.LastUsedAt = &t
		}
		out.Body.Tokens[i] = s
	}
	return out, nil
}

type CaptureTokenDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) revokeCaptureToken(ctx context.Context, input *CaptureTokenDeleteInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)
	uid, err := uuid.Parse(middleware.GetUserID(ctx))
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}

	// Soft semantics: revoke flips the flag (queries filter revoked=false); the
	// row stays for audit. user_id in the WHERE clause prevents revoking another
	// user's token. A no-op (already gone/revoked) is success — idempotent.
	if err := h.q.RevokeCaptureToken(ctx, db.RevokeCaptureTokenParams{ID: id, UserID: uid}); err != nil {
		slog.ErrorContext(ctx, "failed to revoke capture token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &struct{}{}, nil
}
