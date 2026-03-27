# Unblocked Integration

Woods can sync extraction data to [Unblocked](https://getunblocked.com) via its
Documents API. This gives Unblocked's automated code review and Q&A tools
structural codebase context — associations, blast radius, entry points, side
effects — alongside the institutional context (PRs, Slack, tickets) it already
provides.

## How It Works

1. **Extract** codebase data with `woods:extract` (the usual pipeline)
2. **Sync** to Unblocked with `woods:unblocked_sync` (or the alias `woods:relay`)
3. Documents appear in your Unblocked collection within ~1 minute
4. Unblocked's code review agent and Q&A tools reference the structural context

Documents are **upserted by URI** — running sync again updates existing documents
without creating duplicates. URIs point to your GitHub repository for working
citation links in Unblocked answers.

## Setup

### 1. Create an Unblocked Collection

In the [Unblocked web app](https://getunblocked.com):

1. Go to **Settings** → **Data Sources** → **Add Data Sources**
2. Scroll to the documentation section and select **Create a Custom Source**
3. Name it (e.g., "Codebase Architecture") and save
4. Copy the collection ID from the URL or API

Or via the API:

```bash
curl -X POST https://getunblocked.com/api/v1/collections \
  -H "Authorization: Bearer $UNBLOCKED_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Codebase Architecture", "description": "Structural metadata from Woods extraction — models, controllers, services, dependencies, and blast radius analysis."}'
```

### 2. Create an API Token

In the Unblocked web app: **Settings** → **API Tokens** → **Create Token**.

- **Personal Access Token** — 1,000 API calls/day, scoped to your account
- **Team Access Token** — access to all team documents (recommended for CI)

### 3. Configure Woods

Via environment variables (recommended for CI):

```bash
export UNBLOCKED_API_TOKEN="ubk_..."
export UNBLOCKED_COLLECTION_ID="12345678-abcd-..."
export UNBLOCKED_REPO_URL="https://github.com/your-org/your-repo"
```

Or in your initializer:

```ruby
Woods.configure do |config|
  config.unblocked_api_token = ENV["UNBLOCKED_API_TOKEN"]
  config.unblocked_collection_id = ENV["UNBLOCKED_COLLECTION_ID"]
  config.unblocked_repo_url = "https://github.com/your-org/your-repo"
end
```

### 4. Run the Sync

```bash
bundle exec rake woods:extract        # Extract codebase data
bundle exec rake woods:unblocked_sync # Sync to Unblocked
```

Or in Docker:

```bash
docker compose exec app bin/rails woods:extract
docker compose exec app bin/rails woods:unblocked_sync
```

## What Gets Synced

| Unit Type | Strategy | Typical Count |
|-----------|----------|---------------|
| Models | All | 100-300 |
| Controllers | All | 100-400 |
| Services | All | 20-50 |
| Jobs | All | 50-150 |
| GraphQL types/resolvers | All | 100-400 |
| Concerns | All | 20-50 |
| Mailers | All | 3-10 |
| Managers | All | 10-30 |
| Decorators | All | 10-30 |
| POROs | Top 100 by dependents | 100 max |
| Libs | Top 50 by dependents | 50 max |

Total: ~800-1200 documents depending on app size.

## Document Format

Each document is a condensed Markdown profile optimized for code review context.

**Models** (highest value) include:
- Association summary grouped by type (belongs_to/has_many/has_one)
- Dependent count by type with blast radius assessment
- Entry points (controllers, GraphQL resolvers, jobs)
- Schema highlights (enums, scopes, concerns, callbacks)
- Side effects (workers, mailers triggered)

**Controllers** include routes, inheritance chain, model dependencies, view templates.

**Services/Jobs/Other types** include dependencies, dependents summary, key
structural data.

## URI Scheme

Document URIs point to the source file on GitHub:

```
https://github.com/your-org/your-repo/blob/main/app/models/order.rb
```

This means Unblocked citations link directly to the relevant source code.

## Rate Limits

The Unblocked API allows 1,000 calls per day (resets at midnight PST). A typical
sync uses ~800-1200 calls for the initial build. If your app exceeds 1,000 units:

- The sync stops gracefully when the budget is exhausted
- Re-run the next day to continue where it left off (upsert is idempotent)
- Set `UNBLOCKED_DAILY_BUDGET` to adjust the limiter if your plan allows more

## CI Integration

Add a post-merge Buildkite (or GitHub Actions) step:

```yaml
# Buildkite example
- label: ":trees: Woods → Unblocked"
  command:
    - bin/rails woods:extract
    - bin/rails woods:unblocked_sync
  branches: main
  env:
    UNBLOCKED_API_TOKEN: "ubk_..."
    UNBLOCKED_COLLECTION_ID: "..."
    UNBLOCKED_REPO_URL: "https://github.com/your-org/your-repo"
```

This keeps the Unblocked collection in sync with main after every merge.

## Incremental Updates

The current implementation pushes all qualifying units on each sync (upsert
ensures idempotency). For large codebases, you can combine with
`woods:incremental` to only re-extract changed files, though the sync itself
still pushes all documents.

Future versions may support diff-based sync that only pushes changed documents.

## Troubleshooting

**"daily budget exhausted"** — You've hit the 1,000 call/day limit. Wait until
midnight PST or use a Team Access Token if higher limits are available.

**"Unblocked API error 401"** — Check your API token. Personal tokens are scoped
to your account; Team tokens access all team data.

**"collection_id is required"** — Set `UNBLOCKED_COLLECTION_ID` env var or
configure `config.unblocked_collection_id`.

**Documents not appearing in answers** — Documents take ~1 minute to become
available. Also verify the collection is enabled in your Unblocked data source
settings.
