# TODO

Deferred work.

## Capture-First Roadmap

- Web feed virtualization: the captures list keeps every loaded page mounted. Load-more is a manual button, so growth is bounded in practice. If deep feeds ever jank, add @tanstack/react-virtual. Measure first; the 2026-07-11 memoization pass already removed the markdown re-parse cost.
- Desktop polish (remaining): app signing and notarization, but only when distributing the app outside the local development Mac or when Gatekeeper friction is reported. (Shipped: packaged app via `desktop/scripts/build-app.sh`, sign-in/token flow in Settings, queue retry with sent/remaining in Settings, configurable global hotkey, live English/Chinese localization, launch at login.)
- Automatic developer capture: revisit only after repeated manual capture of Git commits, GitHub pull requests/issues, or VSCode activity demonstrates demand and the product has a simple way to control capture noise.
- Mobile capture (deferred; direction decided, not yet built):
  - Trigger: prioritize native mobile entry points when Apple Shortcuts and the existing browser/Desktop capture surfaces no longer cover demonstrated capture demand; start with action-button voice/text capture once the input contract is stable.
  - Stack: Flutter + native integrations. Share the bulk (Inbox, Timeline, Search, Settings, Details) in Flutter; keep only platform capabilities native. Rationale: avoid maintaining two UI / router / state / test stacks.
  - Native entry points must not depend on the Flutter process being alive. Native captures (Share Extension, Widget, App Intent, Quick Settings Tile) write to a shared local DB that Flutter reads instead of a MethodChannel that forces Flutter to launch.
  - Entry points. iOS: Action Button, App Intents, Widget, Share Extension. Android: Quick Settings Tile, Share Intent, App Shortcuts.
  - Transcription engine: Apple Speech as the default (built-in, free, no model download, no server); Whisper Small/Medium/Large as an opt-in power-user option.
  - Model download: don't bundle models in the app. Download on first use into Application Support; source from GitHub Releases / R2 / S3.

## Long-Term Memory Roadmap

- Memory decay: revisit when real capture volume produces measurable stale clutter. Candidate scope: importance score, last-viewed/search/reference counters, low-priority archive candidates, and weekly cleanup suggestions.
- Memory consolidation: revisit after retrieval quality is reliable and repeated capture clusters are common enough to justify periodic AI summaries into durable long-term knowledge.
- MCP retrieval access: revisit only when explicitly prioritized. Add revocable long-lived credentials with explicit read/search scopes and per-user authorization before exposing capture search or retrieval. Keep the current capture tokens create-only. Start with read-only retrieval, then evaluate capture creation as a separate scope.
- Agent workflows: defer until capture volume, search quality, and memory-management primitives are reliable.

## Todo Facet Follow-ups (2026-07-03)

- `#tag` derived index: if inline hashtags see real use, parse them at index time into a browsable tag surface (organize-later; no managed tag objects).
- Remove the deprecated `classifiedAs` compat field from the create endpoint after the desktop offline queues have cycled (one release is enough for a single-user install).
- Local desktop SQLite cache still carries the unused `classified_as` column (constant 'unclassified'); drop it whenever the cache schema next changes for another reason.
