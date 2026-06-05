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
- Mobile capture: action-button voice/text capture once the input contract is stable.

## Long-Term Memory Roadmap

- Ask Chronicle: hybrid search over captures, tasks, log entries, and weekly reports with Postgres full-text search first, then pgvector and LLM synthesis.
- Memory decay: importance score, last-viewed/search/reference counters, low-priority archive candidates, and weekly cleanup suggestions.
- Memory consolidation: periodic AI summaries that compress repeated raw captures into durable long-term knowledge.
- Agent workflows: defer until capture volume, search quality, and memory-management primitives are reliable.
