package ragclient

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
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

func TestIndexBatchWithoutWebhooksSuppressesRestoreSideEffects(t *testing.T) {
	t.Helper()
	type indexBody struct {
		CaptureID    string `json:"capture_id"`
		FireWebhooks bool   `json:"fire_webhooks"`
	}
	received := make(chan indexBody, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body indexBody
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode body: %v", err)
		}
		received <- body
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	New(srv.URL).IndexBatchWithoutWebhooks("user-123", []string{"capture-123"})
	select {
	case body := <-received:
		if body.CaptureID != "capture-123" || body.FireWebhooks {
			t.Fatalf("index body = %+v", body)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for restore index request")
	}
}

func TestInvalidateDisabledIsNoop(t *testing.T) {
	var client *Client
	if err := client.Invalidate(context.Background(), "user-123"); err != nil {
		t.Fatalf("nil client should be a no-op: %v", err)
	}
}
