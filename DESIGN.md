# Chronicle — Design Document

Personal productivity OS. Capture anything (text, image, voice), track time on tasks, generate weekly reports, share progress as a public changelog.

---

## Core Loop

```
Capture (text / image / voice)
    ↓ categorize (task / idea / routine / log)
Track (start/stop timer per task)
    ↓ accumulated time blocks
Summarize (daily → weekly report)
    ↓ shareable public URL
```

---

## Data Model

```
User
  └── Project
        └── Task
              ├── TimeBlock (start, end, duration)
              └── LogEntry  (daily note on this task)

Entry (raw capture) → classified into Task or LogEntry

WeeklyReport (auto-generated, public slug)
PublicShare   (slug → WeeklyReport, no auth required)
```

---

## Tech Stack

| Layer | Choice |
|-------|--------|
| Frontend | Vite + TanStack Router + TanStack Query |
| UI | Radix UI primitives + custom CSS + Recharts |
| Forms | React Hook Form + Zod |
| Backend | Go + chi + huma v2 |
| Database | PostgreSQL (Neon) |
| ORM / queries | sqlc + pgx |
| Migrations | goose |
| Cache / rate limit | Redis (Upstash) + go-redis |
| File storage | Cloudflare R2 |
| Auth | JWT — access token (15m) + refresh token (30d), httpOnly cookies |
| Logging | slog, JSON structured, trace ID on every line |
| Config | envconfig — process exits on invalid env at startup |
| E2E type safety | huma → OpenAPI spec → orval → typed TanStack Query hooks |
| CI/CD | GitHub Actions → Fly.io (API) + Cloudflare Pages (frontend) |

---

## End-to-End Type Safety Chain

```
Go struct (huma route definition)
    → huma auto-generates OpenAPI spec (/openapi.json)
    → orval reads spec at codegen time
    → generates TypeScript types + TanStack Query hooks
    → frontend imports and calls hooks — fully typed, no manual sync
```

Run codegen: `pnpm orval` (reads `orval.config.ts` → outputs to `src/api/`)

---

## Backend Architecture

### Middleware Chain (chi)

```
RequestID  →  Logger  →  CORS  →  RateLimit  →  Auth  →  Handler
```

Every request gets an `x-request-id` injected at the top. All downstream middleware and handlers receive a context-scoped `slog` child logger that includes `traceId`. This means every log line — across the entire request lifecycle — carries the same trace ID.

### Rate Limiting

Redis sliding window. Per-user, 100 req/min. Returns `429` with `Retry-After` header. Unauthenticated requests rate-limited by IP.

### Structured Logging

```go
// Every log line looks like this:
{"time":"...","level":"INFO","traceId":"abc-123","userId":"u_xyz","msg":"time block created","taskId":"t_456","duration":3600}
```

### Environment Config

```go
type Config struct {
    DatabaseURL  string `env:"DATABASE_URL,required"`
    RedisURL     string `env:"REDIS_URL,required"`
    JWTSecret    string `env:"JWT_SECRET,required"`
    R2BucketName string `env:"R2_BUCKET_NAME,required"`
    R2AccountID  string `env:"R2_ACCOUNT_ID,required"`
    R2AccessKey  string `env:"R2_ACCESS_KEY,required"`
    R2SecretKey  string `env:"R2_SECRET_KEY,required"`
    OpenAIKey    string `env:"OPENAI_API_KEY"` // optional — voice transcription
    Port         string `env:"PORT" envDefault:"8080"`
}
```

Process exits immediately if any required variable is missing.

### OpenAPI Docs

`GET /docs` — Swagger UI, auto-generated from huma route definitions. No manual spec maintenance.

---

## API Surface

### Auth
```
POST /auth/register
POST /auth/login
POST /auth/refresh
POST /auth/logout
```

### Capture
```
POST /captures              — create raw entry (text / image / voice)
GET  /captures              — list recent captures
```

Voice capture flow: client records audio blob → `POST /captures` with `multipart/form-data` → Go uploads to R2 → calls OpenAI Whisper → stores transcript as entry text.

### Tasks
```
GET    /tasks
POST   /tasks
GET    /tasks/:id
PATCH  /tasks/:id
DELETE /tasks/:id
```

### Time Tracking
```
POST   /tasks/:id/timers/start
POST   /tasks/:id/timers/stop
GET    /tasks/:id/timers
POST   /timers              — manual entry (start + end provided)
DELETE /timers/:id
```

### Projects
```
GET    /projects
POST   /projects
PATCH  /projects/:id
DELETE /projects/:id
```

### Reports
```
GET /reports/weekly?week=2026-W18   — auto-generate or return cached
GET /reports/monthly?month=2026-05
```

Weekly report generation: DB query → aggregate time blocks → summarize log entries → store result in Redis (TTL 1h). Cache invalidated on any new time block write.

### Public Sharing
```
POST /reports/:id/share             — create public slug
GET  /public/:slug                  — no auth, returns report JSON
```

The public share route is also handled by the Go server as a thin HTML template with OG meta tags (title, description, image), so shared links render previews in Slack / WeChat / iMessage. The SPA then hydrates on top.

### Dashboard
```
GET /dashboard/summary              — time by project this week
GET /dashboard/heatmap?year=2026    — GitHub-style activity heatmap data
GET /dashboard/completion           — task completion rate over time
```

---

## Database Schema (overview)

```sql
users           (id, email, password_hash, created_at)
projects        (id, user_id, name, color, archived, created_at)
tasks           (id, user_id, project_id, title, type, status, due_at, created_at)
time_blocks     (id, task_id, user_id, started_at, ended_at, duration_sec)
log_entries     (id, task_id, user_id, body, created_at)
captures        (id, user_id, raw_text, media_url, media_type, classified_as, created_at)
weekly_reports  (id, user_id, week_start, data jsonb, created_at)
public_shares   (id, report_id, slug, created_at)
refresh_tokens  (id, user_id, token_hash, expires_at, revoked)
```

Migrations managed by goose in `db/migrations/`. Each migration is a numbered `.sql` file (`001_init.sql`, `002_add_captures.sql`, …).

---

## Frontend Structure

```
src/
  api/          ← orval-generated (do not edit manually)
  components/
    ui/         ← Radix-based primitives (Button, Dialog, etc.)
    charts/     ← Recharts wrappers
    layout/     ← AppShell, Sidebar, Header
  routes/       ← TanStack Router file-based routes
    _auth/      ← protected routes
    public/     ← share pages (no auth)
  stores/       ← Zustand (timer running state, active task)
  lib/
    auth.ts
    r2.ts
```

Timer state (is a timer running, which task, elapsed time) lives in a Zustand store — it's client-only state that TanStack Query doesn't own.

---

## CI/CD Pipeline (GitHub Actions)

```yaml
on: push (main)

jobs:
  validate:
    - go vet + staticcheck
    - pnpm typecheck
    - pnpm test (vitest)
    - go test ./...

  build-api:
    needs: validate
    - docker build → push to GHCR (ghcr.io/<user>/chronicle-api)

  deploy-api:
    needs: build-api
    - flyctl deploy --image ghcr.io/<user>/chronicle-api:$SHA
    - goose -dir db/migrations postgres $DATABASE_URL up

  deploy-frontend:
    needs: validate
    - pnpm build
    - Cloudflare Pages deploy (wrangler pages deploy dist/)
```

Secrets stored in GitHub Actions: `FLY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`, `DATABASE_URL` (for migration step).

---

## Local Development

```
docker-compose.yml:
  api        — Go (hot reload via air)
  frontend   — Vite dev server
  postgres   — local DB
  redis      — local Redis
```

`.env` files per service. `envconfig` validates on startup — if you forget a variable, you'll know immediately before writing any code.

Codegen: `pnpm orval` regenerates the API client whenever the Go server's OpenAPI spec changes.

---

## Directory Structure

```
chronicle/
  api/                  — Go backend
    cmd/server/         — main.go
    internal/
      auth/
      capture/
      task/
      timer/
      report/
      middleware/       — trace ID, rate limit, auth
      storage/          — R2 client
      db/               — sqlc generated code
    db/
      migrations/       — goose .sql files
      queries/          — sqlc .sql query files
    Dockerfile
    fly.toml

  web/                  — Vite frontend
    src/
      api/              — orval generated
      components/
      routes/
      stores/
      lib/
    orval.config.ts
    vite.config.ts

  docker-compose.yml
  .github/
    workflows/
      deploy.yml
  DESIGN.md
```

---

## Resume Talking Points

- **End-to-end type safety without shared runtime**: Go types flow to the frontend via OpenAPI + orval codegen — no TypeScript backend required
- **Trace ID propagation**: every log line across middleware, handler, and DB query carries the same request ID — production-grade observability pattern
- **Redis dual use**: sliding-window rate limiter and report cache invalidation — two distinct patterns on one instance
- **sqlc over ORM**: write SQL, get type-safe Go — conscious tradeoff, shows understanding of what an ORM buys and costs
- **Public share with OG meta**: Go serves a thin SSR-like HTML template for the share URL so social previews work, SPA hydrates on top — no Node.js server needed
- **goose migrations in CI**: schema migrations run as a deploy step, not manually — demonstrates production deployment thinking

---

## Phase 2 (out of scope for MVP)

- AI auto-categorization of captures (OpenAI Chat API)
- PWA / offline mode
- Calendar sync (Google Calendar export)
- Public profile page (`/u/:username`)

---

## Planned Features (deferred, not forgotten)

### i18n — Chinese (zh) + Japanese (ja)

**Decision**: use `react-i18next` (industry standard, not hand-rolled).
**Deferred because**: page structure is still changing rapidly; extracting strings now means re-extracting them again after each new page.
**Do it when**: page layout has stabilized (no new routes expected in the next sprint).

Implementation plan:
1. `pnpm add react-i18next i18next i18next-browser-languagedetector`
2. Create `web/public/locales/zh/translation.json` and `web/public/locales/ja/translation.json`
3. Init i18next in `web/src/main.tsx` with `LanguageDetector` (reads browser language, falls back to `zh`)
4. Replace all UI string literals with `t('key')` across all route files
5. Language switcher component in the nav bar (stores preference in localStorage)
6. Add `i18next-parser` to CI to catch missing keys at build time

### Settings / My Page

**Account deletion**: `DELETE /users/me` endpoint — hard deletes the user row (cascade to all user data). Frontend: `/settings` route with confirmation dialog. Planned for next sprint.

