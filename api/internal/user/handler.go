package user

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type handler struct {
	q *db.Queries
}

func Register(api huma.API, pool *pgxpool.Pool, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool)}

	huma.Register(api, huma.Operation{
		OperationID: "getMe",
		Method:      http.MethodGet,
		Path:        "/users/me",
		Summary:     "Get the authenticated user's profile",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.getMe)

	huma.Register(api, huma.Operation{
		OperationID: "changePassword",
		Method:      http.MethodPut,
		Path:        "/users/me/password",
		Summary:     "Change or set password",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.changePassword)

	huma.Register(api, huma.Operation{
		OperationID: "listOAuthAccounts",
		Method:      http.MethodGet,
		Path:        "/users/me/oauth-accounts",
		Summary:     "List linked OAuth accounts",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.listOAuthAccounts)

	huma.Register(api, huma.Operation{
		OperationID: "unlinkOAuthAccount",
		Method:      http.MethodDelete,
		Path:        "/users/me/oauth-accounts/{id}",
		Summary:     "Unlink an OAuth account",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.unlinkOAuthAccount)

	huma.Register(api, huma.Operation{
		OperationID: "deleteAccount",
		Method:      http.MethodDelete,
		Path:        "/users/me",
		Summary:     "Delete the authenticated user's account and all their data",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.deleteAccount)
}

// --- get me ---

type OAuthAccountInfo struct {
	ID       string `json:"id"`
	Provider string `json:"provider"`
}

type UserMeOutput struct {
	Body struct {
		ID            string             `json:"id"`
		Email         string             `json:"email"`
		HasPassword   bool               `json:"hasPassword"`
		OAuthAccounts []OAuthAccountInfo `json:"oauthAccounts"`
		TotpEnabled   bool               `json:"totpEnabled"`
		EmailVerified bool               `json:"emailVerified"`
		CreatedAt     string             `json:"createdAt"`
	}
}

func (h *handler) getMe(ctx context.Context, _ *struct{}) (*UserMeOutput, error) {
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

	oauthRows, err := h.q.GetOAuthAccountsByUserID(ctx, user.ID)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get oauth accounts", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	accounts := make([]OAuthAccountInfo, 0, len(oauthRows))
	for _, oa := range oauthRows {
		accounts = append(accounts, OAuthAccountInfo{
			ID:       oa.ID.String(),
			Provider: oa.Provider,
		})
	}

	out := &UserMeOutput{}
	out.Body.ID = user.ID.String()
	out.Body.Email = user.Email
	out.Body.HasPassword = user.PasswordHash.Valid
	out.Body.OAuthAccounts = accounts
	out.Body.TotpEnabled = user.TotpEnabled
	out.Body.EmailVerified = user.EmailVerified
	if user.CreatedAt.Valid {
		out.Body.CreatedAt = user.CreatedAt.Time.Format(time.RFC3339)
	}
	return out, nil
}

// --- change password ---

type UserChangePasswordInput struct {
	Body struct {
		CurrentPassword string `json:"currentPassword,omitempty"`
		NewPassword     string `json:"newPassword" minLength:"8"`
	}
}

func (h *handler) changePassword(ctx context.Context, input *UserChangePasswordInput) (*struct{}, error) {
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

	if user.PasswordHash.Valid {
		if input.Body.CurrentPassword == "" {
			return nil, huma.Error400BadRequest("current password is required")
		}
		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash.String), []byte(input.Body.CurrentPassword)); err != nil {
			return nil, huma.Error401Unauthorized("current password is incorrect")
		}
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(input.Body.NewPassword), bcrypt.DefaultCost)
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

// --- list oauth accounts ---

type UserListOAuthAccountsOutput struct {
	Body struct {
		Accounts []OAuthAccountInfo `json:"accounts"`
	}
}

func (h *handler) listOAuthAccounts(ctx context.Context, _ *struct{}) (*UserListOAuthAccountsOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	rows, err := h.q.GetOAuthAccountsByUserID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get oauth accounts", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	accounts := make([]OAuthAccountInfo, 0, len(rows))
	for _, oa := range rows {
		accounts = append(accounts, OAuthAccountInfo{
			ID:       oa.ID.String(),
			Provider: oa.Provider,
		})
	}

	out := &UserListOAuthAccountsOutput{}
	out.Body.Accounts = accounts
	return out, nil
}

// --- unlink oauth account ---

type UserUnlinkOAuthAccountInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) unlinkOAuthAccount(ctx context.Context, input *UserUnlinkOAuthAccountInput) (*struct{}, error) {
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

	oauthRows, err := h.q.GetOAuthAccountsByUserID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get oauth accounts", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if !user.PasswordHash.Valid && len(oauthRows) <= 1 {
		return nil, huma.Error400BadRequest("cannot unlink your only login method; set a password first")
	}

	accountID, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error400BadRequest("invalid account id")
	}

	if err := h.q.DeleteOAuthAccount(ctx, db.DeleteOAuthAccountParams{
		ID:     accountID,
		UserID: uid,
	}); err != nil {
		slog.ErrorContext(ctx, "failed to unlink oauth account", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	return nil, nil
}

// --- delete account ---

func (h *handler) deleteAccount(ctx context.Context, _ *struct{}) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	if err := h.q.DeleteUser(ctx, uid); err != nil {
		slog.ErrorContext(ctx, "failed to delete user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	return nil, nil
}
