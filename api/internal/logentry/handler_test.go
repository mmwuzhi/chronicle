package logentry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/logentry"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "log_entries", "time_blocks", "tasks", "projects", "users")

	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)

	authMW := middleware.RequireAuthHuma(func(raw string) (string, error) {
		tok, err := jwt.Parse(raw, func(_ *jwt.Token) (any, error) {
			return []byte(testutil.TestJWTSecret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !tok.Valid {
			return "", fmt.Errorf("invalid token")
		}
		sub, _ := tok.Claims.GetSubject()
		return sub, nil
	})

	logentry.Register(api, pool, authMW)

	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, pool
}

func createTestUser(t *testing.T, pool *pgxpool.Pool) (userID, token string) {
	t.Helper()
	uid := uuid.New()
	_, err := pool.Exec(context.Background(),
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)",
		uid, fmt.Sprintf("%s@test.com", uid), "testhash",
	)
	if err != nil {
		t.Fatalf("create test user: %v", err)
	}
	return uid.String(), testutil.MakeToken(t, uid.String())
}

func do(t *testing.T, client *http.Client, method, url, token string, body any) *http.Response {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, r)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	return resp
}

func decodeBody(t *testing.T, resp *http.Response, dst any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func createEntry(t *testing.T, srv *httptest.Server, token, body string) string {
	t.Helper()
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]string{"body": body})
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("setup: create log entry: got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)
	return out.ID
}

// --- create ---

func TestCreateLogEntry_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]string{
		"body": "Today I shipped the auth feature.",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID   string `json:"id"`
		Body string `json:"body"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.Body != "Today I shipped the auth feature." {
		t.Fatalf("unexpected body: %q", body.Body)
	}
}

func TestCreateLogEntry_EmptyBody(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]string{
		"body": "",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

func TestCreateLogEntry_TimeOnly(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]any{
		"time": map[string]any{
			"inputMode":   "duration",
			"durationSec": 1500,
		},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		Body string `json:"body"`
		Time struct {
			ID          string `json:"id"`
			DurationSec int32  `json:"durationSec"`
			InputMode   string `json:"inputMode"`
		} `json:"time"`
	}
	decodeBody(t, resp, &body)
	if body.Body != "" || body.Time.ID == "" {
		t.Fatalf("expected time-only entry, got body=%q time=%+v", body.Body, body.Time)
	}
	if body.Time.DurationSec != 1500 || body.Time.InputMode != "duration" {
		t.Fatalf("unexpected time block: %+v", body.Time)
	}

	var count int
	if err := pool.QueryRow(context.Background(),
		"SELECT count(*) FROM time_blocks WHERE user_id = $1 AND deleted_at IS NULL",
		userID,
	).Scan(&count); err != nil {
		t.Fatalf("count time blocks: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected one active time block, got %d", count)
	}
}

func TestCreateLogEntry_RangeDurationCannotExceedRange(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	startedAt := "2026-06-06T08:00:00Z"
	endedAt := "2026-06-06T08:30:00Z"

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]any{
		"time": map[string]any{
			"inputMode":   "range",
			"startedAt":   startedAt,
			"endedAt":     endedAt,
			"durationSec": 3600,
		},
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

// --- list ---

func TestListLogEntries_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createEntry(t, srv, tokenA, "Alice's log")
	createEntry(t, srv, tokenB, "Bob's log")

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/log-entries", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var entries []struct {
		Body string `json:"body"`
	}
	decodeBody(t, resp, &entries)

	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Body != "Alice's log" {
		t.Fatalf("expected Alice's log, got %q", entries[0].Body)
	}
}

// --- update ---

func TestUpdateLogEntry_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createEntry(t, srv, token, "original text")

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/log-entries/"+id, token, map[string]string{
		"body": "updated text",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		Body string `json:"body"`
	}
	decodeBody(t, resp, &body)

	if body.Body != "updated text" {
		t.Fatalf("expected 'updated text', got %q", body.Body)
	}
}

func TestUpdateLogEntry_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createEntry(t, srv, tokenA, "Alice's log")

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/log-entries/"+id, tokenB, map[string]string{
		"body": "tampered",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

func TestUpdateLogEntry_RemoveTimeKeepsLog(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]any{
		"body": "reviewed the release",
		"time": map[string]any{
			"inputMode":   "duration",
			"durationSec": 900,
		},
	})
	var created struct {
		ID   string `json:"id"`
		Time struct {
			ID string `json:"id"`
		} `json:"time"`
	}
	decodeBody(t, createResp, &created)

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/log-entries/"+created.ID, token, map[string]any{
		"removeTime": true,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var updated struct {
		Body string `json:"body"`
		Time any    `json:"time"`
	}
	decodeBody(t, resp, &updated)
	if updated.Body != "reviewed the release" || updated.Time != nil {
		t.Fatalf("expected body without time, got %+v", updated)
	}

	var deletedAt *string
	if err := pool.QueryRow(context.Background(),
		"SELECT deleted_at::text FROM time_blocks WHERE id = $1",
		created.Time.ID,
	).Scan(&deletedAt); err != nil {
		t.Fatalf("read time block: %v", err)
	}
	if deletedAt == nil {
		t.Fatal("expected removed time block to be soft deleted")
	}
}

// --- delete ---

func TestDeleteLogEntry_SoftDelete(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createEntry(t, srv, token, "to be deleted")

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/log-entries/"+id, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/log-entries", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after soft delete, got %d items", len(items))
	}
}

func TestDeleteLogEntry_SoftDeletesLinkedTime(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/log-entries", token, map[string]any{
		"time": map[string]any{
			"inputMode":   "duration",
			"durationSec": 600,
		},
	})
	var created struct {
		ID   string `json:"id"`
		Time struct {
			ID string `json:"id"`
		} `json:"time"`
	}
	decodeBody(t, createResp, &created)

	resp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/log-entries/"+created.ID, token, nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", resp.StatusCode)
	}

	var logDeletedAt, timeDeletedAt *string
	if err := pool.QueryRow(context.Background(),
		`SELECT l.deleted_at::text, t.deleted_at::text
		 FROM log_entries l
		 JOIN time_blocks t ON t.id = l.time_block_id
		 WHERE l.id = $1`,
		created.ID,
	).Scan(&logDeletedAt, &timeDeletedAt); err != nil {
		t.Fatalf("read deleted records: %v", err)
	}
	if logDeletedAt == nil || timeDeletedAt == nil {
		t.Fatalf("expected both records soft deleted, got log=%v time=%v", logDeletedAt, timeDeletedAt)
	}
}

func TestDeleteLogEntry_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createEntry(t, srv, tokenA, "Alice's log")

	resp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/log-entries/"+id, tokenB, nil)
	resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- auth ---

func TestLogEntries_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/log-entries", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
