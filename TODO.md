# TODO

Deferred work.

## Revisit After Refactor

- Task event history: represent task edits as deletable log-style events.
- Capture-to-task relationship banner: keep a persistent source link after promotion, with an unlink action.
- Inline capture-to-task conversion: replace the promotion modal with an inline panel that preserves context.
- Weekly digest email: auto-send the weekly report through Resend.
- Due-date reminder emails: notify about tasks approaching `due_at`.

## Capture-First Roadmap

- Desktop polish (remaining): launch at login, app signing. (Shipped: packaged app via `scripts/build-app.sh`, sign-in/token flow in Settings, queue retry with sent/remaining in Settings, configurable global hotkey.)
- Automatic developer capture: Git commits, GitHub pull requests, GitHub issues, and VSCode activity.
- Browser extension capture: save selected text, current page, and research notes into the capture inbox.
- External file references (deferred — design toward multiple providers):
  - Goal: let users attach files without Chronicle becoming the file host. Files upload directly to the user's own cloud drive; Chronicle stores only capture text plus an external attachment reference.
  - Providers: design the provider interface for Google Drive, OneDrive, and Dropbox from the start. A first implementation may ship one provider, but schema/API names must not be Google-specific.
  - Scope boundary: request only the minimum provider permissions needed to create/read app-created files, preferably inside a Chronicle-owned app folder. Do not request broad drive-wide access.
  - Data model: add provider-neutral attachment metadata linked to captures: provider, provider_file_id, display name, MIME type, size, web/open URL, and created_at. Keep file bytes out of Chronicle storage.
  - Product behavior: captures remain searchable by user text/OCR/transcript; external files are shown as linked attachments. If the user deletes or moves the cloud file, Chronicle should degrade to a stale reference instead of trying to repair or mirror it.
  - Non-goals: no cloud-drive file manager, folder browser, background sync engine, cross-provider migration, full-text indexing of arbitrary files, or permission reconciliation workflows.
- Mobile capture (deferred — direction decided, not yet built):
  - Trigger: action-button voice/text capture once the input contract is stable.
  - Stack: Flutter + native integrations. Share the bulk (Inbox, Timeline, Search, Settings, Details) in Flutter; keep only platform capabilities native. Rationale: avoid maintaining two UI / router / state / test stacks.
  - Native entry points must not depend on the Flutter process being alive. Native captures (Share Extension, Widget, App Intent, Quick Settings Tile) write to a shared local DB that Flutter reads — not a MethodChannel that forces Flutter to launch.
  - Entry points — iOS: Action Button, App Intents, Widget, Share Extension. Android: Quick Settings Tile, Share Intent, App Shortcuts.
  - Transcription engine: Apple Speech as the default (built-in, free, no model download, no server); Whisper Small/Medium/Large as an opt-in power-user option.
  - Model download: don't bundle models in the app. Download on first use into Application Support; source from GitHub Releases / R2 / S3.

## Long-Term Memory Roadmap

- Ask Chronicle: hybrid search over captures, tasks, log entries, and weekly reports with Postgres full-text search first, then pgvector and LLM synthesis.
- Memory decay: importance score, last-viewed/search/reference counters, low-priority archive candidates, and weekly cleanup suggestions.
- Memory consolidation: periodic AI summaries that compress repeated raw captures into durable long-term knowledge.
- Agent workflows: defer until capture volume, search quality, and memory-management primitives are reliable.

## Todo Facet Follow-ups (2026-07-03)

- Desktop todo UI: show the checkbox/state on browse rows and the quick panel (backend + web shipped; desktop is compat-only for now — `Capture` no longer carries classification, `todoAt`/`doneAt` not yet decoded).
- `#tag` derived index: if inline hashtags see real use, parse them at index time into a browsable tag surface (organize-later; no managed tag objects).
- Remove the deprecated `classifiedAs` compat field from the create endpoint after the desktop offline queues have cycled (one release is enough for a single-user install).
- Local desktop SQLite cache still carries the unused `classified_as` column (constant 'unclassified'); drop it whenever the cache schema next changes for another reason.

## Refactor Backlog (2026-07-08)

Approved refactor batch, worked top-down; remove each line when its phase lands.

- P4 — Remove the unconsumed `GET /captures` endpoint (handler, `ListCaptures` query, tests move to `/captures/page`).
- P5 — Split `desktop/Sources/ChronicleDesktop/DesktopUI.swift` (1102 lines) into DesktopTheme / CaptureRowModel / CaptureRowViews / WorkspaceInput / ScreenPlacement; update the identity-parity file references in root `CLAUDE.md`.
