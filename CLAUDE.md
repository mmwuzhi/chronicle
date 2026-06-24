# Chronicle

Capture anything.
Find it later.

Chronicle is a capture-first personal memory system.

The primary purpose of Chronicle is helping users find information they have already captured.

Capture First means:

- Record first.
- Organize later.
- Retrieve when needed.

Everything starts as a capture.

Search and retrieval are more important than automatic organization.

AI should enhance retrieval and recall, not replace them.

Users should never need to decide:

- Is this a note?
- Is this a task?
- Is this a project?
- Is this a context?

Users only need to decide:

- I want to remember this.

Everything starts as a Capture.

Core loop:

Capture
↓
Store
↓
Retrieve
↓
Understand (optional)

Search and retrieval are more important than automatic organization.

AI should enhance memory retrieval, not replace it.

## Product Guardrails

Chronicle should reduce maintenance, not create maintenance.

Prefer:

- capture
- search
- retrieval
- memory recall
- review
- related captures

Avoid:

- complex project management
- workflow automation
- deep hierarchies
- mandatory categorization
- manual organization requirements

When uncertain:

Choose the simpler solution.

## Current Priorities

P0

- Fast capture
- Full-text search
- Embeddings
- Hybrid retrieval

P1

- Related captures
- Memory retrieval
- Review

P2

- AI summaries
- Context discovery
- Forget suggestions

Deferred

- MCP
- Plugin systems
- Graph view
- Advanced analyzers
- Agent workflows
- E2EE

Do not introduce deferred features unless explicitly requested.

## Tech Stack

- Frontend: Vite + TanStack Router + TanStack Query, Radix UI primitives, Recharts, React Hook Form + Zod
- Backend: Go — chi router, huma v2 (OpenAPI-first), slog structured logging
- Desktop: Swift macOS menu bar app for quick capture
- Database: PostgreSQL (Neon in prod, Docker in dev) — sqlc + pgx, goose migrations
- Cache / rate limit: Redis (Upstash in prod, Docker in dev) — go-redis
- Auth: JWT — access token 15 min, refresh token 30 days, httpOnly cookies; email verification/password reset, Google/GitHub OAuth, passkeys, and TOTP MFA
- File storage: Cloudflare R2 (images + audio)
- Voice transcription: OpenAI Whisper (optional — app works without it)
- AI polish: Gemini/OpenAI-backed enrichment endpoints (optional — app works without it)
- Email: Resend for verification and password reset (optional locally)
- Bot protection: Cloudflare Turnstile on registration when configured
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
- `desktop/` — Swift macOS menu bar quick-capture app
- `desktop/Sources/ChronicleDesktopCore/` — testable capture payload, API client, queue, and path helpers
- `desktop/Sources/ChronicleDesktop/` — AppKit menu bar UI, global hotkey, settings, and quick-capture panel
- `web/` — Vite frontend
- `web/src/api/` — orval-generated TanStack Query hooks, never edit by hand
- `web/src/routes/` — TanStack Router file-based routes
- `web/src/components/` — shared components; `ui/` for Radix primitives, `settings/` for settings sections
- `web/src/constants/` — shared constants (e.g. `status.ts`)
- `web/src/utils/` — shared pure utilities (e.g. `format.ts`)
- `web/src/lib/` — non-React helpers (axios client, authenticated fetch)
- `TODO.md` — deferred work; refactor oversized route files before adding reminder/digest features
- `.env.example` — all required env vars

## Conceptual Model

Current database tables reflect historical implementation details.

Conceptually:

Capture is the primary object.

Everything else is derived from captures.

Examples:

Capture
↓
Task (actionable capture)

Capture
↓
Context (group of related captures)

Capture
↓
Review

Capture
↓
Summary

Capture
↓
Analyzer

Do not assume the current schema represents the final product model.

## Data Model

Current implementation:

```
users           id, email, password_hash, created_at, email_verified, email_verify_token, password_reset_token, password_reset_expires, totp_secret, totp_enabled
projects        id, user_id, name, color, archived, created_at
tasks           id, user_id, project_id, title, type, status, due_at, created_at, deleted_at, media_url, media_type
time_blocks     id, task_id, user_id, started_at, ended_at, duration_sec
log_entries     id, task_id, user_id, body, created_at, deleted_at
captures        id, user_id, raw_text, media_url, media_type, classified_as, source, created_at
weekly_reports  id, user_id, week_start, data jsonb, created_at
public_shares   id, report_id, slug, created_at
refresh_tokens  id, user_id, token_hash, expires_at, revoked
oauth_accounts  id, user_id, provider, provider_id, created_at
passkeys        id, user_id, credential_id, public_key, aaguid, sign_count, name, created_at
recovery_codes  id, user_id, code_hash, used
```

Notes:

- captures are the conceptual center of the system.
- all long-term value should originate from captures.
- tasks are actionable captures.
- projects are expected to evolve toward contexts.
- existing tables are implementation details, not product direction.

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
make desktop-capture              # Swift macOS menu bar quick-capture app

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

# Desktop (run from desktop/)
swift test                        # Swift core tests
swift build                       # compile the menu bar app
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

  # Desktop
  cd ../desktop
  swift test                      # core tests must pass
  swift build                     # app must compile
  ```

  Fix every failure before pushing. CI runs these same steps exactly.

- **Route files are orchestration only.** They may declare data-fetching hooks, layout structure, and event handlers. Target < 250 lines. Any sub-component longer than 60 lines must live in its own file under `web/src/components/`. Any constant or utility used in more than one file must move to `web/src/constants/` or `web/src/utils/` on the second use.
- **Coding rules are in [`CODING.md`](./CODING.md).** Read it before writing new code.

## Environment

Copy `.env.example` to `.env`. The API reads env vars through `api/internal/config/config.go` using envconfig — process exits immediately if any required variable is missing or invalid. No silent fallbacks.

Feature integrations are optional unless the code path is used: R2 enables uploads, Resend enables email verification/reset, OAuth vars enable Google/GitHub auth, Turnstile vars enable registration bot checks, WebAuthn vars configure passkeys, and OpenAI/Gemini keys enable AI features.
