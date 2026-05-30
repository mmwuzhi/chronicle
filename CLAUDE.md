# Chronicle

Personal productivity OS. Capture text, images, and voice; track time on tasks; generate weekly reports; share progress as a public changelog.

## Tech Stack

- Frontend: Vite + TanStack Router + TanStack Query, Radix UI primitives, Recharts, React Hook Form + Zod
- Backend: Go — chi router, huma v2 (OpenAPI-first), slog structured logging
- Database: PostgreSQL (Neon in prod, Docker in dev) — sqlc + pgx, goose migrations
- Cache / rate limit: Redis (Upstash in prod, Docker in dev) — go-redis
- Auth: JWT — access token 15 min, refresh token 30 days, httpOnly cookies
- File storage: Cloudflare R2 (images + audio)
- Voice transcription: OpenAI Whisper (optional — app works without it)
- E2E type safety: huma → `/openapi.json` → orval codegen → typed TanStack Query hooks
- CI/CD: GitHub Actions → Fly.io (API) + Cloudflare Pages (frontend)

## Key Paths

- `api/` — Go backend
- `api/cmd/server/main.go` — entry point
- `api/internal/middleware/` — trace ID injection, auth guard, rate limiter, request logger
- `api/internal/config/config.go` — envconfig struct; process exits on invalid env at startup
- `api/db/migrations/` — goose SQL migration files, never edit by hand
- `api/db/queries/` — sqlc `.sql` query files (source of truth for DB queries)
- `api/db/sqlc/` — generated Go code from sqlc, never edit by hand
- `web/` — Vite frontend
- `web/src/api/` — orval-generated TanStack Query hooks, never edit by hand
- `web/src/routes/` — TanStack Router file-based routes
- `web/src/components/` — shared components; `ui/` for Radix primitives, `settings/` for settings sections
- `web/src/constants/` — shared constants (e.g. `status.ts`)
- `web/src/utils/` — shared pure utilities (e.g. `format.ts`)
- `web/src/lib/` — non-React helpers (axios client, authenticated fetch)
- `.env.example` — all required env vars

## Data Model

```
users           id, email, password_hash, created_at
projects        id, user_id, name, color, archived, created_at
tasks           id, user_id, project_id, title, type, status, due_at, created_at, deleted_at
time_blocks     id, task_id, user_id, started_at, ended_at, duration_sec
log_entries     id, task_id, user_id, body, created_at, deleted_at
captures        id, user_id, raw_text, media_url, media_type, classified_as, created_at
weekly_reports  id, user_id, week_start, data jsonb, created_at
public_shares   id, report_id, slug, created_at
refresh_tokens  id, user_id, token_hash, expires_at, revoked
```

Soft delete only — `tasks` and `log_entries` have `deleted_at`. Never issue a hard DELETE on user data.

## Common Commands

Most things have a `make` shortcut — run `make help` from the repo root to see all targets.

```bash
# First-time local setup
make setup                        # copies .env.example → .env, starts postgres + redis, runs migrations
# then edit .env to fill in real secrets (R2, JWT, etc.)
make api                          # run API server

# Daily dev
make dev                          # full stack via docker compose watch
make dev-data                     # just postgres + redis
make down                         # stop all dev containers
make api                          # API server only — auto-starts postgres + redis if needed
make web                          # Vite dev server only (separate terminal)

# Codegen
make sqlc                         # regenerate api/db/sqlc/ from db/queries/*.sql
make orval                        # regenerate web/src/api/ from API's OpenAPI spec
                                  # (API server must be running)

# Go backend (run from api/)
go test -p 1 ./...                # all tests (serial: packages share TEST_DATABASE_URL)
go vet ./...                      # vet

# Migrations
make migrate                      # apply pending migrations
make migrate-new name=add_foo     # create a new migration file

# Frontend (run from web/)
pnpm build                        # production build
pnpm typecheck                    # tsc --noEmit
pnpm test                         # vitest
```

## Conventions

- **All DB queries live in `api/db/queries/*.sql`.** sqlc generates the Go code. Never write raw SQL in Go files.
- **All route input/output types are defined on the huma route.** huma auto-generates the OpenAPI spec. Swagger UI is at `/docs`.
- **Every log line from the API includes `traceId`.** Get it from context — never generate a new one mid-request.
- **Soft delete only.** Set `deleted_at = now()`. Never run a hard DELETE on user data tables.
- **Rate limiting runs before auth.** Per-IP for public routes, per-user for authenticated routes.
- **Never edit generated files.** `api/db/sqlc/` and `web/src/api/` are codegen output. Run `sqlc generate` or `pnpm orval` instead.
- **Prefix huma handler I/O types with the resource name.** huma uses a global schema registry — `CreateInput` in two packages collides. Use `ProjectCreateInput`, `TaskCreateInput`, etc.
- **Run `/check` before every `git push`.** Steps in order:

  ```bash
  # API
  cd api
  go fmt ./...                    # format — run first
  go vet ./...                    # vet — fix all issues
  staticcheck ./...               # linter
  go test -p 1 ./...              # tests must pass (serial: packages share TEST_DATABASE_URL)

  # Frontend
  cd web
  pnpm format                     # Prettier
  pnpm lint                       # ESLint — errors block push, warnings are acceptable
  pnpm typecheck                  # no errors allowed
  pnpm test                       # vitest must pass
  pnpm build                      # catches module resolution errors tsc misses
  ```

  Fix every failure before pushing. CI runs these same steps exactly.

- **Route files are orchestration only.** They may declare data-fetching hooks, layout structure, and event handlers. Target < 250 lines. Any sub-component longer than 60 lines must live in its own file under `web/src/components/`. Any constant or utility used in more than one file must move to `web/src/constants/` or `web/src/utils/` on the second use.
- **Coding rules are in [`CODING.md`](./CODING.md).** Read it before writing new code.

## Environment

Copy `.env.example` to `.env`. The API reads env vars through `api/internal/config/config.go` using envconfig — process exits immediately if any required variable is missing or invalid. No silent fallbacks.
