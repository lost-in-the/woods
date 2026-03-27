# Unblocked Exporter — Design Spec

## Purpose

Add a first-class Unblocked integration to woods, following the Notion exporter architecture.
Pushes condensed, review-optimized Markdown documents to Unblocked's Collections API so
automated code reviews and developer Q&A have structural codebase context (associations,
dependents, blast radius, entry points, side effects).

## Architecture

Mirrors `lib/woods/notion/` structure:

```
lib/woods/unblocked/
  client.rb            # REST client for Unblocked API v1
  rate_limiter.rb      # 1000 calls/day budget tracking
  document_builder.rb  # Converts unit JSON → condensed Markdown + URI
  exporter.rb          # Orchestrates sync
```

## Components

### Client

Thin `Net::HTTP` wrapper (same pattern as `Notion::Client`):

- `put_document(collection_id:, title:, body:, uri:)` — upsert by URI
- `create_collection(name:, description:)` — one-time setup
- `list_collections` — for auto-detection
- `delete_document(document_id:)` — cleanup of removed units
- Bearer token auth via `Authorization: Bearer <token>`
- Retry on 429 with `Retry-After` header
- Rate limiting via `RateLimiter`

Base URL: `https://getunblocked.com/api/v1`

### RateLimiter

Different from Notion's (which is requests/second). Unblocked is 1000 calls/day:

- Tracks daily call count against budget
- Warns via stderr when approaching limit (>800 calls)
- Raises `Woods::RateLimitExceeded` when budget exhausted
- Resets at midnight PST (per Unblocked docs)
- Supports `remaining` query for progress reporting

### DocumentBuilder

Core design piece. Takes a unit's JSON hash and produces a document hash:

```ruby
{ title: "Order (model)", body: "# Order (model)\n...", uri: "https://github.com/.../app/models/order.rb" }
```

Formatting strategy per unit type:

**Models** (highest value): associations grouped by type, dependents counted by type with
blast radius assessment, entry points (controllers/GraphQL/jobs), schema highlights
(enums, scopes, concerns), side effects (workers, mailers).

**Controllers**: routes, actions, inheritance chain, model dependencies, view templates.

**Services/Jobs/Mailers/GraphQL/Managers/Decorators/Concerns**: condensed profile with
dependencies, dependents summary, and key methods.

**POROs/Libs**: only top N by dependent count (configurable, default 100/50).

URI scheme: `{repo_url}/blob/main/{file_path}` — produces working GitHub citation links.

### Exporter

Orchestrates the sync (parallel to `Notion::Exporter`):

1. Reads extraction output via `IndexReader`
2. Iterates unit types in priority order
3. Calls `DocumentBuilder` for each unit
4. Pushes via `Client` with URI-based upsert
5. Tracks stats and errors
6. Reports progress to stderr

## Configuration

```ruby
# Added to Woods::Configuration
attr_accessor :unblocked_api_token,        # String — Bearer token
              :unblocked_collection_id,    # String — target collection UUID
              :unblocked_repo_url          # String — GitHub repo base URL for URIs
```

Environment variable overrides:
- `UNBLOCKED_API_TOKEN`
- `UNBLOCKED_COLLECTION_ID`
- `UNBLOCKED_REPO_URL`

## Rake Task

```ruby
desc 'Sync extraction data to Unblocked collection'
task unblocked_sync: :environment

desc 'Relay findings — sync to Unblocked (alias)'
task relay: :unblocked_sync
```

Follows `notion_sync` pattern: env var override, validation, progress output, error reporting.

## Unit Types Synced

| Type | Count (admin) | Strategy |
|------|--------------|----------|
| Models | 212 | All |
| Controllers | 334 | All |
| Services | 35 | All |
| Jobs | 119 | All |
| GraphQL | 306 | All |
| Concerns | 38 | All |
| Mailers | 3 | All |
| Managers | 17 | All |
| Decorators | 23 | All |
| POROs | 752 | Top 100 by dependents |
| Libs | 244 | Top 50 by dependents |

~940 documents for initial sync.

## What This Does NOT Include

- **Domain cluster documents** — tracked as a separate issue
- **Diff-based incremental sync** — upsert is idempotent; optimization comes later
- **Buildkite pipeline config** — that's consumer-side (bc-agents), not gem code

## Testing Strategy

- Unit tests for `Client` (webmock stubs)
- Unit tests for `DocumentBuilder` (fixture-based, verify Markdown output)
- Unit tests for `RateLimiter` (budget tracking)
- Integration test for `Exporter` (mock client, real IndexReader against fixture extraction)
