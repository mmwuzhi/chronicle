# Chronicle API — agent notes

Read the root `CLAUDE.md` first (stack, commands, data model, conventions).
This file maps what lives where inside `api/` and records rules that are not
visible from any single file. Setup and commands live in the root `Justfile`.

## Package map

- `cmd/server` — entry point: config load, postgres/redis wiring, middleware
  order, and every package's `Register(...)` call. New route packages get
  mounted here.
- `internal/config` — envconfig struct; startup fails fast on invalid env.
  A feature is "enabled" iff its env vars are set (R2, Resend, OAuth,
  Turnstile, WebAuthn, OpenAI/Gemini, `RAG_SERVICE_URL`).
- `internal/middleware` — trace ID injection, JWT auth guard, rate limiter,
  request logger.
- `internal/auth` — the whole identity surface: email+password register/login,
  refresh-token rotation, email verify/reset, Google/GitHub OAuth
  (`oauth.go`), passkeys (`passkey.go`), TOTP MFA + recovery codes
  (`totp.go`), JWT mint/verify (`token.go`), create-only capture tokens
  (`capture_token.go`).
- `internal/capture` — the core resource, split by sub-domain: `handler.go`
  (Register + CRUD + shared helpers), `todotag.go` (#todo tag grammar; create
  and update derive todo_at/done_at from the text), `remind.go` (reminders),
  `trash.go` (soft delete, trash, R2 media purge), `attachments.go` (external
  file references), `links.go` (explicit links + semantic suggestions),
  `pagination.go` (cursor logic). New endpoints go in the matching sub-domain
  file.
- `internal/search` — `/find` (hybrid recall) and `/ask` (query-time answer).
  `/find` degrades to keyword FTS when the sidecar is down — search must
  never go dark. `/ask` requires the sidecar.
- `internal/ragclient` — HTTP client for the Python sidecar (`ragsvc/`). A
  nil/disabled client (no `RAG_SERVICE_URL`) makes every call a no-op or
  `ErrDisabled`; every caller must keep working without it.
- `internal/upload` — `POST /captures/upload`: multipart media upload to R2
  (20 MB cap) plus the async Whisper/OCR transcription worker
  (`transcription_worker.go`).
- `internal/linkfetch` — the async link-enrichment worker: fetches URLs found
  in text captures (SSRF-guarded, HTML-only, size-capped) and stores the
  page's readable text in `transcript`. Structural twin of the transcription
  worker; shares the `transcription_status` queue, partitioned by
  `media_key IS NULL`. Gated by `LINK_FETCH_ENABLED`; no external API key.
- `internal/ai` — `POST /ai/polish`: optional LLM text enrichment.
- `internal/user` — `/users/me`: profile, password change, linked OAuth
  account management.
- `internal/webhook` — CRUD for capture-webhook rules. Go owns the rules
  table; ragsvc owns matching + delivery. Workflow automation kept at
  explicit user request — do not extend beyond CRUD.
- `testutil` — `NewPool(t)`: connects to the test DB (default
  `postgres://chronicle:chronicle@localhost:5432/chronicle_test`, override
  with `TEST_DATABASE_URL`), applies all goose migrations, auto-closes. All
  DB tests share this one database — hence `go test -p 1 ./...`.

## Auth boundaries

- `POST /captures` runs behind `createMW`, which accepts a normal JWT **or** a
  long-lived create-only capture token (iOS Shortcut / desktop quick
  capture). Every other capture route uses `authMW` (JWT only). Never attach
  `createMW` to a route that can read or modify data.
- The RAG sidecar has no auth of its own. This API authenticates the user and
  forwards a trusted `X-User-Id` header; the sidecar must only be reachable
  from the API (localhost / private network).

## Cross-cutting behaviors

- On capture write, the API calls the sidecar's `/index` to embed + extract.
  Indexing is best-effort: a capture write must not fail because the sidecar
  is down (same policy as R2 media purge on permanent delete).
- Capture visibility mutations that do not run `/index` (trash, restore,
  permanent delete, empty trash) must call the sidecar's `/invalidate` for the
  affected user. Otherwise its per-user corpus cache can serve stale rows until
  the TTL expires. Invalidation is still best-effort; the database mutation is
  the source of truth.
- `/captures/upload` bypasses huma (multipart needs the raw `*http.Request`),
  so it is absent from `/openapi.json` and has no orval hook — the web client
  calls it manually. An optional `text` form field becomes the capture's
  raw_text; like every save path it goes through the #todo derivation
  (`capture.DeriveTodoStamps`).
- `CaptureCreateInput` still accepts a deprecated, ignored `classifiedAs`
  field so queued desktop offline captures from pre-todo-facet builds replay
  cleanly. Removal timing is tracked in `TODO.md`. General rule: when
  changing the create contract, keep the previous shape accepted for at
  least one release, because desktop offline queues replay old payloads
  after updates.
