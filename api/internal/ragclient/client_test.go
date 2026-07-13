package ragclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestInvalidateCallsScopedSidecarEndpoint(t *testing.T) {
	t.Helper()
	var gotMethod, gotPath, gotUser string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotUser = r.Header.Get("X-User-Id")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := New(srv.URL).Invalidate(context.Background(), "user-123"); err != nil {
		t.Fatalf("Invalidate: %v", err)
	}
	if gotMethod != http.MethodPost || gotPath != "/invalidate" || gotUser != "user-123" {
		t.Fatalf("request = %s %s user=%q", gotMethod, gotPath, gotUser)
	}
}

func TestInvalidateDisabledIsNoop(t *testing.T) {
	var client *Client
	if err := client.Invalidate(context.Background(), "user-123"); err != nil {
		t.Fatalf("nil client should be a no-op: %v", err)
	}
}
