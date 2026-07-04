# Chronicle Web — agent notes

Read the root `CLAUDE.md` first (stack, commands, route-file size rules).
`README.md` here covers human setup. This file maps `src/` and records the
client-side behaviors that are not visible from any single file.

## Layout

- `routes/` — TanStack Router file-based routes; orchestration only (data
  hooks, layout composition, event wiring). `routeTree.gen.ts` is generated
  by the Vite plugin — never edit.
- `api/` — orval codegen from the running API's `/openapi.json` — never edit;
  regenerate with `make orval`.
- `components/` — shared components, flat. `components/settings/` holds
  settings sections; `components/ui/` is reserved for extracted Radix-based
  primitives (currently empty — Radix is used inline so far).
- `hooks/` — shared React hooks (`use-mutation-toast`, `use-todo-enabled`).
- `lib/` — non-React helpers (see auth lifecycle below).
- `utils/` — pure functions, unit-tested with vitest colocated `*.test.ts`.
- `i18n.ts` + `locales/{en,ja,zh}/` — namespaces: `auth`, `captures`,
  `common`, `dashboard`, `settings`. Every user-visible string goes through
  i18n; every new key must be added to all three languages.

## Auth lifecycle (client side)

- Access token lives in localStorage (`access_token`); the refresh token is
  an httpOnly cookie (`withCredentials` on the axios instance).
- `lib/axios.ts` — `apiClient` (axios instance) and `api` (the orval
  mutator). Request interceptor attaches the Bearer header. Response
  interceptor does a single-flight refresh on 401 (`/auth/refresh`), retries
  the original request once, and on refresh failure clears the token and
  hard-redirects to `/login`.
- `lib/initAuth.ts` — runs before first render: if the stored token is
  missing or expired, attempts one cookie refresh so the app doesn't boot
  into a guaranteed 401.
- `lib/apiFetch.ts` — bare `fetch` with the same Bearer header, for flows
  that don't fit orval hooks (WebAuthn/passkey ceremonies, MFA setup,
  account management calls in settings).
- `lib/cloudDrive/` — provider-neutral external attachment client;
  `googleDrive.ts` is the first provider. Keep the interface
  provider-neutral — schema/API names must not be Google-specific (see
  `TODO.md`, external file references).

## Gotchas

- `/captures/upload` is not in the OpenAPI spec (the API mounts it outside
  huma), so there is no generated hook for it — call it manually.
- Route files target < 250 lines; any sub-component over 60 lines moves to
  `components/`. `web/src/constants/` doesn't exist yet — create it on the
  second use of a shared constant, per the root convention.
