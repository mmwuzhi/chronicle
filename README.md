# Chronicle

Personal productivity tracker. Capture thoughts, track time on tasks, and generate weekly reports.

## Features

- **Capture inbox** — dump text quickly, classify later (task / idea / log)
- **Task management** — projects, status cycles, due dates
- **Time tracking** — start/stop timer per task, view history
- **Log entries** — attach notes to any task
- **Weekly reports** — auto-generated summaries with a shareable public URL

## Tech Stack

| Layer | Choice |
|---|---|
| Frontend | Vite + React + TanStack Router + TanStack Query |
| Backend | Go + chi + huma v2 (OpenAPI-first) |
| Database | PostgreSQL — sqlc + pgx, goose migrations |
| Cache / rate limit | Redis (Upstash in prod) |
| Auth | JWT — 15m access token + 30d refresh token, httpOnly cookies |
| CI/CD | GitHub Actions → Fly.io (API) + Cloudflare Pages (frontend) |

Type safety flows end-to-end: Go structs → huma generates `/openapi.json` → orval generates TypeScript types + TanStack Query hooks.

## Local Setup

**Prerequisites:** Docker, Go 1.26+, Node 22+, pnpm 11+

```bash
# 1. Clone and copy env
git clone https://github.com/mmwuzhi/chronicle
cd chronicle
make setup          # copies .env.example → .env, starts postgres + redis, runs migrations

# 2. Fill in secrets
#    Edit .env — JWT_SECRET is required; R2 and OpenAI keys are optional for local dev

# 3. Start everything
make dev            # full stack via docker compose watch
```

Or run services separately:

```bash
make dev-data       # postgres + redis only
make api            # Go server on :8080 (auto-starts db if needed)
make web            # Vite dev server on :5173
```

API docs: http://localhost:8080/docs (Swagger UI, auto-generated)

## Common Commands

```bash
# Codegen (run after changing Go route types or SQL queries)
make sqlc           # regenerate db/sqlc/ from db/queries/*.sql
make orval          # regenerate web/src/api/ from OpenAPI spec (API must be running)

# Migrations
make migrate                        # apply pending
make migrate-new name=add_foo       # create a new migration file

# Go (from api/)
go test -p 1 ./...                  # all tests (serial — packages share TEST_DATABASE_URL)
go vet ./...

# Frontend (from web/)
pnpm typecheck
pnpm lint
pnpm build
```

Full check before pushing:

```bash
# API
cd api && go fmt ./... && go vet ./... && staticcheck ./... && go test -p 1 ./...

# Frontend
cd web && pnpm format && pnpm lint && pnpm typecheck && pnpm build
```

## Project Structure

```
chronicle/
├── api/
│   ├── cmd/server/        # main.go — entry point
│   ├── internal/
│   │   ├── config/        # envconfig — exits on missing required vars
│   │   ├── middleware/    # trace ID, auth guard, rate limiter, request logger
│   │   └── */handler.go   # one package per resource (task, capture, project…)
│   ├── db/
│   │   ├── migrations/    # goose .sql files — never edit by hand
│   │   ├── queries/       # sqlc source — edit these to change queries
│   │   └── sqlc/          # generated Go code — never edit by hand
│   ├── Dockerfile
│   └── fly.toml
└── web/
    └── src/
        ├── api/           # orval-generated hooks — never edit by hand
        ├── components/
        └── routes/        # TanStack Router file-based routes
```

## Deployment

Pushes to `main` trigger the full pipeline automatically:

```
api-check → api-build (GHCR image) → api-deploy (Fly.io + goose migrations)
web-check → web-deploy (Cloudflare Pages)
```

Required GitHub secrets: `FLY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `NEON_DATABASE_URL`.

## Environment Variables

See `.env.example` for the full list. The API exits immediately on startup if any required variable is missing — no silent fallbacks.

Key variables:

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `REDIS_URL` | yes | Redis connection string |
| `JWT_SECRET` | yes | Secret for signing JWTs |
| `R2_*` | no | Cloudflare R2 — needed for image/voice captures |
| `OPENAI_API_KEY` | no | Voice transcription via Whisper |
