# Chronicle

Personal productivity OS. Capture text, images, and voice; track time on tasks; generate weekly reports; share progress as a public changelog.

## Features

- **Capture inbox** — save text, images, and audio; classify later as task / idea / routine / log
- **Task management** — projects, status cycles, due dates, attachments, markdown notes, and AI title polish
- **Time tracking** — add manual duration entries per task and review time history
- **Log entries** — attach markdown-formatted notes to any task
- **Weekly reports** — generate summaries with charts and shareable public URLs
- **Auth and security** — email verification, password reset, Google/GitHub OAuth, passkeys, MFA, account deletion, and optional Turnstile bot protection

## Tech Stack

| Layer | Choice |
|---|---|
| Frontend | Vite + React + TanStack Router + TanStack Query |
| Backend | Go + chi + huma v2 (OpenAPI-first) |
| Database | PostgreSQL — sqlc + pgx, goose migrations |
| Cache / rate limit | Redis (Upstash in prod) |
| Auth | JWT — 15m access token + 30d refresh token, httpOnly cookies |
| File storage | Cloudflare R2 for image/audio uploads |
| Email | Resend for verification and password reset |
| AI | OpenAI Whisper for transcription; Gemini/OpenAI-backed polish endpoints |
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
#    Edit .env — JWT_SECRET is required; feature integrations are optional for local dev

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
        ├── components/    # ui/ for Radix primitives, settings/ for settings sections
        ├── constants/     # shared constants (status cycles, colors)
        ├── utils/         # shared pure utilities (formatting)
        ├── lib/           # non-React helpers (axios client, authenticated fetch)
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

See `.env.example` for the full list. The API exits immediately on startup if a required variable is missing — no silent fallbacks.

Key variables:

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `REDIS_URL` | yes | Redis connection string |
| `JWT_SECRET` | yes | Secret for signing JWTs |
| `API_BASE_URL` | no | Public API base used for OAuth callback URLs |
| `FRONTEND_URL` | no | Frontend origin for CORS and email links |
| `R2_*` | no | Cloudflare R2 — needed for image/audio uploads |
| `OPENAI_API_KEY` | no | Voice transcription via Whisper |
| `GEMINI_API_KEY` | no | AI polish/enrichment |
| `RESEND_API_KEY` | no | Verification and password reset email |
| `GOOGLE_CLIENT_*` | no | Google OAuth login/linking |
| `GITHUB_CLIENT_*` | no | GitHub OAuth login/linking |
| `TURNSTILE_SECRET_KEY` | no | Server-side Cloudflare Turnstile verification |
| `WEBAUTHN_RP_*` | no | Passkey relying-party ID and origin |
| `VITE_API_URL` | no | Frontend API base URL; defaults to `/api` if omitted |
| `VITE_TURNSTILE_SITE_KEY` | no | Frontend Turnstile site key for registration |

## Future Work

Deferred product work lives in [`TODO.md`](./TODO.md). Refactor oversized route files first, then revisit weekly digest emails and due-date reminders.
