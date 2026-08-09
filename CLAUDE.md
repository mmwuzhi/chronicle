# Chronicle

Capture anything. Find it later.

Chronicle is a capture-first personal memory system. Its primary job is helping
people retrieve information they have already captured.

## Product direction

The core loop is Capture → Store → Retrieve → Understand (optional). Record
first, organize later, retrieve when needed. Search and recall matter more than
automatic organization; AI enhances them but never replaces them.

Prefer fast capture, search, retrieval, memory recall, review, and related
Captures. Avoid complex project management, workflow automation, deep
hierarchies, mandatory categorization, and other maintenance. When uncertain,
choose the simpler solution.

Priorities:

- P0: fast capture, full-text search, embeddings, hybrid retrieval
- P1: related Captures, memory retrieval, review
- P2: AI summaries, context discovery, forget suggestions
- Deferred: MCP, plugin systems, graph view, advanced analyzers, agent
  workflows, and E2EE; do not introduce these unless explicitly requested

## Repository routing

- `api/`: Go API with chi, huma v2, slog, PostgreSQL, sqlc, and goose
- `web/src/`: Vite React app with TanStack Router/Query, Radix primitives, i18n,
  and orval-generated API bindings
- `web/extension/`: Manifest V3 browser-extension workspace
- `desktop/`: Swift macOS menu-bar and browse app with an offline local store
- `ragsvc/`: optional Python FastAPI retrieval sidecar
- `shared/`: cross-runtime fixtures and contracts

Each runtime has a nested `CLAUDE.md` with its local architecture and
invariants. Claude Code discovers nested files when it enters their subtree.
Codex launched at the repository root must explicitly read every `CLAUDE.md`
along the target path; a Codex session launched inside a subtree receives the
same files through sibling `AGENTS.md` symlinks. Use `Justfile`, package scripts,
`.env.example`, and `.github/workflows/` as the live sources for commands,
configuration, and CI.

The supported self-host stack uses PostgreSQL plus MinIO. Hosted deployments
may use Neon and Cloudflare R2. The API presents both R2 compatibility settings
and generic S3-compatible object storage through one internal interface.

## Domain invariants

- Capture is the primary object. Tasks, contexts, review, summaries, and other
  views are derived facets or relationships, not competing primary objects.
- User labels live in Capture text (`#tag`) and retrieval, not a label schema. A
  lightweight project is a pinned anchor Capture plus `capture_links`; progress
  is derived from linked Captures.
- The todo facet is text-driven. A Capture is a todo only when `raw_text`
  contains the standalone `#todo` token; completion is `#todo(done)` or
  `#todo(done:YYYY-MM-DD)`. `todo_at` and `done_at` are derived indexes. The Go,
  Web, and Desktop grammars all consume `shared/fixtures/todo-tag.json` and must
  change together. Migration 024 retained `classified_as` as compatibility-only
  storage; it is not product behavior. Capture time never asks for a type. Add a
  facet only together with the behavior that needs it, not as speculative
  classification storage.
- Link enrichment treats the first URL in text as the source of truth, stores
  fetched readable content in the transcript modality, and never exposes the
  internal `link_url`. The fetcher is SSRF-guarded and the link/media workers
  partition their shared queue by whether `media_key` is null.
- Capture content is soft-deleted by default. Only an explicit action inside
  Trash may permanently delete already-trashed Capture content. This lifecycle
  rule does not prohibit deleting ephemeral auth state, credentials,
  relationships, or an explicitly deleted account.
- Search must remain useful without optional AI or object storage. Hybrid search
  falls back to PostgreSQL full-text search when the RAG sidecar is unavailable;
  optional integrations must fail without taking core capture/retrieval down.

## Capture sharing contract

This is the current repository contract; do not infer production deployment
status from it.

- A share is an explicit, revocable, immutable snapshot of non-empty
  `raw_text`, not live access to a Capture.
- Media, attachments, transcript, related Captures, and surrounding context
  remain private.
- The URL fragment carries the share secret; clients send it to the API with
  the `Share` authorization scheme. Missing, invalid, expired, and revoked
  shares expose the same not-found surface.
- A new share replaces the Capture's active link. Moving the source Capture to
  Trash permanently revokes its share; restoring it never reactivates that link.

## Cross-runtime contracts

- Queued quick-capture clients use a create-only capture token, HTTPS except on
  loopback, a client-generated `Idempotency-Key`, a stable first-party `source`,
  and one operation identity across retries. Scope durable queues by API origin
  and credential identity; retry only network, 429, and 5xx failures, and expose
  terminal failures. Apple Shortcuts remains synchronous and has no durable
  offline queue.
- Desktop media/file drafts keep one UUID until saved or discarded. That UUID
  is shared by direct upload, Drive upload metadata, and atomic
  Capture-with-attachment creation. Ambiguous outcomes remain retryable.
- API credentials never cross an origin or account boundary. Async refresh
  results are scoped to the credential snapshot that started them, so a stale
  success or 401 cannot overwrite or clear a newer session.
- The product noun **Capture** is unchanged in every locale. Web/Desktop brand
  accent and list-time formatting are paired definitions and must change
  together; their exact paths live in the runtime instructions.

## Coding-rule boundary

Before modifying, generating, or reviewing code, read `CODING.md`. Skip it for
pure reading, explanation, planning, and repository navigation.
