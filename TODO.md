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
