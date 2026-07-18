# Chronicle Desktop — agent notes

Read the root `CLAUDE.md` first. `README.md` here covers the user-facing
behavior (controls, search layers, offline queue). This file records the
target split, the invariants, and the gotchas.

## Two targets — where code goes

- `Sources/ChronicleDesktopCore/` — platform-free logic, unit-tested by
  `Tests/ChronicleDesktopCoreTests/`. Capture payload + API client
  (`Capture.swift`), auth + token refresh (`Auth.swift`,
  `AuthedTransport.swift`), offline sync orchestration
  (`CaptureSyncCoordinator.swift`), legacy queue (`CaptureQueue.swift`), local
  SQLite store (`LocalCaptureStore.swift`), on-device semantic search
  (`LocalEmbedder.swift`, `LocalSemanticSearch.swift` — local Ollama
  `bge-m3`), server recall client (`Recall.swift` — `/find` + `/ask`),
  reminders (`Reminder.swift`), webhooks (`Webhook.swift`), hotkey model
  (`HotKey.swift`, `DoubleTapDetector.swift`), row merge/sort
  (`RowMerge.swift`), todo grammar/display derivation (`TodoTag.swift`),
  pure layout/focus math (`PanelLayout.swift`,
  `QuickPanelFocusState.swift`), paths (`Paths.swift`).
- `Sources/ChronicleDesktop/` — AppKit/SwiftUI shell: menu bar
  (`AppDelegate`), quick panel (`QuickCapturePanelController`,
  `PanelContentView`), main window (`MainView` — browse/search/ask shell,
  with chrome in `MainWindowChrome.swift` and the trash pane in
  `MainTrashPane.swift`), detail view, pinned stickies (`PinnedSticky*`),
  settings, hotkey wiring, reminder notifications, E2E hooks
  (`E2ERunner`).

**Rule:** if a function doesn't touch AppKit/SwiftUI, it belongs in Core,
where it can be unit-tested. The app target is UI and wiring only.

## Local store = queue + cache

`LocalCaptureStore` (SQLite at
`~/Library/Application Support/Chronicle/chronicle-local.sqlite3`) plays two
roles: rows without a `server_id` are the offline retry queue; all rows form
the corpus for offline browse and search. Legacy `classified_as` column is
still in the schema (constant `'unclassified'`, skipped on read) — drop it
only when the cache schema next changes for another reason (`TODO.md`).

## Invariants

- **Offline queue payloads replay against a newer API after updates.** When
  the create payload changes, the API must keep accepting the previous shape
  for at least one release (this is why the API still accepts the deprecated
  `classifiedAs` field).
- **Search layers are independent, merged by capture id.** Keyword substring
  (local), on-device semantic (local Ollama), and server `/find` never
  depend on each other; local and server embeddings are different vector
  spaces — dedup by id only, never compare scores across layers. When a later
  server result duplicates a local row, merge its evidence snippet into the
  local row instead of discarding the evidence or replacing editable raw text.
- **Offline-first error handling:** a server or auth error must never blank
  already-shown local results; save failures fall back to the queue, not to
  an error dialog.
- **Serialize remote writes per local capture.** Immediate save, session
  refresh, manual retry, and optimistic edits may request the same remote write
  concurrently. Route every create/update drain through
  `CaptureSyncCoordinator`: it deduplicates create POSTs, coalesces update-drain
  requests, and re-reads a dirty row after each PATCH so an in-flight re-edit is
  sent as the next revision.
- **Bearer credentials require a secure API endpoint.** Remote API URLs must
  use HTTPS; plain HTTP is allowed only for loopback development hosts. Keep
  validation centralized in `ChronicleAPIEndpoint` so settings, environment
  overrides, and stored sessions cannot diverge. Changing scheme, host, or
  effective port clears the old bearer token and refresh cookie; never carry a
  credential across API origins.

## Gotchas

- **Single screen + macOS Spaces:** panel/window placement uses
  `.moveToActiveSpace`. A "window jumps back to another screen" report is a
  Spaces problem, not a multi-display problem — don't add multi-display
  logic for it.
- E2E: `bash scripts/e2e.sh` builds the real `.app` and runs
  `ChronicleDesktopE2ETests` against the binary (via
  `CHRONICLE_DESKTOP_E2E_APP_PATH`, driven through `E2ERunner`). UI changes
  to the panel or main window usually need a matching e2e update.
- `MainView` caches its merged browse list in `browseRows`; any new mutation
  of `fragments`/`localRows`/`signedIn`/`offline` must call
  `rebuildBrowseRows()`, or the list goes stale.
- **`.onAppear`-driven pagination needs a `LazyVStack`.** In a non-lazy
  container every row's `onAppear` fires the moment it's added, so "load more
  when the last row appears" (`maybeLoadMore`) degenerates into chain-loading
  every page, with all rows — each hosting a native NSTextView — permanently
  mounted. This was the main-window scroll/sidebar/drag stutter root cause;
  don't diagnose that class of jank as a material/rendering cost first.
- The sticky's `NSHostingView` must keep `sizingOptions = []`: its controller
  owns the panel frame (persisted, height-fitted via `onHeight`). Default
  sizing options let a SwiftUI ideal size — e.g. an NSTextView body's
  unwrapped single-line width — resize the window, and `windowDidResize`
  then persists the blown-out frame.
- MFA login is not implemented in the desktop app.
