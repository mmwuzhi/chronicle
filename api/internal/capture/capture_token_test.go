package capture_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/auth"
)

// mintCaptureToken inserts a capture_token row for userID and returns the raw
// bearer value, mirroring how POST /auth/tokens stores only the hash.
func mintCaptureToken(t *testing.T, pool *pgxpool.Pool, userID string) string {
	t.Helper()
	raw, hashed, err := auth.NewCaptureToken()
	if err != nil {
		t.Fatalf("new capture token: %v", err)
	}
	uid, err := uuid.Parse(userID)
	if err != nil {
		t.Fatalf("parse user id: %v", err)
	}
	if _, err := pool.Exec(context.Background(),
		"INSERT INTO capture_tokens (user_id, token_hash, name) VALUES ($1, $2, $3)",
		uid, hashed, "test token",
	); err != nil {
		t.Fatalf("insert capture token: %v", err)
	}
	return raw
}

func TestCaptureToken_CanCreateCapture(t *testing.T) {
	srv, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	capToken := mintCaptureToken(t, pool, userID)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", capToken, map[string]any{
		"mediaType": "text",
		"rawText":   "captured from the iOS action button",
		"source":    "ios_action_button",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID     string `json:"id"`
		Source string `json:"source"`
	}
	decodeBody(t, resp, &body)
	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.Source != "ios_action_button" {
		t.Fatalf("expected source 'ios_action_button', got %q", body.Source)
	}
}

func TestCaptureToken_ForgedRejected(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", "chr_cap_deadbeefdeadbeef", map[string]any{
		"mediaType": "text",
		"rawText":   "should not be saved",
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for forged token, got %d", resp.StatusCode)
	}
}

func TestCaptureToken_RevokedRejected(t *testing.T) {
	srv, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	capToken := mintCaptureToken(t, pool, userID)

	if _, err := pool.Exec(context.Background(),
		"UPDATE capture_tokens SET revoked = true WHERE token_hash = $1", auth.HashToken(capToken),
	); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", capToken, map[string]any{
		"mediaType": "text",
		"rawText":   "after revoke",
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 after revoke, got %d", resp.StatusCode)
	}
}

// create-only scope: a capture token must not unlock read or delete routes,
// which stay JWT-only. These two guard the security boundary.
func TestCaptureToken_CannotListCaptures(t *testing.T) {
	srv, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	capToken := mintCaptureToken(t, pool, userID)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", capToken, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 listing with capture token, got %d", resp.StatusCode)
	}
}

func TestCaptureToken_CannotDeleteCapture(t *testing.T) {
	srv, pool := newServer(t)
	userID, jwtToken := createTestUser(t, pool)
	capToken := mintCaptureToken(t, pool, userID)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", jwtToken, map[string]any{
		"mediaType": "text",
		"rawText":   "delete me",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("setup create: got %d", resp.StatusCode)
	}
	var created struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &created)

	resp = do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+created.ID, capToken, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 deleting with capture token, got %d", resp.StatusCode)
	}
}

func TestCaptureToken_CannotListAttachments(t *testing.T) {
	srv, pool := newServer(t)
	userID, jwtToken := createTestUser(t, pool)
	capToken := mintCaptureToken(t, pool, userID)
	id := createCapture(t, srv, jwtToken, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id+"/attachments", capToken, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 listing attachments with capture token, got %d", resp.StatusCode)
	}
}
