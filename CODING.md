# Coding Rules

Rules that apply across the entire codebase. Read before writing new code.

## General

- No hardcoded secrets, URLs, or magic numbers. All configuration comes from environment variables validated by `api/internal/config/config.go`.
- No commented-out code in commits. Delete it — git history preserves it.
- One concern per PR. A bug fix should not also refactor unrelated files.

## Go (`api/`)

- **No `fmt.Println` or `log.Print*`.** Use the slog logger. In handlers, get it from context. Every log call must include `traceId`.
- **Never ignore errors.** Every `err != nil` must be handled — either return it, log it, or explicitly explain why it is safe to ignore.
- **No `interface{}` or `any` unless the type is genuinely unknown.** If unknown, narrow it before use.
- **All DB queries go through sqlc.** Write the query in `db/queries/*.sql`, run `sqlc generate`, use the generated function. No `pgx.Exec(ctx, "SELECT ...")` in Go code.
- **Never write to `db/sqlc/`.** It is generated output. Edit the `.sql` files instead.
- **No hard DELETEs on user data.** Set `deleted_at = now()` via a sqlc query. See the conventions in CLAUDE.md.
- **Migrations are generated SQL files managed by goose.** Use `goose ... create <name> sql` to create a new migration file. Never edit an already-applied migration.
- **No business logic in middleware.** Middleware handles cross-cutting concerns: trace ID, auth, rate limiting, logging. Route handlers own business logic.
- **Explicit error types for domain errors.** Do not return raw strings as errors. Define sentinel errors or typed error structs so callers can distinguish them.

## Frontend (`web/`)

- **No `useEffect` for data fetching.** Use TanStack Query — `useQuery` for reads, `useMutation` for writes.
- **All API calls go through the orval-generated hooks in `src/api/`.** Never call `fetch` directly in a component. Never hand-write API client code — run `pnpm orval` if the spec changed.
- **Never edit `src/api/`.** It is codegen output. If a hook is missing, check whether `pnpm orval` needs to be re-run.
- **Mutation errors must surface to the user.** Use a toast in `onError` of `useMutation`. Do not silently swallow errors.
- **Hooks live in `src/hooks/`.** One file per domain (tasks, projects, timer, captures, reports). Do not put query or mutation logic directly in page or component files.
- **No inline styles for layout.** Use CSS classes. Inline `style={{}}` is acceptable only for dynamic values that cannot be expressed statically (e.g. a CSS custom property derived from a runtime value).

## TypeScript (`web/`)

- No `any`. Use `unknown` and narrow explicitly if the type is genuinely unknown.
- No non-null assertions (`!`) unless you add a comment explaining why null is impossible.
- Explicit return types on all exported functions.
- Do not widen types to work around a type error. Fix the underlying issue.
