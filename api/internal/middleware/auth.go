package middleware

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/danielgtaylor/huma/v2"
)

// TokenValidator extracts a user ID from a raw JWT string.
// Defined here so callers (main.go) can compose it without importing auth.
type TokenValidator func(raw string) (userID string, err error)

// RequireAuthHuma returns a huma middleware that validates the JWT from the
// Authorization header or access_token cookie, and injects the user ID into
// the Go context so handlers can retrieve it via GetUserID.
func RequireAuthHuma(validate TokenValidator) func(huma.Context, func(huma.Context)) {
	return func(ctx huma.Context, next func(huma.Context)) {
		raw := tokenFromHumaCtx(ctx)
		if raw == "" {
			writeHumaUnauthorized(ctx)
			return
		}
		userID, err := validate(raw)
		if err != nil {
			writeHumaUnauthorized(ctx)
			return
		}
		next(huma.WithValue(ctx, userIDKey, userID))
	}
}

func tokenFromHumaCtx(ctx huma.Context) string {
	if h := ctx.Header("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	if c, err := huma.ReadCookie(ctx, "access_token"); err == nil {
		return c.Value
	}
	return ""
}

func writeHumaUnauthorized(ctx huma.Context) {
	ctx.SetStatus(http.StatusUnauthorized)
	ctx.SetHeader("Content-Type", "application/json")
	b, _ := json.Marshal(map[string]any{"status": http.StatusUnauthorized, "title": "Unauthorized"})
	_, _ = ctx.BodyWriter().Write(b)
}

// SetUserID stores the user ID in a standard context (for use outside huma middleware).
func SetUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}
