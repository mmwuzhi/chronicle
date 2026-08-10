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
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
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
	return findRequestWithOptions(t, server, token, query, 0, false)
}

func findRequestWithOptions(
	t *testing.T,
	server *httptest.Server,
	token, query string,
	limit int,
	includeDismissed bool,
) *http.Response {
	t.Helper()
	values := url.Values{"q": {query}}
	if limit > 0 {
		values.Set("limit", fmt.Sprint(limit))
	}
	if includeDismissed {
		values.Set("includeDismissed", "true")
	}
	request, err := http.NewRequest(http.MethodGet, server.URL+"/find?"+values.Encode(), nil)
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

func setFindDismissed(
	t *testing.T,
	server *httptest.Server,
	token, targetID, query string,
	dismissed bool,
) *http.Response {
	t.Helper()
	method := http.MethodDelete
	if dismissed {
		method = http.MethodPut
	}
	endpoint := server.URL + "/find/dismissals/" + targetID + "?q=" + url.QueryEscape(query)
	request, err := http.NewRequest(method, endpoint, nil)
	if err != nil {
		t.Fatalf("new dismissal request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatalf("dismissal request: %v", err)
	}
	return response
}

type findBody struct {
	Items []struct {
		ID        string `json:"id"`
		Content   string `json:"content"`
		Dismissed bool   `json:"dismissed"`
	} `json:"items"`
	Degraded                bool `json:"degraded"`
	HiddenCount             int  `json:"hiddenCount"`
	DismissalsAuthoritative bool `json:"dismissalsAuthoritative"`
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

func TestFindDismissalHidesRestoresAndNormalizesExactQuery(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	captureID := uuid.New()
	if _, err := pool.Exec(context.Background(),
		"INSERT INTO captures (id, user_id, raw_text) VALUES ($1, $2, 'foo bar details')",
		captureID, userID,
	); err != nil {
		t.Fatalf("insert capture: %v", err)
	}

	dismiss := setFindDismissed(t, server, token, captureID.String(), "ＦＯＯ\u3000 BAR", true)
	dismiss.Body.Close()
	if dismiss.StatusCode != http.StatusNoContent {
		t.Fatalf("dismiss: expected 204, got %d", dismiss.StatusCode)
	}

	hidden := decodeFind(t, findRequest(t, server, token, "foo bar"))
	if len(hidden.Items) != 0 || hidden.HiddenCount != 1 || !hidden.DismissalsAuthoritative {
		t.Fatalf("expected one hidden result, got %+v", hidden)
	}

	response, err := http.Get(server.URL + "/find?q=foo+bar&includeDismissed=true")
	if err != nil {
		t.Fatalf("include dismissed request: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("include dismissed without auth: expected 401, got %d", response.StatusCode)
	}
	request, err := http.NewRequest(http.MethodGet,
		server.URL+"/find?q=foo+bar&includeDismissed=true", nil)
	if err != nil {
		t.Fatalf("new include dismissed request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err = server.Client().Do(request)
	if err != nil {
		t.Fatalf("include dismissed request: %v", err)
	}
	shown := decodeFind(t, response)
	if len(shown.Items) != 1 || !shown.Items[0].Dismissed || shown.HiddenCount != 1 {
		t.Fatalf("expected dismissed result to be recoverable, got %+v", shown)
	}

	restore := setFindDismissed(t, server, token, captureID.String(), "foo bar", false)
	restore.Body.Close()
	if restore.StatusCode != http.StatusNoContent {
		t.Fatalf("restore: expected 204, got %d", restore.StatusCode)
	}
	restored := decodeFind(t, findRequest(t, server, token, "foo bar"))
	if len(restored.Items) != 1 || restored.HiddenCount != 0 {
		t.Fatalf("expected restored result, got %+v", restored)
	}
}

func TestFindDismissalsPreserveVisibleLimitAndRecoverOutsideCandidateWindow(t *testing.T) {
	server, pool := newSearchServer(t)
	userID, token := createSearchUser(t, pool)
	query := "recovery needle"
	oldID := uuid.New()
	if _, err := pool.Exec(context.Background(), `
		INSERT INTO captures (id, user_id, raw_text, created_at)
		VALUES ($1, $2, 'recovery needle oldest', '2020-01-01T00:00:00Z')`,
		oldID, userID,
	); err != nil {
		t.Fatalf("insert oldest capture: %v", err)
	}
	dismissOld := setFindDismissed(t, server, token, oldID.String(), query, true)
	dismissOld.Body.Close()
	if dismissOld.StatusCode != http.StatusNoContent {
		t.Fatalf("dismiss old: expected 204, got %d", dismissOld.StatusCode)
	}

	var newestID uuid.UUID
	var topRankedIDs []uuid.UUID
	for index := range 70 {
		id := uuid.New()
		if index == 69 {
			newestID = id
		}
		if index >= 15 {
			topRankedIDs = append(topRankedIDs, id)
		}
		if _, err := pool.Exec(context.Background(), `
			INSERT INTO captures (id, user_id, raw_text, created_at)
			VALUES ($1, $2, 'recovery needle newer', $3)`,
			id, userID, time.Date(2026, 1, 1, 0, index, 0, 0, time.UTC),
		); err != nil {
			t.Fatalf("insert newer capture %d: %v", index, err)
		}
	}
	for index, id := range topRankedIDs {
		dismiss := setFindDismissed(t, server, token, id.String(), query, true)
		dismiss.Body.Close()
		if dismiss.StatusCode != http.StatusNoContent {
			t.Fatalf("dismiss top-ranked %d: expected 204, got %d", index, dismiss.StatusCode)
		}
	}

	hidden := decodeFind(t, findRequestWithOptions(t, server, token, query, 10, false))
	if len(hidden.Items) != 10 || hidden.HiddenCount != 56 {
		t.Fatalf("hidden results must not consume the visible limit: %+v", hidden)
	}
	for _, item := range hidden.Items {
		if item.Dismissed {
			t.Fatalf("collapsed search returned dismissed item: %+v", item)
		}
	}

	shown := decodeFind(t, findRequestWithOptions(t, server, token, query, 10, true))
	visibleCount := 0
	dismissedIDs := map[string]bool{}
	for _, item := range shown.Items {
		if item.Dismissed {
			dismissedIDs[item.ID] = true
		} else {
			visibleCount++
		}
	}
	if visibleCount != 10 || shown.HiddenCount != 56 || len(dismissedIDs) != 56 ||
		!dismissedIDs[oldID.String()] || !dismissedIDs[newestID.String()] {
		t.Fatalf("expected ten visible and both recoverable dismissals, got %+v", shown)
	}
}

func TestSearchDismissalPruningIsBounded(t *testing.T) {
	_, pool := newSearchServer(t)
	userID, _ := createSearchUser(t, pool)
	targetID := uuid.New()
	if _, err := pool.Exec(context.Background(),
		"INSERT INTO captures (id, user_id, raw_text) VALUES ($1, $2, 'target')",
		targetID, userID,
	); err != nil {
		t.Fatalf("insert capture: %v", err)
	}
	for index := range 5 {
		if _, err := pool.Exec(context.Background(), `
			INSERT INTO retrieval_dismissals (
				user_id, surface, query_hash, query_text, target_id, created_at
			)
			VALUES ($1, 'search', $2, $5, $3, now() + ($4 * interval '1 second'))`,
			userID, []byte(fmt.Sprintf("query-%d", index)), targetID, index,
			fmt.Sprintf("query-%d", index),
		); err != nil {
			t.Fatalf("insert dismissal %d: %v", index, err)
		}
	}
	queries := db.New(pool)
	if err := queries.PruneSearchDismissals(context.Background(), db.PruneSearchDismissalsParams{
		UserID: userID, KeepLimit: 3,
	}); err != nil {
		t.Fatalf("prune dismissals: %v", err)
	}
	var count int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM retrieval_dismissals
		WHERE user_id = $1 AND surface = 'search'`, userID).Scan(&count); err != nil {
		t.Fatalf("count dismissals: %v", err)
	}
	if count != 3 {
		t.Fatalf("expected retention bound of 3, got %d", count)
	}
}
