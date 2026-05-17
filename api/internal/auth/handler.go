package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/github"
	"golang.org/x/oauth2/google"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type Options struct {
	JWTSecret          string
	ResendAPIKey       string
	FrontendURL        string
	APIBaseURL         string
	GoogleClientID     string
	GoogleClientSecret string
	GitHubClientID     string
	GitHubClientSecret string
	TurnstileSecret    string
}

type handler struct {
	q               *db.Queries
	secret          string
	resendKey       string
	frontendURL     string
	apiBaseURL      string
	rdb             *redis.Client
	googleOAuth     *oauth2.Config
	githubOAuth     *oauth2.Config
	turnstileSecret string
}

func Register(api huma.API, r chi.Router, pool *pgxpool.Pool, rdb *redis.Client, opts Options) {
	h := &handler{
		q:               db.New(pool),
		secret:          opts.JWTSecret,
		resendKey:       opts.ResendAPIKey,
		frontendURL:     opts.FrontendURL,
		apiBaseURL:      opts.APIBaseURL,
		rdb:             rdb,
		turnstileSecret: opts.TurnstileSecret,
	}

	if opts.GoogleClientID != "" {
		h.googleOAuth = &oauth2.Config{
			ClientID:     opts.GoogleClientID,
			ClientSecret: opts.GoogleClientSecret,
			Endpoint:     google.Endpoint,
			RedirectURL:  opts.APIBaseURL + "/auth/google/callback",
			Scopes:       []string{"openid", "email"},
		}
		r.Get("/auth/google", h.googleAuth)
		r.Get("/auth/google/callback", h.googleCallback)
	}

	if opts.GitHubClientID != "" {
		h.githubOAuth = &oauth2.Config{
			ClientID:     opts.GitHubClientID,
			ClientSecret: opts.GitHubClientSecret,
			Endpoint:     github.Endpoint,
			RedirectURL:  opts.APIBaseURL + "/auth/github/callback",
			Scopes:       []string{"user:email"},
		}
		r.Get("/auth/github", h.githubAuth)
		r.Get("/auth/github/callback", h.githubCallback)
	}

	huma.Register(api, huma.Operation{
		OperationID: "register",
		Method:      http.MethodPost,
		Path:        "/auth/register",
		Summary:     "Create a new account",
		Tags:        []string{"auth"},
	}, h.register)

	huma.Register(api, huma.Operation{
		OperationID: "login",
		Method:      http.MethodPost,
		Path:        "/auth/login",
		Summary:     "Login and receive tokens",
		Tags:        []string{"auth"},
	}, h.login)

	huma.Register(api, huma.Operation{
		OperationID: "refresh",
		Method:      http.MethodPost,
		Path:        "/auth/refresh",
		Summary:     "Exchange refresh token for new access token",
		Tags:        []string{"auth"},
	}, h.refresh)

	huma.Register(api, huma.Operation{
		OperationID: "logout",
		Method:      http.MethodPost,
		Path:        "/auth/logout",
		Summary:     "Revoke refresh token and clear cookie",
		Tags:        []string{"auth"},
	}, h.logout)

	huma.Register(api, huma.Operation{
		OperationID: "verifyEmail",
		Method:      http.MethodPost,
		Path:        "/auth/verify-email",
		Summary:     "Verify email address with token",
		Tags:        []string{"auth"},
	}, h.verifyEmail)

	huma.Register(api, huma.Operation{
		OperationID: "forgotPassword",
		Method:      http.MethodPost,
		Path:        "/auth/forgot-password",
		Summary:     "Send password reset email",
		Tags:        []string{"auth"},
	}, h.forgotPassword)

	huma.Register(api, huma.Operation{
		OperationID: "resetPassword",
		Method:      http.MethodPost,
		Path:        "/auth/reset-password",
		Summary:     "Reset password with token",
		Tags:        []string{"auth"},
	}, h.resetPassword)
}

// --- register ---

type RegisterInput struct {
	Body struct {
		Email               string `json:"email" format:"email"`
		Password            string `json:"password" minLength:"8"`
		CfTurnstileResponse string `json:"cfTurnstileResponse"`
	}
}

type RegisterOutput struct {
	Body struct {
		UserID string `json:"userId"`
	}
}

func (h *handler) register(ctx context.Context, input *RegisterInput) (*RegisterOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	// Per-IP registration rate limit: max 3 per hour
	if h.rdb != nil {
		r, _ := responseWriter(ctx)
		ip := clientIP(r)
		key := "reg:ip:" + ip
		count, err := h.rdb.Incr(ctx, key).Result()
		if err == nil {
			if count == 1 {
				h.rdb.Expire(ctx, key, time.Hour)
			}
			if count > 3 {
				return nil, huma.NewError(http.StatusTooManyRequests, "too many registrations from this IP, try again later")
			}
		}
	}

	// Turnstile bot check
	if h.turnstileSecret != "" {
		if err := verifyTurnstile(ctx, h.turnstileSecret, input.Body.CfTurnstileResponse); err != nil {
			slog.WarnContext(ctx, "turnstile verification failed", "traceId", traceID, "err", err)
			return nil, huma.Error400BadRequest("bot verification failed")
		}
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(input.Body.Password), bcrypt.DefaultCost)
	if err != nil {
		slog.ErrorContext(ctx, "bcrypt error", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	user, err := h.q.CreateUser(ctx, db.CreateUserParams{
		Email:        input.Body.Email,
		PasswordHash: pgtype.Text{String: string(hash), Valid: true},
	})
	if err != nil {
		return nil, huma.Error409Conflict("email already in use")
	}

	token, err := randomHex(32)
	if err != nil {
		slog.ErrorContext(ctx, "token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if err := h.q.SetEmailVerifyToken(ctx, db.SetEmailVerifyTokenParams{
		ID:               user.ID,
		EmailVerifyToken: pgtype.Text{String: token, Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store verify token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if h.resendKey != "" {
		if err := sendVerificationEmail(h.resendKey, h.frontendURL, user.Email, token); err != nil {
			slog.ErrorContext(ctx, "failed to send verification email", "traceId", traceID, "err", err)
		}
	}

	out := &RegisterOutput{}
	out.Body.UserID = user.ID.String()
	return out, nil
}

// --- verify email ---

type VerifyEmailInput struct {
	Body struct {
		Token string `json:"token" minLength:"1"`
	}
}

func (h *handler) verifyEmail(ctx context.Context, input *VerifyEmailInput) (*struct{}, error) {
	_, err := h.q.VerifyEmail(ctx, pgtype.Text{String: input.Body.Token, Valid: true})
	if err != nil {
		return nil, huma.Error400BadRequest("invalid or expired token")
	}
	return nil, nil
}

// --- forgot password ---

type ForgotPasswordInput struct {
	Body struct {
		Email string `json:"email" format:"email"`
	}
}

func (h *handler) forgotPassword(ctx context.Context, input *ForgotPasswordInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	user, err := h.q.GetUserByEmail(ctx, input.Body.Email)
	if err != nil {
		// Return success regardless to avoid email enumeration
		return nil, nil
	}

	token, err := randomHex(32)
	if err != nil {
		slog.ErrorContext(ctx, "token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	expires := pgtype.Timestamptz{Time: time.Now().Add(time.Hour), Valid: true}
	if err := h.q.SetPasswordResetToken(ctx, db.SetPasswordResetTokenParams{
		Email:                user.Email,
		PasswordResetToken:   pgtype.Text{String: token, Valid: true},
		PasswordResetExpires: expires,
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store reset token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if h.resendKey != "" {
		if err := sendPasswordResetEmail(h.resendKey, h.frontendURL, user.Email, token); err != nil {
			slog.ErrorContext(ctx, "failed to send reset email", "traceId", traceID, "err", err)
		}
	}

	return nil, nil
}

// --- reset password ---

type ResetPasswordInput struct {
	Body struct {
		Token    string `json:"token" minLength:"1"`
		Password string `json:"password" minLength:"8"`
	}
}

func (h *handler) resetPassword(ctx context.Context, input *ResetPasswordInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	user, err := h.q.GetUserByPasswordResetToken(ctx, pgtype.Text{String: input.Body.Token, Valid: true})
	if err != nil {
		return nil, huma.Error400BadRequest("invalid or expired token")
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(input.Body.Password), bcrypt.DefaultCost)
	if err != nil {
		slog.ErrorContext(ctx, "bcrypt error", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if err := h.q.UpdatePassword(ctx, db.UpdatePasswordParams{
		ID:           user.ID,
		PasswordHash: pgtype.Text{String: string(hash), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to update password", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	return nil, nil
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func clientIP(r *http.Request) string {
	if r == nil {
		return "unknown"
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.SplitN(xff, ",", 2)[0])
	}
	return r.RemoteAddr
}

func verifyTurnstile(ctx context.Context, secret, token string) error {
	resp, err := http.PostForm(
		"https://challenges.cloudflare.com/turnstile/v0/siteverify",
		url.Values{"secret": {secret}, "response": {token}},
	)
	if err != nil {
		return fmt.Errorf("turnstile request: %w", err)
	}
	defer resp.Body.Close()
	var result struct {
		Success bool `json:"success"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("turnstile decode: %w", err)
	}
	if !result.Success {
		return fmt.Errorf("turnstile rejected")
	}
	return nil
}

// --- login ---

type LoginInput struct {
	Body struct {
		Email    string `json:"email" format:"email"`
		Password string `json:"password"`
	}
}

type LoginOutput struct {
	Body struct {
		AccessToken string `json:"accessToken"`
	}
}

func (h *handler) login(ctx context.Context, input *LoginInput) (*LoginOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	user, err := h.q.GetUserByEmail(ctx, input.Body.Email)
	if err != nil {
		return nil, huma.Error401Unauthorized("invalid credentials")
	}

	if !user.PasswordHash.Valid {
		return nil, huma.Error401Unauthorized("invalid credentials")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash.String), []byte(input.Body.Password)); err != nil {
		return nil, huma.Error401Unauthorized("invalid credentials")
	}

	accessToken, err := NewAccessToken(user.ID.String(), h.secret)
	if err != nil {
		slog.ErrorContext(ctx, "access token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	rawRefresh, hashedRefresh, err := NewRefreshToken()
	if err != nil {
		slog.ErrorContext(ctx, "refresh token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if _, err := h.q.CreateRefreshToken(ctx, db.CreateRefreshTokenParams{
		UserID:    user.ID,
		TokenHash: hashedRefresh,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(RefreshTokenTTL), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store refresh token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	setRefreshCookie(ctx, rawRefresh, RefreshTokenTTL)

	out := &LoginOutput{}
	out.Body.AccessToken = accessToken
	return out, nil
}

// --- refresh ---

type RefreshInput struct {
	RefreshToken string `cookie:"refresh_token"`
}

type RefreshOutput struct {
	Body struct {
		AccessToken string `json:"accessToken"`
	}
}

func (h *handler) refresh(ctx context.Context, input *RefreshInput) (*RefreshOutput, error) {
	if input.RefreshToken == "" {
		return nil, huma.Error401Unauthorized("missing refresh token")
	}

	hashed := HashRefreshToken(input.RefreshToken)
	record, err := h.q.GetRefreshToken(ctx, hashed)
	if err != nil {
		return nil, huma.Error401Unauthorized("invalid or expired refresh token")
	}

	accessToken, err := NewAccessToken(record.UserID.String(), h.secret)
	if err != nil {
		slog.ErrorContext(ctx, "access token generation failed", "traceId", middleware.GetTraceID(ctx), "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &RefreshOutput{}
	out.Body.AccessToken = accessToken
	return out, nil
}

// --- logout ---

type LogoutInput struct {
	RefreshToken string `cookie:"refresh_token"`
}

func (h *handler) logout(ctx context.Context, input *LogoutInput) (*struct{}, error) {
	if input.RefreshToken != "" {
		_ = h.q.RevokeRefreshToken(ctx, HashRefreshToken(input.RefreshToken))
	}
	clearRefreshCookie(ctx)
	return nil, nil
}

// setRefreshCookie writes the httpOnly refresh token cookie to the response.
// It reaches the underlying http.ResponseWriter via humachi.Unwrap on the
// huma.Context stored in the Go context by the InjectHumaContext middleware.
func setRefreshCookie(ctx context.Context, value string, ttl time.Duration) {
	_, w := responseWriter(ctx)
	if w == nil {
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "refresh_token",
		Value:    value,
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		Path:     "/auth/refresh",
		MaxAge:   int(ttl.Seconds()),
	})
}

func clearRefreshCookie(ctx context.Context) {
	_, w := responseWriter(ctx)
	if w == nil {
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "refresh_token",
		Value:    "",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		Path:     "/auth/refresh",
		MaxAge:   -1,
	})
}

type humaCtxKey struct{}

// InjectHumaContext is a huma middleware that stores the huma.Context in the
// Go context so handlers can access the underlying ResponseWriter for cookies.
func InjectHumaContext(ctx huma.Context, next func(huma.Context)) {
	newCtx := huma.WithValue(ctx, humaCtxKey{}, ctx)
	next(newCtx)
}

func responseWriter(ctx context.Context) (*http.Request, http.ResponseWriter) {
	humaCtx, ok := ctx.Value(humaCtxKey{}).(huma.Context)
	if !ok {
		return nil, nil
	}
	return humachi.Unwrap(humaCtx)
}
