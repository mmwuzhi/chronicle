# TODO

Deferred work.

## Desktop Sign-in Health (2026-07-09)

- Signed-out state needs a visible, non-intrusive indicator (menu bar icon
  state or a panel badge). The launch-time onboarding window used to be the
  only signal and is now first-run-only, so a returning user who loses their
  session sees nothing until a mutation fails. Context: the installed app sat
  signed out for ~3 weeks with 16 captures silently queued locally.
- Likely cause of the long signed-out stretch: signOut deliberately clears the
  refresh cookie (2026-06-22 fix), and offline-first is a supported way to run
  the app — so a lapsed/cleared session never heals itself and never announces
  itself. A "N captures waiting to sync — sign in" nudge in the panel or main
  window would close the loop without nagging.

## Revisit After Refactor

- Task event history: represent task edits as deletable log-style events.
- Capture-to-task relationship banner: keep a persistent source link after promotion, with an unlink action.
- Inline capture-to-task conversion: replace the promotion modal with an inline panel that preserves context.
- Weekly digest email: auto-send the weekly report through Resend.
- Due-date reminder emails: notify about tasks approaching `due_at`.

## Capture-First Roadmap

- Web feed virtualization: the captures list keeps every loaded page mounted. Load-more is a manual button so growth is bounded in practice; if deep feeds ever jank, add @tanstack/react-virtual (measure first — the 2026-07-11 memoization pass already removed the markdown re-parse cost).
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

- Desktop todo UI: display only — the `#todo` text tag is the entry point everywhere (2026-07-09), so desktop capture already works by typing the tag; what's missing is rendering the tag as a chip on browse rows, the quick panel, and stickies (matching web's chip-only model — no checkbox anywhere), plus the `#` suggestion menu in the capture field.
- `#tag` derived index: if inline hashtags see real use, parse them at index time into a browsable tag surface (organize-later; no managed tag objects).
- Remove the deprecated `classifiedAs` compat field from the create endpoint after the desktop offline queues have cycled (one release is enough for a single-user install).
- Local desktop SQLite cache still carries the unused `classified_as` column (constant 'unclassified'); drop it whenever the cache schema next changes for another reason.
