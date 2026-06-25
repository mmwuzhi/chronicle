# TODO

Deferred work to revisit after the current UI route files are refactored.

## Refactor First

- Split oversized route files back into orchestration-only routes.
- Prioritize `web/src/routes/tasks.$taskId.tsx`, then `captures.tsx`, `tasks.index.tsx`, `projects.index.tsx`, and `reports.tsx`.
- Keep route files focused on data hooks, layout composition, and event wiring. Move large sub-components to `web/src/components/`.

## Revisit After Refactor

- Task event history: represent task edits as deletable log-style events.
- Capture-to-task relationship banner: keep a persistent source link after promotion, with an unlink action.
- Inline capture-to-task conversion: replace the promotion modal with an inline panel that preserves context.
- Weekly digest email: auto-send the weekly report through Resend.
- Due-date reminder emails: notify about tasks approaching `due_at`.

## Capture-First Roadmap

- Desktop Quick Capture polish: packaged app, token setup flow, queue status UI, launch at login, app signing, and configurable global hotkey.
- Automatic developer capture: Git commits, GitHub pull requests, GitHub issues, and VSCode activity.
- Browser extension capture: save selected text, current page, and research notes into the capture inbox.
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
