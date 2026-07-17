# TODO

Deferred work.

## Capture-First Roadmap

- Web feed virtualization: the captures list keeps every loaded page mounted. Load-more is a manual button, so growth is bounded in practice. If deep feeds ever jank, add @tanstack/react-virtual. Measure first; the 2026-07-11 memoization pass already removed the markdown re-parse cost.
- Desktop polish (remaining): app signing. (Shipped: packaged app via `scripts/build-app.sh`, sign-in/token flow in Settings, queue retry with sent/remaining in Settings, configurable global hotkey, live English/Chinese localization, launch at login.)
- Automatic developer capture: Git commits, GitHub pull requests, GitHub issues, and VSCode activity.
- Browser extension capture (deferred by product choice): start with a Chrome/Edge Manifest V3 extension that saves selected text or the current page through the existing create-only capture token. Reuse link enrichment for page content; add no new backend or read permissions. Revisit only when the extension is explicitly prioritized.
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
- MCP retrieval access: add revocable long-lived credentials with explicit read/search scopes and per-user authorization before exposing capture search or retrieval. Keep the current capture tokens create-only. Start with read-only retrieval, then evaluate capture creation as a separate scope.
- Agent workflows: defer until capture volume, search quality, and memory-management primitives are reliable.

## Todo Facet Follow-ups (2026-07-03)

- `#tag` derived index: if inline hashtags see real use, parse them at index time into a browsable tag surface (organize-later; no managed tag objects).
- Remove the deprecated `classifiedAs` compat field from the create endpoint after the desktop offline queues have cycled (one release is enough for a single-user install).
- Local desktop SQLite cache still carries the unused `classified_as` column (constant 'unclassified'); drop it whenever the cache schema next changes for another reason.
