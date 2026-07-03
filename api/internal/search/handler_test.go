package search_test

import (
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
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
	"github.com/sikaoshenmi/chronicle/internal/search"
	"github.com/sikaoshenmi/chronicle/testutil"
)

// The RAG sidecar is disabled here (ragclient.New("")), so /find exercises the
// keyword FTS fallback over captures — which is what must keep working when the
// sidecar is down.

func newSearchServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")

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
	search.Register(api, pool, ragclient.New(""), authMW)

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

func findRequest(t *testing.T, server *httptest.Server, token, query string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, server.URL+"/find?q="+url.QueryEscape(query), nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatalf("find request: %v", err)
	}
	return response
}

type findBody struct {
	Items []struct {
		ID      string `json:"id"`
		Content string `json:"content"`
	} `json:"items"`
	Degraded bool `json:"degraded"`
}

func decodeFind(t *testing.T, response *http.Response) findBody {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, body)
	}
	var body findBody
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return body
}

func TestFindFallbackMatchesTranscriptAndMultilingualSubstrings(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	captureID := uuid.New()
	_, err := pool.Exec(context.Background(), `
		INSERT INTO captures (
			id, user_id, raw_text, transcript, media_type, source,
			transcription_status
		) VALUES ($1, $2, 'voice note', '東京で設計会議をした', 'audio',
			'web', 'completed')`,
		captureID, userID,
	)
	if err != nil {
		t.Fatalf("insert capture: %v", err)
	}

	body := decodeFind(t, findRequest(t, server, token, "設計会議"))
	if !body.Degraded {
		t.Fatalf("expected degraded (FTS fallback) when sidecar disabled")
	}
	if len(body.Items) != 1 || body.Items[0].ID != captureID.String() {
		t.Fatalf("unexpected items: %+v", body.Items)
	}
}

func TestFindExcludesOtherUsersData(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	otherUserID, _ := createSearchUser(t, pool)
	for _, owner := range []uuid.UUID{otherUserID} {
		if _, err := pool.Exec(context.Background(),
			"INSERT INTO captures (user_id, raw_text) VALUES ($1, 'private recall phrase')",
			owner,
		); err != nil {
			t.Fatalf("insert capture: %v", err)
		}
	}
	_ = userID

	body := decodeFind(t, findRequest(t, server, token, "private recall"))
	if len(body.Items) != 0 {
		t.Fatalf("expected no visible items, got %d", len(body.Items))
	}
}

func TestFindRejectsWhitespaceOnlyQuery(t *testing.T) {
	server, pool := newSearchServer(t)
	_, token := createSearchUser(t, pool)

	response := findRequest(t, server, token, "   ")
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", response.StatusCode)
	}
}
