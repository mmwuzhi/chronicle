package middleware

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
)

type contextKey string

const (
	traceIDKey contextKey = "traceId"
	userIDKey  contextKey = "userId"
)

func TraceID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		traceID := r.Header.Get("x-request-id")
		if traceID == "" {
			b := make([]byte, 16)
			rand.Read(b)
			traceID = hex.EncodeToString(b)
		}
		ctx := context.WithValue(r.Context(), traceIDKey, traceID)
		w.Header().Set("x-request-id", traceID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func GetTraceID(ctx context.Context) string {
	if id, ok := ctx.Value(traceIDKey).(string); ok {
		return id
	}
	return ""
}

func GetUserID(ctx context.Context) string {
	if id, ok := ctx.Value(userIDKey).(string); ok {
		return id
	}
	return ""
}

func setUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}
