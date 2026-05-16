package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/redis/go-redis/v9"
	"golang.org/x/oauth2"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

const oauthStateTTL = 10 * time.Minute

// --- Google ---

func (h *handler) googleAuth(w http.ResponseWriter, r *http.Request) {
	state, err := randomHex(16)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := h.rdb.Set(r.Context(), "oauth:state:"+state, "1", oauthStateTTL).Err(); err != nil {
		slog.ErrorContext(r.Context(), "failed to store oauth state", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, h.googleOAuth.AuthCodeURL(state), http.StatusFound)
}

func (h *handler) googleCallback(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := middleware.GetTraceID(ctx)

	if err := h.validateState(ctx, r.URL.Query().Get("state")); err != nil {
		http.Error(w, "invalid state", http.StatusBadRequest)
		return
	}

	tok, err := h.googleOAuth.Exchange(ctx, r.URL.Query().Get("code"))
	if err != nil {
		slog.ErrorContext(ctx, "google token exchange failed", "traceId", traceID, "err", err)
		http.Error(w, "auth failed", http.StatusBadRequest)
		return
	}

	email, providerID, err := fetchGoogleUser(ctx, h.googleOAuth, tok)
	if err != nil {
		slog.ErrorContext(ctx, "failed to fetch google user", "traceId", traceID, "err", err)
		http.Error(w, "auth failed", http.StatusInternalServerError)
		return
	}

	h.finishOAuthLogin(w, r, ctx, traceID, email, "google", providerID)
}

func fetchGoogleUser(ctx context.Context, cfg *oauth2.Config, tok *oauth2.Token) (email, id string, err error) {
	client := cfg.Client(ctx, tok)
	resp, err := client.Get("https://www.googleapis.com/oauth2/v2/userinfo")
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", err
	}
	var info struct {
		ID    string `json:"id"`
		Email string `json:"email"`
	}
	if err := json.Unmarshal(body, &info); err != nil {
		return "", "", err
	}
	if info.Email == "" {
		return "", "", fmt.Errorf("google did not return an email")
	}
	return info.Email, info.ID, nil
}

// --- GitHub ---

func (h *handler) githubAuth(w http.ResponseWriter, r *http.Request) {
	state, err := randomHex(16)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := h.rdb.Set(r.Context(), "oauth:state:"+state, "1", oauthStateTTL).Err(); err != nil {
		slog.ErrorContext(r.Context(), "failed to store oauth state", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, h.githubOAuth.AuthCodeURL(state), http.StatusFound)
}

func (h *handler) githubCallback(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := middleware.GetTraceID(ctx)

	if err := h.validateState(ctx, r.URL.Query().Get("state")); err != nil {
		http.Error(w, "invalid state", http.StatusBadRequest)
		return
	}

	tok, err := h.githubOAuth.Exchange(ctx, r.URL.Query().Get("code"))
	if err != nil {
		slog.ErrorContext(ctx, "github token exchange failed", "traceId", traceID, "err", err)
		http.Error(w, "auth failed", http.StatusBadRequest)
		return
	}

	email, providerID, err := fetchGitHubUser(ctx, h.githubOAuth, tok)
	if err != nil {
		slog.ErrorContext(ctx, "failed to fetch github user", "traceId", traceID, "err", err)
		http.Error(w, "auth failed", http.StatusInternalServerError)
		return
	}

	h.finishOAuthLogin(w, r, ctx, traceID, email, "github", providerID)
}

func fetchGitHubUser(ctx context.Context, cfg *oauth2.Config, tok *oauth2.Token) (email, id string, err error) {
	client := cfg.Client(ctx, tok)

	// Try primary email from /user first
	resp, err := client.Get("https://api.github.com/user")
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var user struct {
		ID    int64  `json:"id"`
		Email string `json:"email"`
	}
	if err := json.Unmarshal(body, &user); err != nil {
		return "", "", err
	}

	// If email is private, fetch from /user/emails
	if user.Email == "" {
		resp2, err := client.Get("https://api.github.com/user/emails")
		if err != nil {
			return "", "", err
		}
		defer resp2.Body.Close()
		body2, _ := io.ReadAll(resp2.Body)
		var emails []struct {
			Email    string `json:"email"`
			Primary  bool   `json:"primary"`
			Verified bool   `json:"verified"`
		}
		if err := json.Unmarshal(body2, &emails); err != nil {
			return "", "", err
		}
		for _, e := range emails {
			if e.Primary && e.Verified {
				user.Email = e.Email
				break
			}
		}
	}

	if user.Email == "" {
		return "", "", fmt.Errorf("github did not return a verified email")
	}
	return user.Email, fmt.Sprintf("%d", user.ID), nil
}

// --- shared ---

func (h *handler) validateState(ctx context.Context, state string) error {
	if state == "" {
		return fmt.Errorf("missing state")
	}
	val, err := h.rdb.GetDel(ctx, "oauth:state:"+state).Result()
	if err == redis.Nil {
		return fmt.Errorf("state not found or expired")
	}
	if err != nil {
		return fmt.Errorf("redis error: %w", err)
	}
	if val != "1" {
		return fmt.Errorf("invalid state value")
	}
	return nil
}

func (h *handler) finishOAuthLogin(w http.ResponseWriter, r *http.Request, ctx context.Context, traceID, email, provider, providerID string) {
	user, err := h.q.UpsertOAuthUser(ctx, db.UpsertOAuthUserParams{
		Email:           email,
		OauthProvider:   pgtype.Text{String: provider, Valid: true},
		OauthProviderID: pgtype.Text{String: providerID, Valid: true},
	})
	if err != nil {
		slog.ErrorContext(ctx, "upsert oauth user failed", "traceId", traceID, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	accessToken, err := NewAccessToken(user.ID.String(), h.secret)
	if err != nil {
		slog.ErrorContext(ctx, "access token generation failed", "traceId", traceID, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	rawRefresh, hashedRefresh, err := NewRefreshToken()
	if err != nil {
		slog.ErrorContext(ctx, "refresh token generation failed", "traceId", traceID, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if _, err := h.q.CreateRefreshToken(ctx, db.CreateRefreshTokenParams{
		UserID:    user.ID,
		TokenHash: hashedRefresh,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(RefreshTokenTTL), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store refresh token", "traceId", traceID, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "refresh_token",
		Value:    rawRefresh,
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		Path:     "/auth/refresh",
		MaxAge:   int(RefreshTokenTTL.Seconds()),
	})

	frontendURL := h.frontendURL
	if frontendURL == "" {
		frontendURL = "http://localhost:5173"
	}
	http.Redirect(w, r, frontendURL+"/auth/callback?access_token="+accessToken, http.StatusFound)
}
