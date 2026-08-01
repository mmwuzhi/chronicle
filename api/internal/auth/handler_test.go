package auth_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/testutil"
)

const testSecret = "test-jwt-secret-long-enough"

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv, _ := newServerWithPool(t)
	return srv
}

func newServerWithPool(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(
		t,
		pool,
		"auth_ephemeral_states",
		"auth_rate_limits",
		"refresh_tokens",
		"users",
	)

	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test API", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	auth.Register(api, r, pool, auth.Options{JWTSecret: testSecret})

	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, pool
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

func TestLogin_UsesDurableNormalizedAccountRateLimit(t *testing.T) {
	srv := newServer(t)

	for attempt := 0; attempt < 10; attempt++ {
		email := "Missing@Example.com"
		if attempt%2 == 1 {
			email = "missing@example.com"
		}
		resp := post(t, srv, "/auth/login", map[string]string{
			"email": email, "password": "wrongpassword",
		})
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("attempt %d: expected 401, got %d", attempt+1, resp.StatusCode)
		}
		resp.Body.Close()
	}

	resp := post(t, srv, "/auth/login", map[string]string{
		"email": "missing@example.com", "password": "wrongpassword",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected durable account limit to return 429, got %d", resp.StatusCode)
	}
}

func TestDesktopOAuthExchange_IsOneTimeAndSetsRefreshCookie(t *testing.T) {
	srv, pool := newServerWithPool(t)
	registerResp := post(t, srv, "/auth/register", map[string]string{
		"email": "oauth-desktop@example.com", "password": "password123",
	})
	var registered struct {
		UserID string `json:"userId"`
	}
	decodeBody(t, registerResp, &registered)

	code := uuid.NewString()
	verifier := "0123456789012345678901234567890123456789012"
	handoff, err := json.Marshal(map[string]string{
		"userId":        registered.UserID,
		"codeChallenge": testPKCEChallenge(verifier),
	})
	if err != nil {
		t.Fatalf("encode desktop OAuth handoff: %v", err)
	}
	codeHash := sha256.Sum256([]byte(code))
	queries := db.New(pool)
	if err := queries.StoreAuthEphemeralState(context.Background(), db.StoreAuthEphemeralStateParams{
		Purpose:   "desktop_oauth_handoff",
		KeyHash:   codeHash[:],
		Payload:   handoff,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("seed desktop OAuth handoff: %v", err)
	}

	wrongVerifier := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
	wrong := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": wrongVerifier,
	})
	defer wrong.Body.Close()
	if wrong.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected wrong verifier to return 401, got %d", wrong.StatusCode)
	}
	if _, err := queries.GetAuthEphemeralState(context.Background(), db.GetAuthEphemeralStateParams{
		Purpose: "desktop_oauth_handoff",
		KeyHash: codeHash[:],
	}); err != nil {
		t.Fatalf("wrong verifier must not consume handoff: %v", err)
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

func TestDesktopOAuthExchange_MFARequiresSecondStep(t *testing.T) {
	srv, pool := newServerWithPool(t)
	registerResp := post(t, srv, "/auth/register", map[string]string{
		"email": "oauth-desktop-mfa@example.com", "password": "password123",
	})
	var registered struct {
		UserID string `json:"userId"`
	}
	decodeBody(t, registerResp, &registered)

	code := uuid.NewString()
	verifier := "0123456789012345678901234567890123456789012"
	handoff, err := json.Marshal(map[string]string{
		"userId":        registered.UserID,
		"codeChallenge": testPKCEChallenge(verifier),
	})
	if err != nil {
		t.Fatalf("encode desktop OAuth MFA handoff: %v", err)
	}
	codeHash := sha256.Sum256([]byte(code))
	if err := db.New(pool).StoreAuthEphemeralState(context.Background(), db.StoreAuthEphemeralStateParams{
		Purpose:   "desktop_oauth_handoff",
		KeyHash:   codeHash[:],
		Payload:   handoff,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("seed desktop OAuth MFA handoff: %v", err)
	}

	// The handoff was created while MFA was disabled. Enabling it before the
	// exchange must still require the second factor; a cached boolean would let
	// this request mint access and refresh tokens directly.
	userID, err := uuid.Parse(registered.UserID)
	if err != nil {
		t.Fatalf("parse registered user id: %v", err)
	}
	if err := db.New(pool).EnableTOTP(context.Background(), userID); err != nil {
		t.Fatalf("enable TOTP after desktop OAuth handoff: %v", err)
	}

	resp := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": verifier,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"accessToken"`
		MFARequired bool   `json:"mfaRequired"`
		MFAToken    string `json:"mfaToken"`
	}
	decodeBody(t, resp, &body)
	if body.AccessToken != "" || !body.MFARequired || body.MFAToken == "" {
		t.Fatalf("expected only an MFA challenge, got %+v", body)
	}
	if userID, err := auth.ParseMFAToken(body.MFAToken, testSecret); err != nil || userID != registered.UserID {
		t.Fatalf("MFA token user: got %q err=%v", userID, err)
	}
	if len(resp.Cookies()) != 0 {
		t.Fatal("MFA challenge must not create a refresh session")
	}

	replay := post(t, srv, "/auth/oauth/desktop/exchange", map[string]string{
		"code": code, "codeVerifier": verifier,
	})
	defer replay.Body.Close()
	if replay.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected one-time MFA code replay to return 401, got %d", replay.StatusCode)
	}
}

func TestMFAVerify_RecoveryCodeSingleUseUnderConcurrency(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(
		t,
		pool,
		"auth_ephemeral_states",
		"auth_rate_limits",
		"recovery_codes",
		"refresh_tokens",
		"users",
	)

	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test API", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	auth.Register(api, r, pool, auth.Options{JWTSecret: testSecret})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)

	const (
		email        = "mfa-recovery-race@example.com"
		password     = "password123"
		recoveryCode = "recovery-code"
	)
	registerUser(t, srv, email, password)

	ctx := context.Background()
	queries := db.New(pool)
	user, err := queries.GetUserByEmail(ctx, email)
	if err != nil {
		t.Fatalf("get registered user: %v", err)
	}
	codeHash, err := bcrypt.GenerateFromPassword([]byte(recoveryCode), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash recovery code: %v", err)
	}
	if err := queries.CreateRecoveryCode(ctx, db.CreateRecoveryCodeParams{
		UserID:   user.ID,
		CodeHash: string(codeHash),
	}); err != nil {
		t.Fatalf("create recovery code: %v", err)
	}
	codes, err := queries.GetRecoveryCodes(ctx, user.ID)
	if err != nil || len(codes) != 1 {
		t.Fatalf("get recovery code row: count=%d err=%v", len(codes), err)
	}

	mfaToken, err := auth.NewMFAToken(user.ID.String(), testSecret)
	if err != nil {
		t.Fatalf("create MFA token: %v", err)
	}
	requestBody, err := json.Marshal(map[string]string{
		"mfaToken": mfaToken,
		"code":     recoveryCode,
	})
	if err != nil {
		t.Fatalf("marshal MFA request: %v", err)
	}

	// Hold the recovery-code row so both requests finish verification and block
	// at consumption. Releasing the lock then deterministically exercises the
	// conditional update instead of depending on scheduler timing.
	blocker, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin row-lock transaction: %v", err)
	}
	if _, err := blocker.Exec(ctx,
		"UPDATE recovery_codes SET used = used WHERE id = $1",
		codes[0].ID,
	); err != nil {
		_ = blocker.Rollback(ctx)
		t.Fatalf("lock recovery code row: %v", err)
	}

	type result struct {
		status           int
		hasRefreshCookie bool
		err              error
	}
	results := make(chan result, 2)
	start := make(chan struct{})
	for range 2 {
		go func() {
			<-start
			resp, err := srv.Client().Post(
				srv.URL+"/auth/mfa/verify",
				"application/json",
				bytes.NewReader(requestBody),
			)
			if err != nil {
				results <- result{err: err}
				return
			}
			defer resp.Body.Close()
			hasRefreshCookie := false
			for _, cookie := range resp.Cookies() {
				if cookie.Name == "refresh_token" {
					hasRefreshCookie = true
				}
			}
			results <- result{
				status:           resp.StatusCode,
				hasRefreshCookie: hasRefreshCookie,
			}
		}()
	}
	close(start)

	deadline := time.Now().Add(5 * time.Second)
	for {
		var blocked int
		err := pool.QueryRow(ctx, `
			SELECT count(*)
			FROM pg_stat_activity
			WHERE datname = current_database()
			  AND pid <> pg_backend_pid()
			  AND state = 'active'
			  AND wait_event_type = 'Lock'
			  AND query LIKE '%UPDATE recovery_codes%'
		`).Scan(&blocked)
		if err != nil {
			_ = blocker.Rollback(ctx)
			t.Fatalf("inspect blocked recovery-code consumers: %v", err)
		}
		if blocked == 2 {
			break
		}
		if time.Now().After(deadline) {
			_ = blocker.Rollback(ctx)
			for range 2 {
				<-results
			}
			t.Fatalf("expected 2 blocked recovery-code consumers, got %d", blocked)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := blocker.Commit(ctx); err != nil {
		t.Fatalf("release recovery-code row: %v", err)
	}

	successes := 0
	rejections := 0
	refreshCookies := 0
	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatalf("MFA verify request: %v", got.err)
		}
		switch got.status {
		case http.StatusOK:
			successes++
		case http.StatusUnauthorized:
			rejections++
		default:
			t.Errorf("unexpected MFA verify status: %d", got.status)
		}
		if got.hasRefreshCookie {
			refreshCookies++
		}
	}
	if successes != 1 || rejections != 1 {
		t.Fatalf("expected one success and one rejection, got successes=%d rejections=%d", successes, rejections)
	}
	if refreshCookies != 1 {
		t.Fatalf("expected exactly one refresh cookie, got %d", refreshCookies)
	}

	var refreshTokens int
	if err := pool.QueryRow(ctx,
		"SELECT count(*) FROM refresh_tokens WHERE user_id = $1",
		user.ID,
	).Scan(&refreshTokens); err != nil {
		t.Fatalf("count refresh sessions: %v", err)
	}
	if refreshTokens != 1 {
		t.Fatalf("expected exactly one refresh session, got %d", refreshTokens)
	}
	codes, err = queries.GetRecoveryCodes(ctx, user.ID)
	if err != nil || len(codes) != 1 || !codes[0].Used {
		t.Fatalf("expected recovery code consumed once, codes=%+v err=%v", codes, err)
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
