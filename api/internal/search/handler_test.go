package search_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/search"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newSearchServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "time_blocks", "log_entries", "tasks", "projects", "users")

	router := chi.NewRouter()
	api := humachi.New(router, huma.DefaultConfig("Test", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	authMW := middleware.RequireAuthHuma(func(raw string) (string, error) {
		token, err := jwt.Parse(raw, func(_ *jwt.Token) (any, error) {
			return []byte(testutil.TestJWTSecret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !token.Valid {
			return "", fmt.Errorf("invalid token")
		}
		subject, _ := token.Claims.GetSubject()
		return subject, nil
	})
	search.Register(api, pool, authMW)

	server := httptest.NewServer(router)
	t.Cleanup(server.Close)
	return server, pool
}

func createSearchUser(t *testing.T, pool *pgxpool.Pool) (uuid.UUID, string) {
	t.Helper()
	id := uuid.New()
	_, err := pool.Exec(context.Background(),
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		id, id.String()+"@test.com",
	)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	return id, testutil.MakeToken(t, id.String())
}

func searchRequest(t *testing.T, server *httptest.Server, token, query string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, server.URL+"/search?q="+url.QueryEscape(query), bytes.NewReader(nil))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatalf("search request: %v", err)
	}
	return response
}

func decodeSearch(t *testing.T, response *http.Response, target any) {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, body)
	}
	if err := json.NewDecoder(response.Body).Decode(target); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func TestSearchFindsTranscriptAndMultilingualSubstrings(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	captureID := uuid.New()
	_, err := pool.Exec(context.Background(), `
		INSERT INTO captures (
			id, user_id, raw_text, transcript, media_type, classified_as, source,
			transcription_status
		) VALUES ($1, $2, 'voice note', '東京で設計会議をした', 'audio', 'unclassified',
			'web', 'completed')`,
		captureID, userID,
	)
	if err != nil {
		t.Fatalf("insert capture: %v", err)
	}

	response := searchRequest(t, server, token, "設計会議")
	var body struct {
		Captures []struct {
			ID           string `json:"id"`
			MatchedField string `json:"matchedField"`
			Preview      string `json:"preview"`
		} `json:"captures"`
	}
	decodeSearch(t, response, &body)
	if len(body.Captures) != 1 || body.Captures[0].ID != captureID.String() {
		t.Fatalf("unexpected captures: %+v", body.Captures)
	}
	if body.Captures[0].MatchedField != "transcript" || body.Captures[0].Preview == "" {
		t.Fatalf("unexpected transcript match: %+v", body.Captures[0])
	}
}

func TestSearchUsesFullTextForSeparatedEnglishTerms(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	taskID := uuid.New()
	_, err := pool.Exec(context.Background(), `
		INSERT INTO tasks (id, user_id, title, type, status)
		VALUES ($1, $2, 'alpha planning notes for beta launch', 'task', 'todo')`,
		taskID, userID,
	)
	if err != nil {
		t.Fatalf("insert task: %v", err)
	}

	response := searchRequest(t, server, token, "alpha beta")
	var body struct {
		Tasks []struct {
			ID string `json:"id"`
		} `json:"tasks"`
	}
	decodeSearch(t, response, &body)
	if len(body.Tasks) != 1 || body.Tasks[0].ID != taskID.String() {
		t.Fatalf("unexpected tasks: %+v", body.Tasks)
	}
}

func TestSearchExcludesSoftDeletedAndOtherUsersData(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	otherUserID, _ := createSearchUser(t, pool)
	for _, row := range []struct {
		userID  uuid.UUID
		deleted bool
	}{
		{userID: userID, deleted: true},
		{userID: otherUserID, deleted: false},
	} {
		deletedAt := "NULL"
		if row.deleted {
			deletedAt = "now()"
		}
		query := fmt.Sprintf(`
			INSERT INTO log_entries (user_id, body, deleted_at)
			VALUES ($1, 'private recall phrase', %s)`, deletedAt)
		if _, err := pool.Exec(context.Background(), query, row.userID); err != nil {
			t.Fatalf("insert log entry: %v", err)
		}
	}

	response := searchRequest(t, server, token, "private recall")
	var body struct {
		LogEntries []any `json:"logEntries"`
	}
	decodeSearch(t, response, &body)
	if len(body.LogEntries) != 0 {
		t.Fatalf("expected no visible log entries, got %d", len(body.LogEntries))
	}
}

func TestSearchRejectsWhitespaceOnlyQuery(t *testing.T) {
	server, pool := newSearchServer(t)
	_, token := createSearchUser(t, pool)

	response := searchRequest(t, server, token, "   ")
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", response.StatusCode)
	}
}
