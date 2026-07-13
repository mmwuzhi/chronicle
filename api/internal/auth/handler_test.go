package auth_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/testutil"
)

const testSecret = "test-jwt-secret-long-enough"

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "refresh_tokens", "users")

	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test API", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	auth.Register(api, r, pool, nil, auth.Options{JWTSecret: testSecret})

	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv
}

func newServerWithRedis(t *testing.T) (*httptest.Server, *redis.Client) {
	t.Helper()
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6379"
	}
	redisOptions, err := redis.ParseURL(redisURL)
	if err != nil {
		t.Fatalf("parse REDIS_URL: %v", err)
	}
	rdb := redis.NewClient(redisOptions)
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		t.Skipf("redis is required for desktop OAuth exchange: %v", err)
	}
	t.Cleanup(func() { _ = rdb.Close() })

	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "refresh_tokens", "users")
	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test API", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	auth.Register(api, r, pool, rdb, auth.Options{JWTSecret: testSecret})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, rdb
}

func post(t *testing.T, srv *httptest.Server, path string, body any) *http.Response {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}
	resp, err := srv.Client().Post(srv.URL+path, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	return resp
}

func decodeBody(t *testing.T, resp *http.Response, dst any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		t.Fatalf("decode response body: %v", err)
	}
}

// --- register ---

func TestRegister_HappyPath(t *testing.T) {
	srv := newServer(t)

	resp := post(t, srv, "/auth/register", map[string]string{
		"email":    "alice@example.com",
		"password": "password123",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		UserID string `json:"userId"`
	}
	decodeBody(t, resp, &body)

	if body.UserID == "" {
		t.Fatal("expected non-empty userId in response")
	}
}

func TestRegister_DuplicateEmail(t *testing.T) {
	srv := newServer(t)

	payload := map[string]string{"email": "bob@example.com", "password": "password123"}
	post(t, srv, "/auth/register", payload) // first registration

	resp := post(t, srv, "/auth/register", payload) // duplicate
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("expected 409, got %d", resp.StatusCode)
	}
}

func TestRegister_PasswordTooShort(t *testing.T) {
	srv := newServer(t)

	resp := post(t, srv, "/auth/register", map[string]string{
		"email":    "carol@example.com",
		"password": "short",
	})

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

// --- login ---

func registerUser(t *testing.T, srv *httptest.Server, email, password string) {
	t.Helper()
	resp := post(t, srv, "/auth/register", map[string]string{
		"email": email, "password": password,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("setup: register user: got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestLogin_HappyPath(t *testing.T) {
	srv := newServer(t)
	registerUser(t, srv, "dave@example.com", "password123")

	resp := post(t, srv, "/auth/login", map[string]string{
		"email":    "dave@example.com",
		"password": "password123",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		AccessToken string `json:"accessToken"`
	}
	decodeBody(t, resp, &body)

	if body.AccessToken == "" {
		t.Fatal("expected non-empty accessToken")
	}

	// refresh token cookie must be set
	var refreshCookie *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == "refresh_token" {
			refreshCookie = c
		}
	}
	if refreshCookie == nil {
		t.Fatal("expected refresh_token cookie in response")
	}
	if !refreshCookie.HttpOnly {
		t.Fatal("refresh_token cookie must be HttpOnly")
	}
}

func TestLogin_WrongPassword(t *testing.T) {
	srv := newServer(t)
	registerUser(t, srv, "eve@example.com", "password123")

	resp := post(t, srv, "/auth/login", map[string]string{
		"email":    "eve@example.com",
		"password": "wrongpassword",
	})

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestLogin_UnknownEmail(t *testing.T) {
	srv := newServer(t)

	resp := post(t, srv, "/auth/login", map[string]string{
		"email":    "nobody@example.com",
		"password": "password123",
	})

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestDesktopOAuthExchange_IsOneTimeAndSetsRefreshCookie(t *testing.T) {
	srv, rdb := newServerWithRedis(t)
	registerResp := post(t, srv, "/auth/register", map[string]string{
		"email": "oauth-desktop@example.com", "password": "password123",
	})
	var registered struct {
		UserID string `json:"userId"`
	}
	decodeBody(t, registerResp, &registered)

	code := uuid.NewString()
	key := "oauth:desktop:" + code
	verifier := "0123456789012345678901234567890123456789012"
	handoff, err := json.Marshal(map[string]string{
		"userId":        registered.UserID,
		"codeChallenge": testPKCEChallenge(verifier),
	})
	if err != nil {
		t.Fatalf("encode desktop OAuth handoff: %v", err)
	}
	if err := rdb.Set(context.Background(), key, handoff, time.Minute).Err(); err != nil {
		t.Fatalf("seed desktop OAuth handoff: %v", err)
	}
	t.Cleanup(func() { _ = rdb.Del(context.Background(), key).Err() })

	wrongVerifier := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
	wrong := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": wrongVerifier,
	})
	defer wrong.Body.Close()
	if wrong.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected wrong verifier to return 401, got %d", wrong.StatusCode)
	}
	if exists, err := rdb.Exists(context.Background(), key).Result(); err != nil || exists != 1 {
		t.Fatalf("wrong verifier must not consume handoff: exists=%d err=%v", exists, err)
	}

	resp := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": verifier,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"accessToken"`
	}
	decodeBody(t, resp, &body)
	if body.AccessToken == "" {
		t.Fatal("expected non-empty accessToken")
	}
	var refreshCookie *http.Cookie
	for _, cookie := range resp.Cookies() {
		if cookie.Name == "refresh_token" {
			refreshCookie = cookie
		}
	}
	if refreshCookie == nil || !refreshCookie.HttpOnly {
		t.Fatal("expected an httpOnly refresh_token cookie")
	}

	replay := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": verifier,
	})
	defer replay.Body.Close()
	if replay.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected one-time code replay to return 401, got %d", replay.StatusCode)
	}
}

func testPKCEChallenge(verifier string) string {
	digest := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

// --- refresh ---

func loginUser(t *testing.T, srv *httptest.Server, email, password string) (accessToken string, refreshCookie *http.Cookie) {
	t.Helper()
	resp := post(t, srv, "/auth/login", map[string]string{
		"email": email, "password": password,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("setup: login: got %d", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"accessToken"`
	}
	decodeBody(t, resp, &body)
	for _, c := range resp.Cookies() {
		if c.Name == "refresh_token" {
			refreshCookie = c
		}
	}
	return body.AccessToken, refreshCookie
}

func TestRefresh_HappyPath(t *testing.T) {
	srv := newServer(t)
	registerUser(t, srv, "frank@example.com", "password123")
	_, refreshCookie := loginUser(t, srv, "frank@example.com", "password123")

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/auth/refresh", nil)
	req.AddCookie(refreshCookie)

	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /auth/refresh: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		AccessToken string `json:"accessToken"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body.AccessToken == "" {
		t.Fatal("expected non-empty accessToken")
	}
}

func TestRefresh_MissingCookie(t *testing.T) {
	srv := newServer(t)

	resp, err := srv.Client().Post(srv.URL+"/auth/refresh", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /auth/refresh: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestRefresh_InvalidToken(t *testing.T) {
	srv := newServer(t)

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/auth/refresh", nil)
	req.AddCookie(&http.Cookie{Name: "refresh_token", Value: "invalid-token-value"})

	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /auth/refresh: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// --- logout ---

func TestLogout_RevokesToken(t *testing.T) {
	srv := newServer(t)
	registerUser(t, srv, "grace@example.com", "password123")
	_, refreshCookie := loginUser(t, srv, "grace@example.com", "password123")

	// logout
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/auth/logout", nil)
	req.AddCookie(refreshCookie)
	logoutResp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /auth/logout: %v", err)
	}
	logoutResp.Body.Close()

	if logoutResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", logoutResp.StatusCode)
	}

	// refresh with the same token must fail
	req2, _ := http.NewRequest(http.MethodPost, srv.URL+"/auth/refresh", nil)
	req2.AddCookie(refreshCookie)
	refreshResp, err := srv.Client().Do(req2)
	if err != nil {
		t.Fatalf("POST /auth/refresh after logout: %v", err)
	}
	defer refreshResp.Body.Close()

	if refreshResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 after logout, got %d", refreshResp.StatusCode)
	}
}
