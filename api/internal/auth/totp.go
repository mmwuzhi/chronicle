package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/bcrypt"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

const MFATokenTTL = 5 * time.Minute

// --- MFA token ---

type MFAClaims struct {
	UserID string `json:"sub"`
	MFA    bool   `json:"mfa"`
}

func NewMFAToken(userID, secret string) (string, error) {
	return newTokenWithClaims(userID, secret, MFATokenTTL, true)
}

func ParseMFAToken(raw, secret string) (string, error) {
	claims, err := ParseAccessToken(raw, secret)
	if err != nil {
		return "", err
	}
	if !claims.MFA {
		return "", fmt.Errorf("not an MFA token")
	}
	return claims.UserID, nil
}

// --- setup TOTP ---

type TOTPSetupOutput struct {
	Body struct {
		Secret string `json:"secret"`
		URI    string `json:"uri"`
	}
}

func (h *handler) totpSetup(ctx context.Context, _ *struct{}) (*TOTPSetupOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if user.TotpEnabled {
		return nil, huma.Error400BadRequest("TOTP already enabled")
	}

	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      "Chronicle",
		AccountName: user.Email,
	})
	if err != nil {
		slog.ErrorContext(ctx, "failed to generate totp key", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if err := h.q.SetTOTPSecret(ctx, db.SetTOTPSecretParams{
		ID:         uid,
		TotpSecret: pgtype.Text{String: key.Secret(), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store totp secret", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &TOTPSetupOutput{}
	out.Body.Secret = key.Secret()
	out.Body.URI = key.URL()
	return out, nil
}

// --- enable TOTP ---

type TOTPEnableInput struct {
	Body struct {
		Code string `json:"code" minLength:"6" maxLength:"6"`
	}
}

type TOTPEnableOutput struct {
	Body struct {
		RecoveryCodes []string `json:"recoveryCodes"`
	}
}

func (h *handler) totpEnable(ctx context.Context, input *TOTPEnableInput) (*TOTPEnableOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if !user.TotpSecret.Valid {
		return nil, huma.Error400BadRequest("run setup first")
	}

	if !totp.Validate(input.Body.Code, user.TotpSecret.String) {
		return nil, huma.Error400BadRequest("invalid code")
	}

	if err := h.q.EnableTOTP(ctx, uid); err != nil {
		slog.ErrorContext(ctx, "failed to enable totp", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	// Generate recovery codes
	if err := h.q.DeleteRecoveryCodes(ctx, uid); err != nil {
		slog.ErrorContext(ctx, "failed to delete old recovery codes", "traceId", traceID, "err", err)
	}

	codes := make([]string, 8)
	for i := range codes {
		b := make([]byte, 4)
		if _, err := rand.Read(b); err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		codes[i] = hex.EncodeToString(b)
		hash, err := bcrypt.GenerateFromPassword([]byte(codes[i]), bcrypt.DefaultCost)
		if err != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		if err := h.q.CreateRecoveryCode(ctx, db.CreateRecoveryCodeParams{
			UserID:   uid,
			CodeHash: string(hash),
		}); err != nil {
			slog.ErrorContext(ctx, "failed to store recovery code", "traceId", traceID, "err", err)
			return nil, huma.Error500InternalServerError("internal error")
		}
	}

	out := &TOTPEnableOutput{}
	out.Body.RecoveryCodes = codes
	return out, nil
}

// --- disable TOTP ---

type TOTPDisableInput struct {
	Body struct {
		Password string `json:"password,omitempty"`
		Code     string `json:"code,omitempty"`
	}
}

func (h *handler) totpDisable(ctx context.Context, input *TOTPDisableInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if !user.TotpEnabled {
		return nil, huma.Error400BadRequest("TOTP not enabled")
	}

	// Require either password or TOTP code to disable
	authenticated := false
	if input.Body.Password != "" && user.PasswordHash.Valid {
		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash.String), []byte(input.Body.Password)); err == nil {
			authenticated = true
		}
	}
	if input.Body.Code != "" && user.TotpSecret.Valid {
		if totp.Validate(input.Body.Code, user.TotpSecret.String) {
			authenticated = true
		}
	}

	if !authenticated {
		return nil, huma.Error401Unauthorized("invalid password or code")
	}

	if err := h.q.DisableTOTP(ctx, uid); err != nil {
		slog.ErrorContext(ctx, "failed to disable totp", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if err := h.q.DeleteRecoveryCodes(ctx, uid); err != nil {
		slog.ErrorContext(ctx, "failed to delete recovery codes", "traceId", traceID, "err", err)
	}

	return nil, nil
}

// --- verify MFA ---

type MFAVerifyInput struct {
	Body struct {
		MFAToken string `json:"mfaToken"`
		Code     string `json:"code"`
	}
}

type MFAVerifyOutput struct {
	Body struct {
		AccessToken string `json:"accessToken"`
	}
}

func (h *handler) mfaVerify(ctx context.Context, input *MFAVerifyInput) (*MFAVerifyOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	if h.rdb != nil {
		r, _ := responseWriter(ctx)
		ip := clientIP(r)
		key := "mfa:ip:" + ip
		count, err := h.rdb.Incr(ctx, key).Result()
		if err == nil {
			if count == 1 {
				h.rdb.Expire(ctx, key, 15*time.Minute)
			}
			if count > 5 {
				return nil, huma.NewError(http.StatusTooManyRequests, "too many attempts, try again later")
			}
		}
	}

	userID, err := ParseMFAToken(input.Body.MFAToken, h.secret)
	if err != nil {
		return nil, huma.Error401Unauthorized("invalid or expired MFA token")
	}

	uid, err := uuid.Parse(userID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	verified := false

	// Try TOTP code
	if user.TotpSecret.Valid && totp.Validate(input.Body.Code, user.TotpSecret.String) {
		verified = true
	}

	// Try recovery code
	if !verified {
		codes, err := h.q.GetRecoveryCodes(ctx, uid)
		if err == nil {
			for _, rc := range codes {
				if rc.Used {
					continue
				}
				if err := bcrypt.CompareHashAndPassword([]byte(rc.CodeHash), []byte(input.Body.Code)); err == nil {
					verified = true
					_ = h.q.UseRecoveryCode(ctx, rc.ID)
					break
				}
			}
		}
	}

	if !verified {
		return nil, huma.Error401Unauthorized("invalid code")
	}

	accessToken, err := NewAccessToken(userID, h.secret)
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
		UserID:    uid,
		TokenHash: hashedRefresh,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(RefreshTokenTTL), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store refresh token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	setRefreshCookie(ctx, rawRefresh, RefreshTokenTTL)

	out := &MFAVerifyOutput{}
	out.Body.AccessToken = accessToken
	return out, nil
}
