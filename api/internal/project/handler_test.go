package project_test

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
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/project"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "projects", "tasks", "users")

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

	project.Register(api, pool, authMW)

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

// --- create ---

func TestCreateProject_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", token, map[string]string{
		"name":  "My Project",
		"color": "#6366f1",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.Name != "My Project" {
		t.Fatalf("expected name 'My Project', got %q", body.Name)
	}
	if body.Color == "" {
		t.Fatal("expected non-empty color (default)")
	}
}

func TestCreateProject_EmptyName(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", token, map[string]string{
		"name": "",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

// --- list ---

func TestListProjects_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", tokenA, map[string]string{"name": "Alice's Project", "color": "#6366f1"}).Body.Close()
	do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", tokenB, map[string]string{"name": "Bob's Project", "color": "#6366f1"}).Body.Close()

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/projects", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body []struct {
		Name string `json:"name"`
	}
	decodeBody(t, resp, &body)

	if len(body) != 1 {
		t.Fatalf("expected 1 project, got %d", len(body))
	}
	if body[0].Name != "Alice's Project" {
		t.Fatalf("expected Alice's Project, got %q", body[0].Name)
	}
}

// --- update ---

func TestUpdateProject_Rename(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", token, map[string]string{"name": "Old Name", "color": "#6366f1"})
	var created struct {
		ID string `json:"id"`
	}
	decodeBody(t, createResp, &created)

	newName := "New Name"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/projects/"+created.ID, token, map[string]*string{"name": &newName})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		Name string `json:"name"`
	}
	decodeBody(t, resp, &body)

	if body.Name != "New Name" {
		t.Fatalf("expected 'New Name', got %q", body.Name)
	}
}

func TestUpdateProject_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", tokenA, map[string]string{"name": "Alice's", "color": "#6366f1"})
	var created struct {
		ID string `json:"id"`
	}
	decodeBody(t, createResp, &created)

	newName := "Stolen"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/projects/"+created.ID, tokenB, map[string]*string{"name": &newName})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- delete ---

func TestDeleteProject_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", token, map[string]string{"name": "To Delete", "color": "#6366f1"})
	var created struct {
		ID string `json:"id"`
	}
	decodeBody(t, createResp, &created)

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/projects/"+created.ID, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/projects", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after delete, got %d items", len(items))
	}
}

func TestDeleteProject_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createResp := do(t, srv.Client(), http.MethodPost, srv.URL+"/projects", tokenA, map[string]string{"name": "Alice's", "color": "#6366f1"})
	var created struct {
		ID string `json:"id"`
	}
	decodeBody(t, createResp, &created)

	resp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/projects/"+created.ID, tokenB, nil)
	resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- auth ---

func TestProjects_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/projects", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
