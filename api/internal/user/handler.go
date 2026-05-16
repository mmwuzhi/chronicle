package user

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

type handler struct {
	q *db.Queries
}

func Register(api huma.API, pool *pgxpool.Pool, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{q: db.New(pool)}

	huma.Register(api, huma.Operation{
		OperationID: "deleteAccount",
		Method:      http.MethodDelete,
		Path:        "/users/me",
		Summary:     "Delete the authenticated user's account and all their data",
		Tags:        []string{"users"},
		Middlewares: huma.Middlewares{authMW},
	}, h.deleteAccount)
}

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
