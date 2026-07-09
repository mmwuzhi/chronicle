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
- Desktop: Swift macOS menu bar app — quick capture/search/ask panel, browse window, offline local search, desktop stickies, reminder notifications
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
- `desktop/Sources/ChronicleDesktopCore/` — testable capture payload, API client, queue, path helpers, and on-device offline semantic search (local Ollama embedder + SQLite vector cache)
- `desktop/Sources/ChronicleDesktop/` — AppKit menu bar UI, global hotkey, quick panel, main window, capture detail windows, pinned stickies, reminder notifications, settings
- `web/` — Vite frontend
- `web/src/api/` — orval-generated TanStack Query hooks, never edit by hand
- `web/src/routes/` — TanStack Router file-based routes
- `web/src/components/` — shared components; `ui/` for Radix primitives, `settings/` for settings sections
- `web/src/constants/` — shared constants (none yet; create on the second use of a constant)
- `web/src/utils/` — shared pure utilities (e.g. `format.ts`)
- `web/src/lib/` — non-React helpers (axios client, authenticated fetch)
- `TODO.md` — deferred work; the oversized-route-file gate is cleared (all routes are back under 250 lines)
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

Current implementation (post migration 016, which collapsed the old
projects/tasks/time_blocks/log_entries productivity model into captures, and
024, which replaced the classification enum with the todo facet):

```
users                id, email, password_hash, created_at, email_verified, email_verify_token, password_reset_token, password_reset_expires, totp_secret, totp_enabled
captures             id, user_id, raw_text, media_url, media_key, media_type, source, created_at, deleted_at,
                     transcript + transcription_* (Whisper/OCR pipeline; also holds link-fetched page text),
                     audio_duration_sec, link_url (link enrichment; 026),
                     remind_at, remind_hide (time-based recall),
                     todo_at, done_at (todo facet; CHECK done_at IS NULL OR todo_at IS NOT NULL)
capture_links        a_id, b_id, user_id, created_at  (undirected, a_id < b_id)
capture_attachments  external file references (Google Drive etc.)
capture_embeddings   per-chunk vector (RAG index; one row per (capture, chunk_idx) since 027, max-over-chunks at read)
capture_metadata     per-capture extracted JSONB (RAG index)
capture_tokens       create-only personal access tokens (iOS Shortcut / quick capture)
capture_webhooks     keyword/semantic outbound webhooks
rag_config           per-user RAG settings
refresh_tokens       id, user_id, token_hash, expires_at, revoked
oauth_accounts       id, user_id, provider, provider_id, created_at
passkeys             id, user_id, credential_id, public_key, aaguid, sign_count, name, created_at
recovery_codes       id, user_id, code_hash, used
archived_*           frozen pre-016 tables (tasks, log_entries, time_blocks, …) kept for recovery; never queried
```

Notes:

- captures are the conceptual center of the system; all long-term value originates from them.
- **The todo facet is not a classification, and the `#todo` text tag is its only entry point** (migration 025). A capture is a todo iff its raw text carries the standalone `#todo` token; completion is a parameter of the tag — `#todo(done)` / `#todo(done:YYYY-MM-DD)` — never a separate tag. Text is the source of truth: `todo_at`/`done_at` are derived on every save (parser + grammar in `api/internal/capture/todotag.go`) and only index the browse filter; `todo_at` records first entry and is never written into the text. Typing the tag flags, deleting the word unflags, editing the parameter completes — there is no todo endpoint and no todo button/checkbox; the only todo UI is the tag rendered as a chip in reading mode (`web/src/utils/rehype-todo-chip.ts`) and the `#` suggestion menu in the composer. The tag grammar is defined twice — Go (`todoTagRe` in `todotag.go`) and web (`TODO_TAG_RE` in `web/src/utils/todo.ts`) — and must change together. Capture time never asks what something is.
- **Classification values are behavior switches.** The old classified_as enum (task/idea/routine/log) was dropped in 024 because only "actionable" ever gated behavior. Add a new facet column only together with the behavior that needs it, never ahead of it.
- **Link enrichment reuses the transcript modality** (migration 026, `LINK_FETCH_ENABLED`, off by default). A text capture whose raw text contains a URL (grammar: `FirstURL` in `api/internal/capture/linkurl.go`, the single definition) has the page's readable text fetched into `transcript`, so it becomes findable by content — `transcript` already feeds the FTS index and the RAG embedding, so no search/embedding change is needed. Text is the source of truth (like the #todo tag): `reconcileLinkFetch` runs on create and on every raw_text edit — adding or changing the URL (re)enqueues a fetch, an unchanged URL is a no-op (never re-fetches), and editing the URL out clears the link-derived transcript (`ClearCaptureLinkFetch`). Scheduling reuses the `transcription_status` machine: a **link job is a capture with `media_key IS NULL`**, a media transcription has one, and the two workers partition the shared queue by that column (`ClaimPendingLinkFetch` vs `ClaimPendingTranscription`). The fetcher (`api/internal/linkfetch`) is SSRF-guarded (refuses private/loopback/link-local/metadata addresses, re-checked on every redirect hop), caps body size, and only accepts HTML. `link_url` is internal — it is not exposed on `CaptureBody`, and the web shows the transcript block for media captures only.
- User labels live in the text itself (`#tag` + full-text/semantic search), not in schema.
- A lightweight "project" = a pinned anchor capture + capture_links; progress ("n/m done") is derived at read time from the linked captures, never stored.
- existing tables are implementation details, not product direction.

Soft delete only — `captures` has `deleted_at`. Never issue a hard DELETE on user data. The one carve-out is the trash's explicit **permanent delete / empty trash**: a deliberate, trash-only user action on already-soft-deleted captures (the macOS "Recently Deleted" model), for content the user truly wants gone. Everything else stays soft.

## Common Commands

Most things are implemented in `Justfile`; `Makefile` is a compatibility shim.
Run `just --list` or `make help` from the repo root to see all targets.

```bash
# First-time local setup
make setup                        # copies .env.example → .env, starts postgres + redis, runs migrations
# then edit .env to fill in real secrets (R2, JWT, etc.)
make api                          # run API server

# Daily dev
make dev                          # full stack via docker compose watch
make dev-all                      # reload desktop app, then run docker compose watch
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

# RAG sidecar (run from ragsvc/)
python -m pytest                  # Python tests (use python -m so top-level imports resolve)
```

How changes reach the running dev stack:

- The api container is image-baked (`build: ./api`): a code change reaches it
  only while a `docker compose watch` session (`make dev`) is running to
  rebuild it, or via a manual `docker compose up -d --build api`. When in
  doubt, compare the image's `Created` time (`docker inspect`) with the source
  file's mtime.
- The web container bind-mounts `./web` and runs Vite — changes hot-reload,
  no rebuild ever.
- Migrations are never auto-applied to the dev DB (nothing runs goose at API
  startup): apply with `make migrate`. Tests are unaffected — `testutil`
  migrates the separate `chronicle_test` DB on every run.
- API liveness probe: `GET /health` → 200 `{"status":"ok"}` (mind the path —
  it is not `/healthz`; probing the wrong path and concluding "server down"
  has happened twice now). `GET /users/me` → 401 also proves routing + auth
  middleware are up.
- ragsvc tests need the project venv: run `.venv/bin/python -m pytest` from
  `ragsvc/` (a bare system python won't have pytest).

## Conventions

- **All DB queries live in `api/db/queries/*.sql`.** sqlc generates the Go code. Never write raw SQL in Go files.
- **All route input/output types are defined on the huma route.** huma auto-generates the OpenAPI spec. Swagger UI is at `/docs`.
- **Every log line from the API includes `traceId`.** Get it from context — never generate a new one mid-request.
- **Soft delete only.** Set `deleted_at = now()`. Never run a hard DELETE on user data tables. Sole exception: the trash's explicit permanent-delete / empty-trash on already-trashed captures (deliberate user action; FK `ON DELETE CASCADE` clears derived rows, R2 media purged best-effort).
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

  # RAG sidecar (run from ragsvc/)
  cd ../ragsvc
  python -m pytest                # Python tests must pass (use python -m, not bare pytest)
  ```

  Fix every failure before pushing. CI runs these same steps exactly.

- **Web/desktop identity parity.** The brand accent and the list-timestamp rule are each defined twice and must change together: accent as `--accent` in `web/src/index.css` and `Color.chronicleAccent` in `desktop/Sources/ChronicleDesktop/DesktopTheme.swift` (desktop deliberately does not follow the macOS system accent); the timestamp rule (relative under 7 days, then short date, year when it differs; precise stamp `Jul 4, 2026 · 2:35pm` on hover/tooltip) as `fmtListTime`/`fmtPreciseDateTime` in `web/src/utils/format.ts` and `CaptureTime` in `desktop/Sources/ChronicleDesktop/CaptureRowModel.swift`.
- **Route files are orchestration only.** They may declare data-fetching hooks, layout structure, and event handlers. Target < 250 lines. Any sub-component longer than 60 lines must live in its own file under `web/src/components/`. Any constant or utility used in more than one file must move to `web/src/constants/` or `web/src/utils/` on the second use.
- **Coding rules are in [`CODING.md`](./CODING.md).** Read it before writing new code.

## Environment

Copy `.env.example` to `.env`. The API reads env vars through `api/internal/config/config.go` using envconfig — process exits immediately if any required variable is missing or invalid. No silent fallbacks.

Feature integrations are optional unless the code path is used: R2 enables uploads, Resend enables email verification/reset, OAuth vars enable Google/GitHub auth, Turnstile vars enable registration bot checks, WebAuthn vars configure passkeys, and OpenAI/Gemini keys enable AI features.
