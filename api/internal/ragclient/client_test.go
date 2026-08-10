package ragclient

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRecallQueriesPostBoundedExclusionsInBody(t *testing.T) {
	t.Helper()
	type body struct {
		Query       string   `json:"query"`
		CaptureID   string   `json:"capture_id"`
		Limit       int      `json:"limit"`
		ExcludedIDs []string `json:"excluded_ids"`
	}
	var requests []body
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		var got body
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatal(err)
		}
		requests = append(requests, got)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("[]"))
	}))
	defer srv.Close()

	client := New(srv.URL)
	if _, err := client.Find(context.Background(), "user", "needle", 10, []string{"hidden"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Related(context.Background(), "user", "anchor", 5, []string{"linked"}); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 2 || requests[0].Query != "needle" ||
		requests[0].ExcludedIDs[0] != "hidden" || requests[1].CaptureID != "anchor" ||
		requests[1].ExcludedIDs[0] != "linked" {
		t.Fatalf("requests = %+v", requests)
	}
}

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

func TestIndexBatchWithoutWebhooksSuppressesRestoreSideEffects(t *testing.T) {
	t.Helper()
	var gotPath, gotUser string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotUser = r.Header.Get("X-User-Id")
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	New(srv.URL).IndexBatchWithoutWebhooks("user-123", []string{"capture-123"})
	if gotPath != "/backfill-queue" || gotUser != "user-123" {
		t.Fatalf("request = %s user=%q", gotPath, gotUser)
	}
}

func TestInvalidateDisabledIsNoop(t *testing.T) {
	var client *Client
	if err := client.Invalidate(context.Background(), "user-123"); err != nil {
		t.Fatalf("nil client should be a no-op: %v", err)
	}
}
