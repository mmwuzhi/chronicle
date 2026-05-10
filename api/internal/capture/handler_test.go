package capture_test

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
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "tasks", "projects", "users")

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

	capture.Register(api, pool, authMW)

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

func createCapture(t *testing.T, srv *httptest.Server, token string, extras map[string]any) string {
	t.Helper()
	body := map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "test capture",
	}
	for k, v := range extras {
		body[k] = v
	}
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, body)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("setup: create capture: got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)
	return out.ID
}

// --- create ---

func TestCreateCapture_TextHappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "idea",
		"rawText":      "Build a time-lapse camera from a Raspberry Pi",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID           string  `json:"id"`
		RawText      *string `json:"rawText"`
		MediaType    string  `json:"mediaType"`
		ClassifiedAs string  `json:"classifiedAs"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.RawText == nil || *body.RawText != "Build a time-lapse camera from a Raspberry Pi" {
		t.Fatalf("unexpected rawText: %v", body.RawText)
	}
	if body.MediaType != "text" {
		t.Fatalf("expected mediaType 'text', got %q", body.MediaType)
	}
	if body.ClassifiedAs != "idea" {
		t.Fatalf("expected classifiedAs 'idea', got %q", body.ClassifiedAs)
	}
}

func TestCreateCapture_InvalidMediaType(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "video",
		"classifiedAs": "unclassified",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

// --- list ---

func TestListCaptures_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createCapture(t, srv, tokenA, nil)
	createCapture(t, srv, tokenB, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var captures []any
	decodeBody(t, resp, &captures)

	if len(captures) != 1 {
		t.Fatalf("expected 1 capture, got %d", len(captures))
	}
}

func TestListCaptures_FilterByClassifiedAs(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createCapture(t, srv, token, map[string]any{"classifiedAs": "idea"})
	createCapture(t, srv, token, map[string]any{"classifiedAs": "task"})

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures?classifiedAs=idea", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var captures []struct {
		ClassifiedAs string `json:"classifiedAs"`
	}
	decodeBody(t, resp, &captures)

	if len(captures) != 1 {
		t.Fatalf("expected 1 idea capture, got %d", len(captures))
	}
	if captures[0].ClassifiedAs != "idea" {
		t.Fatalf("expected classifiedAs 'idea', got %q", captures[0].ClassifiedAs)
	}
}

// --- update ---

func TestUpdateCapture_Reclassify(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createCapture(t, srv, token, map[string]any{"classifiedAs": "unclassified"})

	newClass := "task"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token, map[string]*string{
		"classifiedAs": &newClass,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ClassifiedAs string `json:"classifiedAs"`
	}
	decodeBody(t, resp, &body)

	if body.ClassifiedAs != "task" {
		t.Fatalf("expected 'task', got %q", body.ClassifiedAs)
	}
}

func TestUpdateCapture_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createCapture(t, srv, tokenA, nil)

	newClass := "task"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, tokenB, map[string]*string{
		"classifiedAs": &newClass,
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- delete ---

func TestDeleteCapture_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createCapture(t, srv, token, nil)

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after delete, got %d items", len(items))
	}
}

// --- auth ---

func TestCaptures_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
