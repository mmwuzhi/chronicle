# Chronicle Web application

This directory is the Vite React application. It uses TanStack Router and
Query, orval-generated API bindings, Radix-based UI primitives, and i18next.

## Map

- `routes/`: file-based route declarations and orchestration; the pathless
  `_authenticated` layout guards ordinary signed-in routes
- `api/`: generated query/mutation bindings from the API OpenAPI document
- `components/`: shared product components; `components/settings/` contains
  settings sections and `components/ui/` contains extracted primitives
- `hooks/`: shared React hooks
- `lib/`: API transport, auth lifecycle, and provider-neutral cloud-drive
  integration
- `constants/`: shared constants, currently including feature flags
- `utils/`: pure helpers with colocated Vitest coverage
- `i18n.ts` and `locales/{en,ja,zh}/`: application localization

## Authentication lifecycle

- The access token is in local storage; the rotating refresh token is an
  httpOnly cookie sent with credentials.
- `lib/initAuth.ts` repairs an absent/expired access token before first render.
  `lib/axios.ts`, `lib/auth-refresh.ts`, and `lib/auth-session.ts` implement
  single-flight refresh and retry for ordinary generated API operations.
- Every refresh and 401 result is scoped to the access-token snapshot that
  started it. If a newer sign-in, sign-out, or server change occurred, discard
  the stale result rather than replaying with or clearing newer credentials.
- The `_authenticated` layout remembers a normalized internal destination
  before sign-in. Complete authentication consumes it once; reject external or
  scheme-relative redirects.
- `lib/apiFetch.ts` is the centralized fetch transport for browser-protocol auth
  ceremonies and other operations that cannot use generated hooks. Multipart
  media upload has its own centralized path because it is outside OpenAPI.

## Capture and sharing boundaries

- The composer routes transcribable direct media to Chronicle's configured
  object storage and other files to the provider-neutral cloud-drive interface.
  Direct-upload size policy mirrors the API and changes as one contract.
- `routes/s.$shareId.tsx` is intentionally public; ordinary Capture routes stay
  under `_authenticated`.
- A public share secret remains in the URL fragment so it is not sent in the
  initial HTTP request. The client extracts it and sends
  `Authorization: Share <secret>` to fetch the immutable text snapshot. Treat
  all missing/invalid/expired/revoked results as not found.
- Share UI previews and submits the exact non-empty text the owner approved.
  Never add media, attachments, transcript, related Captures, or ambient account
  context to the public payload.

## Shared identity

- Every user-visible string goes through i18n and every new key is added to
  English, Japanese, and Simplified Chinese. The noun **Capture** remains
  `Capture` in every locale.
- Brand accent is `--accent` in `index.css`; its Desktop counterpart is
  `Color.chronicleAccent` in `DesktopTheme.swift`.
- List/precise timestamp behavior is `fmtListTime`/`fmtPreciseDateTime` in
  `utils/format.ts`; its Desktop counterpart is `CaptureTime` in
  `CaptureRowModel.swift`. Change paired definitions together.
