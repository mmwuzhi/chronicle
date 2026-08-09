# Chronicle API

The Go API is the authenticated system boundary and PostgreSQL is the source of
truth. Setup, generation, migration, and verification commands live in the root
`Justfile`; environment fields live in `internal/config` and `.env.example`.

## Package map

- `cmd/server`: configuration, PostgreSQL/object-store wiring, middleware
  order, background workers, and every package's `Register(...)` call
- `internal/config`: fail-fast envconfig plus generic S3/R2 object-storage
  resolution
- `internal/objectstore`: the S3-compatible client shared by upload, archive,
  and media deletion; R2 and self-hosted MinIO are provider configurations
- `internal/middleware`: trace IDs, request logging, JWT auth, and bounded rate
  limiting
- `internal/auth`: password/email flows, refresh rotation, Google/GitHub OAuth,
  passkeys, TOTP/recovery codes, create-only Capture tokens, and atomically
  consumed PostgreSQL OAuth/WebAuthn state
- `internal/capture`: Capture CRUD plus todo derivation, reminders, review,
  Trash, attachment references, explicit/semantic links, link URL parsing,
  sharing, pagination, and the durable media-deletion outbox worker
- `internal/upload`: multipart direct-media upload and Whisper/OCR worker
- `internal/linkfetch`: SSRF-guarded readable-page fetch worker
- `internal/search`: `/find` hybrid recall and `/ask` query-time answers
- `internal/ragclient`: optional, user-scoped HTTP client for `ragsvc/`
- `internal/archive`: lossless Chronicle archive export/import with durable
  operation identity
- `internal/importer`: additive Markdown/text/ZIP import and Trash-based undo,
  also backed by durable operation identity
- `internal/ai`: optional text-polish endpoint
- `internal/user`: profile, password, linked-account, and account lifecycle
- `internal/webhook`: user-managed outbound Capture-webhook rules
- `testutil`: migrated shared PostgreSQL test pool

## Authentication and exposure boundaries

- `POST /captures` alone uses `createMW`, accepting either a normal JWT or a
  create-only Capture token. A Capture token must never reach read, update,
  delete, settings, sharing, or other account routes.
- Ordinary Capture and account routes require JWT auth. Rate limiting runs
  before auth: public surfaces are IP-scoped and authenticated surfaces become
  user-scoped after identity is known.
- `GET /public/shares/{id}` is intentionally unauthenticated at the account
  layer, but requires `Authorization: Share <secret>`. UUID, secret, expiry, and
  revocation failures all return the same 404 surface.
- The RAG sidecar has no independent auth. The API authenticates the user and
  forwards trusted `X-User-Id`; the sidecar must remain on localhost or a
  private network.

## Capture lifecycle

- All save paths derive `todo_at`/`done_at` from `raw_text` using
  `capture/todotag.go`. The deprecated ignored `classifiedAs` create field stays
  accepted so older Desktop offline queues can replay. Contract changes must
  preserve at least one release of queued-client compatibility.
- Link detection has one grammar: `capture/linkurl.go`. Create and text edits
  reconcile the first URL. Changed URLs enqueue link fetch; unchanged URLs do
  not refetch; removing the URL clears only link-derived transcript state.
- Link and media transcription jobs share `transcription_status` but are
  partitioned by `media_key IS NULL`. Link fetches re-check SSRF restrictions on
  every redirect, accept only HTML, and cap response size.
- Direct upload accepts transcribable media up to the configured limit. It is a
  raw multipart route outside huma/OpenAPI; direct clients use the established
  upload helper and a stable `Idempotency-Key`.
- Normal Capture deletion is soft. Permanent delete and empty Trash operate only
  on already-trashed Captures. Object keys enter the durable
  `capture_media_deletions` outbox transactionally; the worker retries deletion
  against the configured object store.
- Review is a time-based retrieval view over Captures, not a second content
  model.

## Sharing contract

- A share stores the exact non-empty `snapshotRawText` approved by the owner and
  the source Capture timestamp. It never serializes media, attachments,
  transcript, relationships, or context.
- Secrets are random bearer capabilities returned only to the owner and placed
  in the Web URL fragment. Compare decoded secrets in constant time.
- Creating a share locks the source Capture and revokes its previous active
  share in the same transaction. Trashing a Capture revokes active shares;
  restore does not reverse revocation.
- Owner list/create/revoke operations remain JWT-authenticated and user-scoped.

## Imports, indexing, and optional services

- Chronicle archive restore is lossless replacement/recovery; Markdown import
  is additive content ingestion. Do not blur the contracts. Both persist
  operation identity so retries after ambiguous outcomes are safe.
- Capture writes index/extract best-effort. `/find` falls back to PostgreSQL FTS
  if RAG is disabled or unavailable; `/ask` requires the sidecar.
- Visibility mutations that do not re-index (Trash, restore, permanent delete,
  empty Trash) invalidate the user's RAG corpus cache best-effort.
- Webhook delivery and object removal are side effects. Their failures must not
  roll back a committed Capture mutation; durable repair/outbox paths own retry.
