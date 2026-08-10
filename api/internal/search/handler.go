package search

import (
	"github.com/danielgtaylor/huma/v2"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

// Register wires the recall surface: hybrid semantic search (/find) and
// query-time analysis (/ask). Captures are the only searchable entity now;
// keyword FTS over captures (SearchCaptures) remains as the /find fallback.
func Register(api huma.API, pool *pgxpool.Pool, rag *ragclient.Client, authMW func(huma.Context, func(huma.Context))) {
	registerRecall(api, pool, db.New(pool), rag, authMW)
}
