---
name: unblocked-sync
description: Setup, operation, and debugging of the Unblocked integration — collection creation, incremental sync, the sync manifest, escape hatches, live API quirks, and smoke testing. Use when working on lib/woods/unblocked/, the woods:unblocked_sync rake task, sync CI wiring, or when a sync misbehaves (everything re-pushes, deletes refused, budget exhausted, 400s from the API).
---

# Unblocked Sync

Woods pushes condensed Markdown profiles of extracted units to an
[Unblocked](https://getunblocked.com) collection via its Documents API.
User-facing reference: `docs/UNBLOCKED_INTEGRATION.md`. This skill is the
agent-facing operational map.

## Components (`lib/woods/unblocked/`)

| File | Role |
|------|------|
| `client.rb` | Net::HTTP REST client. `put_document` (upsert by URI), `delete_document`, `list_documents`/`all_documents` (paginated, no body returned), `create_collection`. There is no `list_collections`. Raises `ApiError < Woods::Error` carrying the HTTP `status`. |
| `document_builder.rb` | Unit JSON → `{title:, body:, uri:}` Markdown. **Every rendered collection is sorted** — body bytes must be a function of content, not input order, because the exporter hashes them. Credential-scrubs bodies (fails closed to empty string). |
| `exporter.rb` | Orchestrates the sync. Skip-if-unchanged via manifest hash, reconcile-on-empty-manifest, orphan purge with safety guards. |
| `sync_manifest.rb` | JSON at `<output_dir>/unblocked_sync_manifest.json`: `uri → {hash, document_id}`. Atomic save; discards itself on collection-id mismatch or corrupt file (degrades to full re-push). |
| `rate_limiter.rb` | 1000-calls/day budget (override: `UNBLOCKED_DAILY_BUDGET`). Raises `BudgetExhaustedError < Woods::Error` when spent. |

## Setup (one-time per host app)

1. Team API token: Unblocked web app → Settings → API Tokens.
2. Create the collection **via the API** (no UI path):
   ```ruby
   client = Woods::Unblocked::Client.new(api_token: ENV['UNBLOCKED_API_TOKEN'])
   client.create_collection(name: '...', description: '...')['id']
   ```
   `iconUrl` defaults to `Client::DEFAULT_ICON_URL` (the repo-hosted Woods
   mark). **The live API 400s without an iconUrl** even though its docs say
   optional — never strip the default.
3. Set `UNBLOCKED_API_TOKEN`, `UNBLOCKED_COLLECTION_ID`, `UNBLOCKED_REPO_URL`
   (env vars override `Woods.configure` values in the rake task).
4. Run `bin/rails woods:extract` then `bin/rails woods:unblocked_sync`
   (alias: `woods:relay`).

## How incremental sync decides

- **Skip:** SHA256 of built `title + "\n" + body` matches the manifest entry.
- **Push:** hash differs or URI unknown. `put_document` upserts by URI.
- **Delete:** manifest URIs absent from the current run's full unit set
  (partial-sync types track ALL existing units, so a poro falling out of the
  top-100 is *not* a deletion).
- **Inventory:** every run (not a dry run) first calls
  `all_documents(collection_id: nil)` for the whole remote inventory. A short
  page is not proof of completion, and a malformed page or repeated cursor
  raises before any write. A URI already in another collection is refused.
- **Receipts:** a manifest entry is deletion authority only when it records a
  successful push (non-nil hash, `owned`). A missing manifest re-pushes current
  documents and records fresh receipts. It does not adopt unrelated remote
  documents for deletion, so old remote documents are not purged. Entries with
  a nil `document_id` are resolved from the inventory before a purge, and a
  delete needs the remote id and collection to match the receipt.

### Purge safety rails (both intentional — do not "fix")

- Budget exhausted mid-run → purge skipped entirely (current set incomplete).
- Mass-deletion guard: refuses to delete >30% of a ≥10-doc manifest unless
  `UNBLOCKED_FORCE_PURGE=1`. Triggers when someone syncs a partial index
  (e.g. `woods:incremental` output in a fresh directory).

## Escape hatches (truthy: `1`/`true`/`yes`, case-insensitive)

- `UNBLOCKED_FORCE_FULL_SYNC` — re-push everything, ignoring the unchanged
  check. Use after a `DocumentBuilder` format change to make intent explicit
  (every body hash shifts anyway, so the effect is the same either way).
- `UNBLOCKED_FORCE_PURGE` — bypass the mass-deletion guard. **This is the flag
  a `unblocked_repo_url` change needs:** every URI changes, so everything
  re-pushes on its own (all URIs are new to the manifest), but the old-URI
  documents become 100% of the stale set — which trips the >30% guard — and
  they persist as remote duplicates until a run with FORCE_PURGE deletes them.

## Symptom → cause

| Symptom | Likely cause |
|---------|--------------|
| Everything re-pushes every run | Manifest not persisted between CI runs (cache restore missing), OR a `DocumentBuilder` change altered all bodies, OR nondeterministic body output (unsorted collection — check any new `build_*` method) |
| `0 synced, N skipped`, but docs stale in Unblocked | Hash matched a stale manifest from another checkout. Restore the right manifest, or run once with `UNBLOCKED_FORCE_FULL_SYNC=1` to re-push. Deleting the manifest also re-pushes, but forfeits deletion receipts for earlier documents |
| `Unblocked manifest needs recovery: ...` (or a `discarding sync manifest` warning) | Manifest is unparseable, unreadable, an unsupported schema version, malformed, or written for a different collection. Sync refuses before any remote change. Restore a known-good copy from the CI cache. Force flags do not bypass it |
| `cleanup incomplete: legacy owned documents remain` | A v1 manifest receipt has no repo/ref scope. Set `UNBLOCKED_MIGRATE_FROM_REF` to the known source ref (preview with `UNBLOCKED_DRY_RUN=1`), or clean up manually. `UNBLOCKED_FORCE_PURGE` does not help |
| A few units re-push every warm run; manifest entry count < synced | Multiple units share one `file_path` (nested/namespaced classes, several classes per `.rb`). `build_uri_index` disambiguates them (`?unit=` suffix on all but the lexically-first identifier) — if it regresses, those units collide on one URI again |
| A unit's document is missing from the collection (only one of N co-located classes present) | Same file-sharing collision overwriting on a shared URI — `build_uri_index` is the fix |
| `WARNING: refusing to delete X of Y documents` | Partial index — sync against full extraction output. Or an *intentional* large removal (type dropped from FULL_SYNC_TYPES, `unblocked_repo_url` change, big deletion): re-run once with `UNBLOCKED_FORCE_PURGE=1` |
| `daily budget exhausted` | >1000 calls today. Cold start needs ~1005 for ~1000 docs; converges next run. Raise `UNBLOCKED_DAILY_BUDGET` only if the plan allows |
| Bare `400 Bad Request` on create_collection | Missing `iconUrl` (live-API quirk) |
| `TypeError` parsing list responses | Live API returns bare JSON arrays, not `{items:}` envelopes — guard with `is_a?(Array)` first |

## Working on this code

- **TDD per repo conventions.** Exporter specs use a `manifest_double` helper;
  client specs stub `Net::HTTP` (see `stub_http_sequence`).
- **Determinism is a hard invariant:** any new `DocumentBuilder` output must be
  byte-identical across runs for unchanged input — extend the order-independence
  spec in `spec/unblocked/document_builder_spec.rb` when adding sections.
- Error classes: raise/rescue `ApiError` (required `status`) for HTTP failures;
  `BudgetExhaustedError` for budget stops — detected in `note_budget_exhaustion`
  (single chokepoint; class check with a message-text fallback).
- **Live smoke** (writes to the real org, self-cleaning): create temp collection
  → put → `all_documents` → delete doc → delete collection. Needs the
  Team token. Pattern: `script` it against `Client` directly; never log the token.
- Concurrency: the gem does not lock the manifest — CI must serialize sync runs
  (Buildkite `concurrency_group` / GHA `concurrency:`).
