# Notion Integration

Sync your Rails application's data model documentation to Notion databases, making schema, associations, validations, callbacks, and column-level detail accessible to non-technical stakeholders without GitHub access.

## What Gets Synced

CodebaseIndex extracts your Rails application via runtime introspection and pushes structured data to two Notion databases:

**Data Models Database** — One page per ActiveRecord model:
- Table name, model class name, file path
- Associations (has_many, belongs_to, has_one, through, polymorphic)
- Validations (grouped by attribute)
- Callbacks with side-effect analysis (jobs enqueued, services called)
- Scopes
- Column count
- Git metadata (last modified date, change frequency)
- Dependencies (services, jobs, other models referenced)
- Last schema change (from migration history)

**Columns Database** — One page per database column:
- Column name, data type, nullable, default value
- Validation rules (matched from model-level validations)
- Relation to parent Data Models page

All syncs are **idempotent** — existing pages are updated, new pages are created. Re-running the sync is always safe.

## Setup

### 1. Create a Notion Integration

1. Go to [notion.so/my-integrations](https://www.notion.so/my-integrations)
2. Create a new internal integration
3. Copy the API token (starts with `secret_`)

### 2. Create Notion Databases

Create two databases in your Notion workspace with these exact property names and types:

**Data Models Database:**

| Property | Type |
|---|---|
| Table Name | Title |
| Model Name | Text |
| Description | Text |
| Associations | Text |
| Validations | Text |
| Callbacks | Text |
| Scopes | Text |
| Column Count | Number |
| Last Modified | Date |
| Change Frequency | Select (options: new, hot, active, stable, dormant) |
| Last Schema Change | Date |
| File Path | Text |
| Dependencies | Text |

**Columns Database:**

| Property | Type |
|---|---|
| Column Name | Title |
| Table | Relation (→ Data Models database) |
| Data Type | Select (options: string, integer, bigint, boolean, datetime, text, decimal, float, date, binary, json, jsonb) |
| Nullable | Checkbox |
| Default Value | Text |
| Validation Rules | Text |

### 3. Share Databases with Integration

Open each database in Notion, click the `...` menu → "Connections" → add your integration.

### 4. Get Database IDs

Each database URL contains its ID: `https://notion.so/{workspace}/{database_id}?v=...`

### 5. Configure CodebaseIndex

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.notion_api_token = Rails.application.credentials.dig(:notion, :api_token)
  config.notion_database_ids = {
    data_models: 'your-data-models-database-id',
    columns: 'your-columns-database-id'
  }
end
```

Or via environment variables:

```bash
export NOTION_API_TOKEN=secret_...
```

## Common Workflows

### Full Extraction + Sync

```bash
# Extract everything from the Rails app, then push to Notion
bundle exec rake codebase_index:extract
bundle exec rake codebase_index:notion_sync
```

### Post-Migration Sync

```bash
# Re-extract changed files after a migration, then sync
bundle exec rake codebase_index:incremental
bundle exec rake codebase_index:notion_sync
```

### Buildkite CI Integration

Add to your `pipeline.yml`:

```yaml
steps:
  - label: ":database: Extract & Sync to Notion"
    command: |
      bundle exec rake codebase_index:extract
      bundle exec rake codebase_index:notion_sync
    if: build.branch == "main" && build.state == "passed"
    soft_fail: true
    env:
      NOTION_API_TOKEN: $NOTION_API_TOKEN  # Set in pipeline environment settings
```

For post-migration syncs only:

```yaml
steps:
  - label: ":database: Sync Schema to Notion"
    command: |
      bundle exec rake codebase_index:incremental
      bundle exec rake codebase_index:notion_sync
    if: |
      build.message =~ /migrate/i ||
      build.env("FORCE_SCHEMA_SYNC") == "true"
    soft_fail: true
```

### MCP Server

If using the MCP Index Server, the `notion_sync` tool is available:

```json
{
  "tool": "notion_sync",
  "arguments": {}
}
```

### Selective Sync

Only sync Data Models (skip Columns):

```ruby
CodebaseIndex.configure do |config|
  config.notion_database_ids = { data_models: 'db-uuid' }
  # columns key omitted → column sync is skipped
end
```

## What the Gem Handles vs. the Host App

### Gem (automated)

| Database | Content | Source |
|---|---|---|
| Data Models | Schema, associations, validations, callbacks, scopes, git metadata | ModelExtractor + MigrationExtractor |
| Columns | Column details, types, defaults, validation rules | ModelExtractor metadata |

### Host App (you build these)

| Database | Content | How to Build |
|---|---|---|
| Features | Feature ownership, status, user stories, acceptance criteria | Human-authored in Notion |
| User Flows | User-facing flow documentation, triggers, endpoints | Human-authored (future: gem can auto-populate from controller/route extraction) |
| Data Handling | PII classification, encryption, retention policies | Human policy decisions |
| Deploys | Build numbers, environments, deployers, commit SHAs | Buildkite webhook → Rails controller → Notion API |

### Example: Deploy Tracking (Host App)

```ruby
# app/controllers/webhooks/buildkite_controller.rb
module Webhooks
  class BuildkiteController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :verify_buildkite_token

    def create
      payload = JSON.parse(request.body.read)
      NotionDeploySyncJob.perform_later(payload)
      head :ok
    end
  end
end

# app/jobs/notion_deploy_sync_job.rb
class NotionDeploySyncJob < ApplicationJob
  def perform(payload)
    build = payload["build"]
    # Use your own NotionClient to create a Deploys page
    # This is outside CodebaseIndex's scope
  end
end
```

## Rate Limiting

Notion's API allows 3 requests per second. The gem's built-in rate limiter handles this automatically. For large codebases (100+ models), expect the sync to take a few minutes.

If you see 429 errors, the client retries up to 3 times with exponential backoff using the `Retry-After` header.

## Error Handling

The sync collects errors per-model and per-column without stopping. The stats hash returned by `sync_all` includes an `errors` array:

```ruby
stats = exporter.sync_all
stats[:errors]  # => ["User: Notion API error 400: ...", ...]
```

Common errors:
- **401 Unauthorized**: Check your API token
- **404 Not Found**: Check database IDs and ensure the integration has access
- **400 Validation Error**: Check that Notion database properties match the expected schema above
- **429 Rate Limited**: Automatic retry (up to 3 times)

## Architecture

```
Extraction Output (JSON on disk)
       ↓
┌─────────────────────┐
│ IndexReader          │ ← Reads model, column, migration data
└─────────────────────┘
       ↓
┌─────────────────────┐
│ Exporter             │ ← Orchestrates sync flow
├─────────────────────┤
│ ModelMapper          │ ← Maps ExtractedUnit → Notion Data Models properties
│ ColumnMapper         │ ← Maps column metadata → Notion Columns properties
│ MigrationMapper      │ ← Extracts latest migration dates per table
└─────────────────────┘
       ↓
┌─────────────────────┐
│ Client               │ ← Notion API wrapper (Net::HTTP, rate-limited)
│ RateLimiter          │ ← 3 req/sec token bucket
└─────────────────────┘
       ↓
    Notion API
```

## Future Extensions

- **User Flows**: Auto-populate from controller/route extraction (controller actions, HTTP methods, filters, dependencies)
- **Data Handling**: Surface column types and model metadata to assist with PII classification
- **ERD Diagrams**: Generate and attach relationship diagrams to Data Models pages
- **Diff Reporting**: Use temporal snapshots to show what changed between syncs
