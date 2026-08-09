# Chronicle Desktop

The macOS app has a platform-free Core target and an AppKit/SwiftUI shell.
`README.md` describes user-facing behavior; this file records architectural
boundaries that span source files.

## Target map

- `Sources/ChronicleDesktopCore/`: payloads and API clients (`Capture`,
  `CaptureMedia`, `CaptureShare`, `Recall`, `Reminder`, `Webhook`), authenticated
  transport/session state (`APIEndpoint`, `Auth`, `AuthedTransport`,
  `SessionMonitor`, `UserIdentity`), offline persistence/sync (`LocalCaptureStore`,
  `CaptureQueue`, `CaptureSyncCoordinator`, `CaptureSyncGate`), safe file and
  Drive transport (`SecureCaptureFile`, `GoogleDrive`), local semantic search,
  todo grammar, row merge/sort, path, hotkey, focus, and layout logic
- `Sources/ChronicleDesktop/`: AppKit/SwiftUI wiring for the menu bar, quick panel,
  browse/search/ask window, Capture detail, review and Trash panes, media/file
  UI, Google Drive authorization, share sheet, Shared Copies settings, pinned
  stickies, reminders, localization, settings, and E2E hooks
- `Tests/ChronicleDesktopCoreTests/`: platform-free unit tests
- `Tests/ChronicleDesktopE2ETests/`: real-app and UI-facing behavior tests

If logic does not touch AppKit or SwiftUI, it belongs in Core so it is testable.

## Local data and synchronization

- `LocalCaptureStore` is both the offline retry queue and local browse/search
  cache. Rows without `server_id` are pending remote creation. The legacy
  `classified_as` cache column is compatibility-only and ignored on read. Drop
  it only when another cache-schema change already requires a migration.
- Older offline payloads must replay against a newer API. Preserve the previous
  create shape for at least one release when changing it.
- Remote writes for one local Capture are serialized through
  `CaptureSyncCoordinator`: deduplicate create POSTs, coalesce drains, and
  re-read dirty state after each PATCH so in-flight edits become the next
  revision.
- Server/auth failure never blanks already displayed local results. Ambiguous
  save failures remain queued and retryable.
- Keyword, local Ollama semantic, and server `/find` layers are independent and
  merged only by Capture ID. Never compare scores across vector spaces. Merge a
  server evidence snippet into a matching local row without replacing editable
  local text.

## Credential and file boundaries

- `ChronicleAPIEndpoint` requires HTTPS except for loopback. An effective origin
  change clears bearer and refresh credentials; credentials never cross API
  origins.
- Refresh results are scoped to their starting credential snapshot. A stale
  success or 401 cannot overwrite or clear a newer sign-in/session. Only an
  explicit refresh 401 marks `SessionMonitor` expired; network and 5xx failures
  leave health unknown/current.
- Main-actor session callbacks read `SessionMonitor`'s current converged health;
  never act on a state value captured before a newer sign-in or refresh finished.
- Password and OAuth sign-in both preserve the TOTP/recovery-code second step.
  Desktop OAuth custom callbacks carry only a short-lived, single-use code.
  Exchange it with the original PKCE verifier; access and MFA tokens must never
  appear directly in the custom callback URL.
- `UserIdentity` establishes the server-issued account boundary for on-device
  state. Invalidate cached Drive authority on every Chronicle account or origin
  change.
- Capture file reads go through `SecureCaptureFile`: verify a regular-file
  descriptor and copy into an app-owned staged snapshot. Do not upload directly
  from an unverified user-controlled path.
- One media/file draft owns one operation UUID until saved or discarded. Reuse
  it for direct upload `Idempotency-Key`, Drive `chronicleOperationId`, and
  atomic `/captures/with-attachment` creation. Do not compensate ambiguous
  outcomes by deleting the Drive file or soft-deleting a possibly created
  Capture.
- Direct media is content-sniffed and capped at 20 MB. Other files use Drive
  resumable upload up to 100 MB. Retry one Drive 401 only after reauthorization;
  if rejected again, invalidate authority again.

## Sharing boundary

- `CaptureShare` models owner-authenticated list/create/revoke operations; the
  app share sheet and Shared Copies settings use that client.
- The owner explicitly approves an immutable, non-empty raw-text snapshot.
  Media, attachments, transcript, related Captures, and context remain private.
- A replacement share revokes the previous link. Trashing the source Capture
  permanently revokes its active share; restore never reactivates it.

## UI invariants and gotchas

- All user-facing copy goes through `L(...)` or
  `DesktopLocalization.format`, includes a Simplified Chinese entry, and
  observes language changes. AppKit-only surfaces refresh on
  `.chronicleLanguageChanged`. The noun **Capture** is never translated.
- Desktop brand accent is `Color.chronicleAccent` in `DesktopTheme.swift`; Web
  defines the pair as `--accent`. Desktop list timestamps are `CaptureTime` in
  `CaptureRowModel.swift`; Web defines the paired formatting helpers. Change
  each pair together.
- `MainView` mutations of `fragments`, `localRows`, `signedIn`, or `offline`
  must rebuild `browseRows`.
- `.onAppear` pagination requires `LazyVStack`; a non-lazy container mounts all
  rows and chain-loads every page.
- A sticky's `NSHostingView` keeps `sizingOptions = []`; its controller owns and
  persists the fitted window frame.
- Panel/window placement uses `.moveToActiveSpace`; do not misdiagnose macOS
  Spaces movement as a multi-display layout bug.
- `scripts/e2e.sh` builds the real app and drives `E2ERunner`; panel or main
  window behavior changes generally require matching E2E coverage.
