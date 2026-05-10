package task_test

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
	"github.com/sikaoshenmi/chronicle/internal/task"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "time_blocks", "log_entries", "tasks", "projects", "users")

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

	task.Register(api, pool, authMW)

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

// createTask is a test helper that creates a task and returns its ID.
func createTask(t *testing.T, srv *httptest.Server, token string, extras map[string]any) string {
	t.Helper()
	body := map[string]any{"title": "Test Task", "type": "task"}
	for k, v := range extras {
		body[k] = v
	}
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/tasks", token, body)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("setup: create task: got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)
	return out.ID
}

// --- create ---

func TestCreateTask_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/tasks", token, map[string]any{
		"title": "Buy groceries",
		"type":  "task",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID     string `json:"id"`
		Title  string `json:"title"`
		Type   string `json:"type"`
		Status string `json:"status"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.Title != "Buy groceries" {
		t.Fatalf("expected title 'Buy groceries', got %q", body.Title)
	}
	if body.Type != "task" {
		t.Fatalf("expected type 'task', got %q", body.Type)
	}
	if body.Status != "todo" {
		t.Fatalf("expected default status 'todo', got %q", body.Status)
	}
}

func TestCreateTask_WithDueAt(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	due := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/tasks", token, map[string]any{
		"title": "Deadline task",
		"type":  "task",
		"dueAt": due.Format(time.RFC3339),
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		DueAt *string `json:"dueAt"`
	}
	decodeBody(t, resp, &body)

	if body.DueAt == nil {
		t.Fatal("expected dueAt to be set")
	}
}

func TestCreateTask_InvalidType(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/tasks", token, map[string]any{
		"title": "Bad task",
		"type":  "invalid",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

// --- list ---

func TestListTasks_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createTask(t, srv, tokenA, nil)
	createTask(t, srv, tokenB, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body []struct {
		Title string `json:"title"`
	}
	decodeBody(t, resp, &body)

	if len(body) != 1 {
		t.Fatalf("expected 1 task, got %d", len(body))
	}
}

func TestListTasks_FilterByStatus(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createTask(t, srv, token, nil)

	// mark as done
	status := "done"
	do(t, srv.Client(), http.MethodPatch, srv.URL+"/tasks/"+id, token, map[string]*string{"status": &status}).Body.Close()

	// filter todo — should be empty
	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks?status=todo", token, nil)
	var todos []any
	decodeBody(t, resp, &todos)
	if len(todos) != 0 {
		t.Fatalf("expected 0 todo tasks, got %d", len(todos))
	}

	// filter done — should have 1
	resp2 := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks?status=done", token, nil)
	var done []any
	decodeBody(t, resp2, &done)
	if len(done) != 1 {
		t.Fatalf("expected 1 done task, got %d", len(done))
	}
}

// --- get ---

func TestGetTask_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createTask(t, srv, token, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks/"+id, token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &body)

	if body.ID != id {
		t.Fatalf("expected id %q, got %q", id, body.ID)
	}
}

func TestGetTask_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createTask(t, srv, tokenA, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks/"+id, tokenB, nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- update ---

func TestUpdateTask_ChangeStatus(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createTask(t, srv, token, nil)

	status := "in_progress"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/tasks/"+id, token, map[string]*string{
		"status": &status,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		Status string `json:"status"`
	}
	decodeBody(t, resp, &body)

	if body.Status != "in_progress" {
		t.Fatalf("expected status 'in_progress', got %q", body.Status)
	}
}

func TestUpdateTask_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createTask(t, srv, tokenA, nil)

	status := "done"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/tasks/"+id, tokenB, map[string]*string{
		"status": &status,
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- delete ---

func TestDeleteTask_SoftDelete(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createTask(t, srv, token, nil)

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/tasks/"+id, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	// get should 404 (soft deleted)
	getResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks/"+id, token, nil)
	getResp.Body.Close()

	if getResp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 after soft delete, got %d", getResp.StatusCode)
	}

	// list should be empty
	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after delete, got %d items", len(items))
	}
}

func TestDeleteTask_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createTask(t, srv, tokenA, nil)

	resp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/tasks/"+id, tokenB, nil)
	resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- auth ---

func TestTasks_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/tasks", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
