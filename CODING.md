# Coding and review rules

Read this file before modifying, generating, or reviewing code. It is not
required for pure reading, explanation, planning, or repository navigation.

## Repository-wide

- Keep configuration in the owning runtime's centralized boundary: Go uses
  `api/internal/config`, Web uses Vite env/config helpers, Desktop uses its
  settings/config types, the extension uses validated settings, and RAG reads
  its documented environment. Do not hardcode secrets, deployment URLs, or
  unexplained magic numbers.
- Do not commit commented-out code. Keep one concern per change.
- Preserve product/domain/security invariants from the applicable `CLAUDE.md`;
  these are not relaxed by an existing code violation.
- Use the root `Justfile` and package scripts for formatting, generation, lint,
  tests, builds, E2E, and packaging. Run `/check` before every push. CI is a
  superset of the normal local checks; inspect `.github/workflows/` for the live
  release gate rather than claiming the two command lists are identical.

## Go API

- Use `slog`, not `fmt.Println` or `log.Print*`. Request-path logs use the trace
  ID already present in context; never mint another mid-request. Startup and
  background-worker logs use their natural process/worker identity and must not
  fabricate a request trace.
- Handle every error by returning, logging, or explicitly documenting why it is
  safe to ignore. Prefer typed or sentinel domain errors over raw strings.
- Avoid `interface{}`/`any` unless data is genuinely unknown; narrow it before
  use.
- Production database operations go through sqlc queries in
  `api/db/queries/*.sql`. Tests may use explicit raw SQL only for fixture setup,
  fault injection, or assertions that are not product query paths. Never edit
  generated `api/db/sqlc/` files.
- Create migrations with `just migrate-new <name>`. Edit the newly created,
  unapplied SQL migration as needed; never change an already-applied migration.
- Capture content is soft-deleted by default; only explicit permanent deletion
  from Trash hard-deletes it. Ephemeral auth state, credentials, relationships,
  and an explicitly deleted account follow their own lifecycle contracts.
- Middleware owns cross-cutting behavior, not domain business logic.
- Define huma input/output types on their route and prefix schemas with the
  resource name because huma's registry is global.

## Web application (`web/src`)

- Use TanStack Query for server data, not `useEffect` fetching.
- Ordinary API operations use orval-generated hooks from `src/api/`. Multipart
  upload and browser-protocol auth ceremonies use their established centralized
  helpers. Never add ad-hoc component-level `fetch` calls or handwritten API
  transports.
- Never edit `src/api/` or `src/routeTree.gen.ts`; regenerate them through the
  repository commands.
- Mutation failures must reach the user through the established toast/error
  surface; do not silently swallow them.
- Use the `@/` alias inside handwritten `web/src` code. Generated sources are
  exempt. Do not add relative `./` or `../` imports.
- Do not use `any`; use `unknown` and narrow it. Avoid non-null assertions unless
  a nearby comment proves why null is impossible. Exported functions have
  explicit return types; do not widen types to hide an error.
- Use CSS classes for layout. Inline styles are reserved for genuinely dynamic
  runtime values such as CSS custom properties.
- Route files orchestrate data, layout, and events and target fewer than 250
  lines. New or materially edited route code must not add to existing debt;
  extract subcomponents longer than 60 lines and move second-use constants or
  pure utilities into `constants/` or `utils/`.
- Existing oversized route/subcomponent code and direct auth `fetch` calls in
  `LoginProviders`/`LoginMfaStep` are implementation debt, not precedent. Fix
  them in a separately scoped change unless the current task directly owns them.

## Browser extension (`web/extension`)

- Keep Manifest V3 service-worker work restart-safe: persist durable state and
  make event handlers idempotent.
- Preserve least-privilege permissions and the origin/token-scoped outbox.
- Validate with the extension test/package recipes; do not edit `dist/` or the
  packaged ZIP directly.

## Desktop

- Put platform-free logic in `ChronicleDesktopCore` with unit coverage; keep the
  app target focused on AppKit/SwiftUI wiring.
- New user-facing strings use `L(...)` or `DesktopLocalization.format`, add the
  Simplified Chinese entry, and update live language-change observation.
- Preserve stable remote operation identity and account/origin boundaries for
  async transport, queued writes, files, and Drive authority.

## RAG sidecar

- Keep every interactive query and derived-data write user-scoped.
- Preserve exact-cosine, cache invalidation, chunking, degraded-mode, and
  literal-extraction decisions unless an approved architecture change replaces
  them.
- Prefer `just rag-test`; run `just rag-eval` when retrieval behavior changes.
