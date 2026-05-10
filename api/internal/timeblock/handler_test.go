package timeblock_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/timeblock"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "time_blocks", "tasks", "projects", "users")

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

	timeblock.Register(api, pool, authMW)

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

func createBlock(t *testing.T, srv *httptest.Server, token string, extras map[string]any) string {
	t.Helper()
	body := map[string]any{}
	for k, v := range extras {
		body[k] = v
	}
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/time-blocks", token, body)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("setup: create time block: got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)
	return out.ID
}

// --- create ---

func TestCreateTimeBlock_NoStartedAt(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	// startedAt defaults to now when omitted
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/time-blocks", token, map[string]any{})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID        string  `json:"id"`
		StartedAt string  `json:"startedAt"`
		EndedAt   *string `json:"endedAt"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.StartedAt == "" {
		t.Fatal("expected non-empty startedAt")
	}
	if body.EndedAt != nil {
		t.Fatal("expected endedAt to be null for an in-progress block")
	}
}

func TestCreateTimeBlock_WithStartedAt(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	started := time.Now().Add(-30 * time.Minute).UTC().Truncate(time.Second)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/time-blocks", token, map[string]any{
		"startedAt": started.Format(time.RFC3339),
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		StartedAt string `json:"startedAt"`
	}
	decodeBody(t, resp, &body)

	if body.StartedAt != started.Format(time.RFC3339) {
		t.Fatalf("expected startedAt %q, got %q", started.Format(time.RFC3339), body.StartedAt)
	}
}

// --- list ---

func TestListTimeBlocks_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createBlock(t, srv, tokenA, nil)
	createBlock(t, srv, tokenB, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/time-blocks", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var blocks []any
	decodeBody(t, resp, &blocks)

	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
}

// --- update (stop a block) ---

func TestUpdateTimeBlock_Stop(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createBlock(t, srv, token, nil)

	endedAt := time.Now().UTC().Truncate(time.Second)
	var durSec int32 = 1800

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/time-blocks/"+id, token, map[string]any{
		"endedAt":     endedAt.Format(time.RFC3339),
		"durationSec": durSec,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		EndedAt     *string `json:"endedAt"`
		DurationSec *int32  `json:"durationSec"`
	}
	decodeBody(t, resp, &body)

	if body.EndedAt == nil {
		t.Fatal("expected endedAt to be set after stop")
	}
	if body.DurationSec == nil || *body.DurationSec != durSec {
		t.Fatalf("expected durationSec %d, got %v", durSec, body.DurationSec)
	}
}

func TestUpdateTimeBlock_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createBlock(t, srv, tokenA, nil)

	endedAt := time.Now().UTC().Truncate(time.Second)
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/time-blocks/"+id, tokenB, map[string]any{
		"endedAt": endedAt.Format(time.RFC3339),
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- delete ---

func TestDeleteTimeBlock_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createBlock(t, srv, token, nil)

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/time-blocks/"+id, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/time-blocks", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after delete, got %d items", len(items))
	}
}

func TestDeleteTimeBlock_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createBlock(t, srv, tokenA, nil)

	resp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/time-blocks/"+id, tokenB, nil)
	resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- auth ---

func TestTimeBlocks_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/time-blocks", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
