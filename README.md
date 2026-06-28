# Chronicle

Capture anything.
Find it later.

Chronicle is a capture-first personal memory system designed to help people remember ideas, thoughts, tasks, observations, and life events without requiring manual organization.

Instead of forcing users to structure information up front, Chronicle focuses on fast capture, powerful retrieval, and long-term memory.

## Features

- Fast capture for text, images, and audio
- Native macOS quick capture app
- [iOS quick capture](docs/ios-quick-capture.md) from the Action Button via a create-only token
- Full-text search
- Semantic search
- Related capture discovery
- Voice transcription
- AI-assisted memory retrieval
- Optional task extraction

## Tech Stack

| Layer | Choice |
|---|---|
| Frontend | Vite + React + TanStack Router + TanStack Query |
| Backend | Go + chi + huma v2 (OpenAPI-first) |
| Desktop input | Swift macOS menu bar app |
| Database | PostgreSQL — sqlc + pgx, goose migrations |
| Cache / rate limit | Redis (Upstash in prod) |
| Auth | JWT — 15m access token + 30d refresh token, httpOnly cookies |
| File storage | Cloudflare R2 for image/audio uploads |
| Email | Resend for verification and password reset |
| AI | OpenAI `gpt-4o-mini-transcribe` for voice transcription; Gemini/OpenAI-backed polish endpoints |
| CI/CD | GitHub Actions → Fly.io (API) + Cloudflare Pages (frontend) |

Type safety flows end-to-end: Go structs → huma generates `/openapi.json` → orval generates TypeScript types + TanStack Query hooks.

## Local Setup

**Prerequisites:** Docker or OrbStack, Go 1.26+, Node 22+, pnpm 11+, just

```bash
# 1. Clone and copy env
git clone https://github.com/mmwuzhi/chronicle
cd chronicle
make setup          # copies .env.example → .env, starts postgres + redis, runs migrations

# 2. Fill in secrets
#    Edit .env — JWT_SECRET is required; feature integrations are optional for local dev

# 3. Start everything
make dev            # full stack via docker compose watch
make dev-all        # reload desktop app, then start docker compose watch
```

Root commands are implemented in `Justfile`; `Makefile` is a compatibility shim, so `make dev` and `just dev` are equivalent.

Or run services separately:

```bash
make dev-data       # postgres + redis only
make api            # Go server on :8080 (auto-starts db if needed)
make web            # Vite dev server on :5173
make desktop-capture # macOS menu bar quick-capture app
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
pnpm test
pnpm build

# Desktop quick capture (from desktop/)
swift test
swift run ChronicleDesktop
```

Full check before pushing:

```bash
# API
(cd api && go fmt ./... && go vet ./... && staticcheck ./... && go test -p 1 ./...)

# Frontend
(cd web && pnpm format && pnpm lint && pnpm typecheck && pnpm test && pnpm build)

# Desktop
(cd desktop && swift test && swift build)
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
├── desktop/
│   └── Sources/          # Swift macOS menu bar quick-capture app
├── docs/
│   └── ios-quick-capture.md  # iOS Action Button / Share Sheet setup guide
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
| `OPENAI_API_KEY` | no | Background transcription for recordings up to five minutes |
| `OPENAI_BASE_URL` | no | OpenAI-compatible API base; defaults to `https://api.openai.com/v1` |
| `OPENAI_TRANSCRIPTION_MODEL` | no | Audio transcription model; defaults to `gpt-4o-mini-transcribe` |
| `GEMINI_API_KEY` | no | AI polish/enrichment |
| `RESEND_API_KEY` | no | Verification and password reset email |
| `GOOGLE_CLIENT_*` | no | Google OAuth login/linking |
| `GITHUB_CLIENT_*` | no | GitHub OAuth login/linking |
| `TURNSTILE_SECRET_KEY` | no | Server-side Cloudflare Turnstile verification |
| `WEBAUTHN_RP_*` | no | Passkey relying-party ID and origin |
| `VITE_API_URL` | no | Frontend API base URL; defaults to `/api` if omitted |
| `VITE_TURNSTILE_SITE_KEY` | no | Frontend Turnstile site key for registration |

## Product Direction

Chronicle follows a capture-first philosophy.

Core loop:

Capture
↓
Store
↓
Retrieve
↓
Understand

Chronicle is not a traditional note-taking app.

Chronicle is not a project management tool.

Chronicle is a personal memory system focused on retrieval and recall.

The most important feature is not AI.

The most important feature is helping users find something they once thought, wrote, or experienced.

AI is used to improve retrieval, review, and memory recall.

Users should never be required to maintain a complex organizational system.

## Future Work

Deferred product work lives in [`TODO.md`](./TODO.md). Refactor oversized route files first, then revisit weekly digest emails and due-date reminders.

## Principles

### Capture First

Record now.
Organize later.

### Retrieval Over Organization

Finding a memory is more important than categorizing it.

### Evidence Over AI

Chronicle should prefer showing original captures over only AI-generated conclusions.

### AI Suggests, Humans Decide

AI may suggest.
Users remain in control.

### No Maintenance

Users should not maintain the system.

The system should maintain itself whenever possible.
