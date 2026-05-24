package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/redis/go-redis/v9"
	"golang.org/x/oauth2"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

const oauthStateTTL = 10 * time.Minute

type oauthStateData struct {
	Action string `json:"action,omitempty"`
	UserID string `json:"userId,omitempty"`
}

func (h *handler) storeOAuthState(ctx context.Context, r *http.Request) (string, error) {
	state, err := randomHex(16)
	if err != nil {
		return "", err
	}

	data := oauthStateData{}
	if r.URL.Query().Get("action") == "link" {
		raw := ""
		if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
			raw = strings.TrimPrefix(auth, "Bearer ")
		} else if tok := r.URL.Query().Get("token"); tok != "" {
			raw = tok
		}
		if raw == "" {
			return "", fmt.Errorf("must be logged in to link account")
		}
		claims, err := ParseAccessToken(raw, h.secret)
		if err != nil {
			return "", fmt.Errorf("invalid token")
		}
		data.Action = "link"
		data.UserID = claims.UserID
	}

	val, err := json.Marshal(data)
	if err != nil {
		return "", err
	}
	if err := h.rdb.Set(ctx, "oauth:state:"+state, string(val), oauthStateTTL).Err(); err != nil {
		return "", err
	}
	return state, nil
}

// --- Google ---

func (h *handler) googleAuth(w http.ResponseWriter, r *http.Request) {
	state, err := h.storeOAuthState(r.Context(), r)
	if err != nil {
		slog.ErrorContext(r.Context(), "failed to store oauth state", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, h.googleOAuth.AuthCodeURL(state), http.StatusFound)
}

func (h *handler) googleCallback(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := middleware.GetTraceID(ctx)

	stateData, err := h.validateState(ctx, r.URL.Query().Get("state"))
	if err != nil {
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

	h.finishOAuth(w, r, ctx, traceID, stateData, email, "google", providerID)
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
	state, err := h.storeOAuthState(r.Context(), r)
	if err != nil {
		slog.ErrorContext(r.Context(), "failed to store oauth state", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, h.githubOAuth.AuthCodeURL(state), http.StatusFound)
}

func (h *handler) githubCallback(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := middleware.GetTraceID(ctx)

	stateData, err := h.validateState(ctx, r.URL.Query().Get("state"))
	if err != nil {
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

	h.finishOAuth(w, r, ctx, traceID, stateData, email, "github", providerID)
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

func (h *handler) validateState(ctx context.Context, state string) (*oauthStateData, error) {
	if state == "" {
		return nil, fmt.Errorf("missing state")
	}
	val, err := h.rdb.GetDel(ctx, "oauth:state:"+state).Result()
	if err == redis.Nil {
		return nil, fmt.Errorf("state not found or expired")
	}
	if err != nil {
		return nil, fmt.Errorf("redis error: %w", err)
	}

	var data oauthStateData
	if err := json.Unmarshal([]byte(val), &data); err != nil {
		return nil, fmt.Errorf("invalid state data")
	}
	return &data, nil
}

func (h *handler) finishOAuth(w http.ResponseWriter, r *http.Request, ctx context.Context, traceID string, stateData *oauthStateData, email, provider, providerID string) {
	frontendURL := h.frontendURL
	if frontendURL == "" {
		frontendURL = "http://localhost:5173"
	}

	// Link flow: attach this OAuth identity to an existing logged-in user
	if stateData.Action == "link" {
		uid, err := uuid.Parse(stateData.UserID)
		if err != nil {
			http.Error(w, "invalid user", http.StatusBadRequest)
			return
		}
		if _, err := h.q.CreateOAuthAccount(ctx, db.CreateOAuthAccountParams{
			UserID:     uid,
			Provider:   provider,
			ProviderID: providerID,
		}); err != nil {
			slog.ErrorContext(ctx, "link oauth account failed", "traceId", traceID, "err", err)
			http.Redirect(w, r, frontendURL+"/settings?oauth_error=already_linked", http.StatusFound)
			return
		}
		http.Redirect(w, r, frontendURL+"/settings?oauth_linked="+provider, http.StatusFound)
		return
	}

	// Login flow
	user, err := h.q.GetUserByOAuth(ctx, db.GetUserByOAuthParams{
		Provider:   provider,
		ProviderID: providerID,
	})
	if err != nil {
		user, err = h.q.GetUserByEmail(ctx, email)
		if err != nil {
			user, err = h.q.CreateOAuthUser(ctx, email)
			if err != nil {
				slog.ErrorContext(ctx, "create oauth user failed", "traceId", traceID, "err", err)
				http.Error(w, "internal error", http.StatusInternalServerError)
				return
			}
		}
		if _, err := h.q.CreateOAuthAccount(ctx, db.CreateOAuthAccountParams{
			UserID:     user.ID,
			Provider:   provider,
			ProviderID: providerID,
		}); err != nil {
			slog.ErrorContext(ctx, "link oauth account failed", "traceId", traceID, "err", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
	}

	if user.TotpEnabled {
		mfaToken, err := NewMFAToken(user.ID.String(), h.secret)
		if err != nil {
			slog.ErrorContext(ctx, "mfa token generation failed", "traceId", traceID, "err", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, frontendURL+"/auth/mfa?mfa_token="+mfaToken, http.StatusFound)
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
		Path:     "/",
		MaxAge:   int(RefreshTokenTTL.Seconds()),
	})

	http.Redirect(w, r, frontendURL+"/auth/callback?access_token="+accessToken, http.StatusFound)
}
