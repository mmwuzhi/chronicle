# Chronicle browser extension

This is a standalone TypeScript/Vite Manifest V3 quick-capture runtime. It is
not a React app and does not use TanStack Query, Web app i18n, or orval.

## Map

- `public/manifest.json`: permissions, service worker, popup, and options page
- `src/background.ts`: context menus, alarms, queue serialization, delivery,
  retry, terminal failure, and badge state
- `src/core.ts`: pure URL validation, Markdown formatting, admission limits,
  retry policy, and queue-scope derivation
- `src/storage.ts`: settings plus origin/token-scoped queues in
  `chrome.storage.local`
- `src/messages.ts`: typed popup/options/background protocol
- `src/popup.ts`: capture and queue-status UI
- `src/options.ts`: API origin, capture token, and optional host permission
- `e2e/`: unpacked-extension Playwright coverage

## Security and permission boundary

- Use a create-only Chronicle Capture token. Never add account-read capability
  or reuse Web session cookies.
- The API origin must be HTTPS except for `localhost`/`127.0.0.1`. Reject URLs
  containing credentials, query strings, or fragments.
- Keep host access least-privileged: loopback is declared for development and a
  configured HTTPS origin is requested through optional host permissions. Do
  not replace this with an unconditional all-sites host permission.
- `activeTab`/`scripting` access is for the user-invoked current-page capture;
  do not introduce passive browsing collection.

## Durable outbox contract

- Each queued item owns one UUID. Send it unchanged as `Idempotency-Key` on
  every retry with stable source `browser_extension`.
- Scope queue storage by normalized API origin and a one-way token fingerprint.
  Do not allow origin/token changes while that scope has queued work.
- Queue admission is bounded by the live limits in `core.ts`; do not silently
  evict captures when full or oversized.
- Serialize queue mutations and flushes. The MV3 worker may stop between events,
  so durable state belongs in `chrome.storage.local`, never module memory alone.
- Retry only network failures, 429, and 5xx with bounded exponential backoff.
  Other HTTP failures become visible terminal items until the user retries or
  removes them.
- Page and selection captures preserve source attribution as escaped Markdown;
  never inject unescaped page title or URL text into the payload.
