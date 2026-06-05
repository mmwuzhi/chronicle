# TODO

Deferred work to revisit after the current UI route files are refactored.

## Refactor First

- Split oversized route files back into orchestration-only routes.
- Prioritize `web/src/routes/tasks.$taskId.tsx`, then `captures.tsx`, `tasks.index.tsx`, `projects.index.tsx`, and `reports.tsx`.
- Keep route files focused on data hooks, layout composition, and event wiring. Move large sub-components to `web/src/components/`.

## Revisit After Refactor

- Weekly digest email: auto-send the weekly report through Resend.
- Due-date reminder emails: notify about tasks approaching `due_at`.
