# Agent Instruction Context Refactor

Status: implemented; repository verification passed.

Date: 2026-08-09

## Goal

Reduce the always-loaded agent context in this monorepo while keeping Chronicle's
non-discoverable product and architecture invariants reliable. Claude Code and
Codex must continue to consume one canonical instruction source per directory:
each `AGENTS.md` remains a symlink to its sibling `CLAUDE.md`.

Success means a read-only task sees only the small amount of context needed to
understand the repository, a task entering one runtime receives that runtime's
architecture notes without loading unrelated runtimes, and coding/review rules
are loaded only when code will be modified, generated, or reviewed.

## State at Planning Time

- Root `CLAUDE.md`: 334 lines and approximately 19 KB. It mixes product
  direction, volatile implementation inventory, commands, coding rules, and
  cross-runtime invariants.
- Existing local instruction files:
  - `api/CLAUDE.md`
  - `web/CLAUDE.md`
  - `desktop/CLAUDE.md`
  - `ragsvc/CLAUDE.md`
- Each existing `AGENTS.md` is a symlink to the sibling `CLAUDE.md`.
- `CODING.md` is not automatically loaded by Claude Code. This is desirable:
  it should be read before modifying, generating, or reviewing code, not for
  pure reading, explanation, planning, or repository navigation.
- `web/` now contains two distinct runtimes:
  - the React/TanStack application under `web/src/`
  - the Manifest V3 browser extension under `web/extension/`
  The current `web/CLAUDE.md` causes extension work to inherit irrelevant React,
  i18n, and orval guidance.

## Chosen Structure

```text
Read-only repository task
└── CLAUDE.md

Task reading api/*
└── CLAUDE.md + api/CLAUDE.md

Task reading web/src/*
└── CLAUDE.md + web/CLAUDE.md + web/src/CLAUDE.md

Task reading web/extension/*
└── CLAUDE.md + web/CLAUDE.md + web/extension/CLAUDE.md

Task reading desktop/*
└── CLAUDE.md + desktop/CLAUDE.md

Task reading ragsvc/*
└── CLAUDE.md + ragsvc/CLAUDE.md

Task modifying, generating, or reviewing code
└── applicable hierarchy above + CODING.md on demand
```

Claude Code loads instructions from the working directory to the repository
root at startup, then discovers nested `CLAUDE.md` files when it accesses their
subtrees. Codex builds its `AGENTS.md` chain from the repository root to the
session's working directory once per run. The root router therefore tells a
root-started Codex to read each nested `CLAUDE.md` along the target path; a Codex
session started inside a runtime receives the same canonical files through the
sibling symlinks.

Loader references:

- [Claude Code memory](https://code.claude.com/docs/en/memory)
- [Codex `AGENTS.md`](https://learn.chatgpt.com/docs/agent-configuration/agents-md)

Do not use `@import` to load `CODING.md` or large reference documents. Imports
are expanded into context and therefore improve organization without reducing
context cost.

Do not migrate this repository to `.claude/rules/` in this change. Path-scoped
Claude rules are useful, but would introduce a Claude-only second instruction
system and weaken the current Claude/Codex single-source arrangement.

## Repository Drift Identified at Planning Time

The instruction rewrite must reflect the current worktree, including stable
contracts present in uncommitted code, while avoiding claims that an uncommitted
feature has shipped.

### Root instruction drift

1. File storage is no longer Cloudflare-R2-only. The API resolves generic
   S3-compatible object storage, retains R2 compatibility settings, and the
   supported self-host stack uses MinIO.
2. Migration 024 did not drop `classified_as` or its enum. It retained them as
   compatibility-only storage while introducing `todo_at` and `done_at`.
3. The root data-model inventory stops at migration 027. The repository now has
   upload-operation, media-deletion-outbox, archive-import-operation,
   markdown-import-operation, PostgreSQL auth-state, and Capture-share storage.
   The fix is to remove the volatile full schema inventory from the root rather
   than continually expanding it.
4. `web/src/constants/` exists and contains `features.ts`.
5. The migration rule is overstated as "never edit by hand." The actual rule is:
   create migrations through the repository command, edit a newly created
   unapplied migration as needed, and never modify an already-applied migration.
6. The local verification list is not identical to CI. CI additionally runs Go
   race tests, Web and Desktop E2E, extension verification/package creation, the
   deterministic RAG benchmark, and the self-host persistence E2E.
7. Request logs have request trace IDs, but startup and background-worker logs do
   not have request contexts. Agents must not fabricate a request trace for
   non-request work; workers use stable worker identities where correlation is
   needed.
8. Soft delete is the lifecycle rule for Capture content. It is not a blanket
   ban on hard deletion of auth state, credentials, Capture links, or an
   explicitly deleted account.
9. Generic object-storage settings, extension commands, and supported self-host
   commands exist but are absent from the root routing summary.
10. `python -m pytest` is no longer required to make top-level RAG imports
    resolve because `ragsvc/pyproject.toml` configures `pythonpath = ["."]`.
    `just rag-test` remains the preferred repository command because it selects
    the project environment consistently.

### API instruction drift

Update the package map and invariants for:

- `internal/objectstore`
- capture review
- link URL parsing and link-fetch scheduling
- durable media-deletion outbox
- archive and Markdown import operation identities
- Capture sharing
- generic S3-compatible storage terminology instead of R2-specific wording

The Capture-share contract to record is:

- A share is an explicit, revocable, immutable snapshot of non-empty
  `raw_text`.
- Media, attachments, transcript, related Captures, and surrounding context stay
  private.
- The URL fragment carries the share secret; the API receives it through the
  `Share` authorization scheme. Invalid, missing, revoked, and expired shares
  all return the same not-found surface.
- Creating another share for a Capture replaces the active link.
- Moving the source Capture to Trash revokes the share permanently; restoring
  the Capture must not reactivate the old share.
- Document this as a current worktree contract, not as a production-release
  claim until the feature is committed and released.

### Web instruction drift

- `components/ui/` contains extracted primitives and is not empty.
- `constants/` exists.
- Authenticated routes now sit behind the pathless `_authenticated` layout.
- The Web app remembers a safe internal destination before sending a user to
  sign-in and returns there only after successful authentication.
- Refresh and failure results are scoped to the access-token snapshot that
  initiated the request; stale 401s must not clear or overwrite a newer login.
- `/s/$shareId` is intentionally public while ordinary Capture routes remain
  authenticated.
- Direct media uses Chronicle's configured object storage, not specifically R2.
- `web/CLAUDE.md` must become a short workspace router. React-app architecture
  belongs in `web/src/CLAUDE.md`; extension architecture belongs in
  `web/extension/CLAUDE.md`.

### Desktop instruction drift

Refresh the map for the current Core and App split, including secure staged file
reads, Google Drive transport, session monitoring, user identity, capture-share
client/model, share sheet, and Shared Copies settings. Preserve the existing
offline queue, credential-origin, sync serialization, search-layer, localization,
pagination, and sticky sizing invariants.

Record only the stable Capture-share boundaries shared with the API. Do not turn
the local instruction file into a user-facing feature-status document.

### RAG instruction drift

- Include `/related`, `/config`, and `/backfill-queue` in the surface map.
- Keep the user-scoped trust boundary and exact-cosine/cache/chunking decisions.
- Replace the stale import-resolution rationale with `just rag-test` as the
  preferred verification entry point.
- Point volatile backend defaults to live environment/config sources instead of
  copying a large configuration table into the instruction file.

## Coding Rules Boundary

Keep `CODING.md` as a separate, on-demand document. Root `CLAUDE.md` will contain
one trigger:

> Before modifying, generating, or reviewing code, read `CODING.md`. Skip it for
> pure reading, explanation, planning, and repository navigation.

Move coding-only rules out of always-loaded instruction files, including:

- route/component size limits
- generated-file and migration workflow
- TypeScript imports, `any`, non-null assertions, and return types
- API request and mutation-error conventions
- log-call conventions
- formatting, linting, and test expectations

Correct these overbroad statements in `CODING.md`:

1. Configuration belongs in the owning runtime's centralized configuration
   path. It does not all flow through Go `envconfig`; Web, Desktop, RAG, and the
   extension have their own configuration boundaries.
2. Production database access goes through sqlc. Tests may use explicit raw SQL
   only for fixture setup, fault injection, or assertions that are not product
   query paths.
3. The orval rule applies to ordinary Web-app API operations under `web/src`.
   Multipart upload and browser-protocol auth ceremonies use their established
   centralized helpers. Do not add new ad-hoc `fetch` calls in components.
4. Request-path logs use the trace ID already present in context. Startup and
   worker logs use their natural process/worker context and do not invent a
   request trace ID.
5. Capture content is soft-deleted by default, with permanent deletion only from
   Trash. This does not prohibit hard deletion of ephemeral auth state,
   credentials, relationships, or an explicitly deleted account.

## Hard-Rule Contradictions Found in Code

Do not weaken instructions merely to make these existing implementation debts
look compliant:

- Several route components exceed the current 60-line extraction threshold,
  including the authenticated Captures route.
- `LoginProviders` and `LoginMfaStep` contain direct component-level `fetch`
  calls despite the centralized API-transport rule.

The documentation refactor reports these contradictions but does not refactor
application code. Resolve them in a separately scoped implementation task. The
route rule may be worded prospectively (new or materially edited route code must
not add to the debt) so an unrelated change does not silently become a broad UI
refactor.

## File Changes

This is one independently mergeable documentation change affecting ten
instruction paths. This plan document is the eleventh path in the final commit:

1. `CLAUDE.md`: rewrite as the lean repository/product/router layer; target no
   more than 140 lines.
2. `api/CLAUDE.md`: refresh API boundaries and current stable invariants.
3. `web/CLAUDE.md`: shrink to pnpm-workspace and runtime routing notes.
4. `web/src/CLAUDE.md`: add React/TanStack app architecture and auth lifecycle.
5. `web/src/AGENTS.md`: symlink to `CLAUDE.md`.
6. `web/extension/CLAUDE.md`: add MV3 runtime, permission, queue, retry,
   idempotency, and origin/token-scope invariants.
7. `web/extension/AGENTS.md`: symlink to `CLAUDE.md`.
8. `desktop/CLAUDE.md`: refresh Desktop maps and invariants.
9. `ragsvc/CLAUDE.md`: refresh service surface and verification guidance.
10. `CODING.md`: retain as on-demand guidance, consolidate coding-only rules,
    and correct overbroad rules.

Existing root, API, Web, Desktop, and RAG `AGENTS.md` symlinks require no content
edits because they already point to their sibling `CLAUDE.md`.

Entity delta: +4 / -0. The additions are two scoped instruction sources and two
Codex compatibility symlinks. There are no public API, schema, runtime,
dependency, command, or configuration additions.

## Implementation Sequence

Perform this as one documentation change so the hierarchy never lands in a
state where rules have been removed from the root without a canonical local
destination.

1. Re-read the current worktree and diff before editing. Current code and config
   override this parked plan if they have changed.
2. Classify every existing instruction as one of:
   - always-on product or repository invariant
   - runtime-local architecture invariant
   - coding/review-only rule
   - volatile fact discoverable from code/config
3. Rewrite root `CLAUDE.md` and remove duplicate product prose, detailed schema,
   copied command matrices, and language-specific coding rules.
4. Update the four existing runtime instruction files and split Web into the
   workspace, app, and extension levels described above.
5. Consolidate coding/review-only material in `CODING.md`.
6. Create the two new `AGENTS.md` symlinks.
7. Grep every affected instruction file for all occurrences of each corrected
   stale phrase; do not stop after the first match.
8. Run the verification below and inspect the complete documentation diff.

## Verification

Run from the repository root:

```bash
wc -l CLAUDE.md api/CLAUDE.md web/CLAUDE.md web/src/CLAUDE.md \
  web/extension/CLAUDE.md desktop/CLAUDE.md ragsvc/CLAUDE.md CODING.md

find . -path './web/node_modules' -prune -o \
  \( -name CLAUDE.md -o -name AGENTS.md \) -print | sort

readlink AGENTS.md
readlink api/AGENTS.md
readlink web/AGENTS.md
readlink web/src/AGENTS.md
readlink web/extension/AGENTS.md
readlink desktop/AGENTS.md
readlink ragsvc/AGENTS.md

rg -n 'Cloudflare R2 \(images|classification enum.*dropped|none yet|currently empty|never edit by hand|CI runs these same steps exactly|top-level imports resolve' \
  CLAUDE.md api/CLAUDE.md web/CLAUDE.md web/src/CLAUDE.md \
  web/extension/CLAUDE.md desktop/CLAUDE.md ragsvc/CLAUDE.md CODING.md

git diff --check
git diff -- CLAUDE.md CODING.md api/CLAUDE.md web/CLAUDE.md \
  web/src/CLAUDE.md web/src/AGENTS.md web/extension/CLAUDE.md \
  web/extension/AGENTS.md desktop/CLAUDE.md ragsvc/CLAUDE.md
```

Expected results:

- Root `CLAUDE.md` is at most 140 lines.
- Every listed `AGENTS.md` resolves to `CLAUDE.md` in its own directory.
- The stale-phrase grep returns no outdated claim. If a term remains in a
  correction note, inspect it manually rather than deleting valid context.
- `git diff --check` has no whitespace errors.
- The diff contains documentation and symlinks only.

Optional live Claude Code acceptance checks:

1. Start a session at the repository root and run `/memory`: only root-level
   project instructions should be eagerly loaded.
2. Read a file under `web/src/`, then run `/memory`: the Web workspace and Web
   app instruction files should now be loaded; the extension file should not.
3. In a fresh session, read a file under `web/extension/`, then run `/memory`:
   the Web workspace and extension instruction files should load; the Web app
   file should not.
4. Confirm `CODING.md` is absent until the task requires code modification,
   generation, or review and the agent explicitly reads it.
5. Use `/context` before and after to compare the instruction footprint.

No application test suite is required because this change modifies no runtime
code. Do not run `/check` as implementation verification unless the change is
combined with code; run it before any later push because the repository's push
policy still applies.

## Scope Boundaries

In scope:

- instruction hierarchy and lazy-loading boundaries
- correcting instruction facts against the live repository
- preserving Claude/Codex parity through symlinks
- documenting stable security and cross-runtime invariants

Out of scope:

- refactoring oversized Web route components
- replacing existing direct component-level auth `fetch` calls
- modifying application code, generated code, migrations, schema, APIs, or
  configuration
- rewriting human-facing `README.md` or roadmap documents
- introducing `.claude/rules/`, skills, hooks, agents, or CI enforcement
- declaring the then-uncommitted Capture-share feature released

## Risk and Rollback

Primary risk: an important hard rule is moved out of always-on context even
though it affects read-only architectural reasoning. Mitigation: retain domain,
security, privacy, compatibility, and cross-runtime behavior invariants in the
appropriate `CLAUDE.md`; move only instructions that matter when changing or
reviewing code into `CODING.md`.

This plan assumes both Claude Code and Codex remain supported. If the repository
becomes Claude-only, path-scoped `.claude/rules/` can be reconsidered later.

Rollback is a normal documentation revert. No data, external state, generated
artifact, credential, service, or migration is touched.

## Implementation Result

Implemented on 2026-08-09. The hierarchy now matches the chosen structure. Root
`CLAUDE.md` is 112 lines, every listed `AGENTS.md` resolves to its sibling
`CLAUDE.md`, the stale-phrase sweep returns no matches, punctuation and Git diff
checks pass, and the change contains documentation and symlinks only.

The official Claude Code and Codex documentation confirms the loader behavior
described above. The optional live `/memory` and `/context` comparison could not
run because the local Claude Code CLI reported `Not logged in`; it remains
available as a future machine-specific smoke test.
