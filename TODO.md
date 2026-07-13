# TODO

Deferred work.

## Capture-First Roadmap

- Web feed virtualization: the captures list keeps every loaded page mounted. Load-more is a manual button, so growth is bounded in practice. If deep feeds ever jank, add @tanstack/react-virtual. Measure first; the 2026-07-11 memoization pass already removed the markdown re-parse cost.
- Desktop polish (remaining): launch at login, app signing. (Shipped: packaged app via `scripts/build-app.sh`, sign-in/token flow in Settings, queue retry with sent/remaining in Settings, configurable global hotkey.)
- Automatic developer capture: Git commits, GitHub pull requests, GitHub issues, and VSCode activity.
- Browser extension capture: save selected text, current page, and research notes into the capture inbox.
- Mobile capture (deferred; direction decided, not yet built):
  - Trigger: action-button voice/text capture once the input contract is stable.
  - Stack: Flutter + native integrations. Share the bulk (Inbox, Timeline, Search, Settings, Details) in Flutter; keep only platform capabilities native. Rationale: avoid maintaining two UI / router / state / test stacks.
  - Native entry points must not depend on the Flutter process being alive. Native captures (Share Extension, Widget, App Intent, Quick Settings Tile) write to a shared local DB that Flutter reads instead of a MethodChannel that forces Flutter to launch.
  - Entry points. iOS: Action Button, App Intents, Widget, Share Extension. Android: Quick Settings Tile, Share Intent, App Shortcuts.
  - Transcription engine: Apple Speech as the default (built-in, free, no model download, no server); Whisper Small/Medium/Large as an opt-in power-user option.
  - Model download: don't bundle models in the app. Download on first use into Application Support; source from GitHub Releases / R2 / S3.

## Long-Term Memory Roadmap

- Memory decay: importance score, last-viewed/search/reference counters, low-priority archive candidates, and weekly cleanup suggestions.
- Memory consolidation: periodic AI summaries that compress repeated raw captures into durable long-term knowledge.
- Agent workflows: defer until capture volume, search quality, and memory-management primitives are reliable.

## Todo Facet Follow-ups (2026-07-03)

- Desktop todo UI is display-only. The `#todo` text tag is the entry point everywhere, so desktop capture already works by typing the tag. What's missing is rendering the tag as a chip on browse rows, the quick panel, and stickies (matching the web chip-only model, with no checkbox anywhere), plus the `#` suggestion menu in the capture field.
- `#tag` derived index: if inline hashtags see real use, parse them at index time into a browsable tag surface (organize-later; no managed tag objects).
- Remove the deprecated `classifiedAs` compat field from the create endpoint after the desktop offline queues have cycled (one release is enough for a single-user install).
- Local desktop SQLite cache still carries the unused `classified_as` column (constant 'unclassified'); drop it whenever the cache schema next changes for another reason.
