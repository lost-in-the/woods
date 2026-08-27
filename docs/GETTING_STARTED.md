# Getting Started

This guide walks you through installing Woods, running your first extraction, and inspecting the output.

## Prerequisites

- Ruby >= 3.0 (through Ruby 4.0)
- A Rails application (6.0+)
- Bundler

### Supported versions

Woods declares `railties >= 6.0` and is exercised in CI across the Rails and Ruby
versions below (the booted-app extraction test runs against each Rails row):

| Rails | Tested Ruby |
|---|---|
| 6.0 | 3.0 |
| 6.1 | 3.0 |
| 7.0 | 3.1 |
| 7.1 | 3.2 |
| 7.2 | 3.3 |
| 8.0 | 3.3, 4.0 |

Newer Ruby/Rails point releases within these lines are expected to work; the
matrix pins one representative Ruby per Rails line and excludes invalid pairings
(e.g. Rails 6.0 does not run on Ruby 3.2+, Rails 8.0 requires Ruby >= 3.2).

## 1. Install the Gem

Add Woods to your Rails app's Gemfile:

```ruby
# Gemfile
group :development do
  gem 'woods'
end
```

```bash
bundle install
```

> **Docker:** Run `docker compose exec app bundle install` and all subsequent commands through `docker compose exec app ...`. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker workflow.

Then run the install generator:

```bash
bundle exec rails generate woods:install
```

This creates `config/initializers/woods.rb` with annotated default configuration, and a migration for Woods tables (`woods_units`, `woods_edges`, `woods_embeddings`). Run migrations after the generator:

```bash
bundle exec rails db:migrate
```

> **Important:** Woods requires a booted Rails environment for extraction. It uses runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) to produce accurate output. It cannot extract from source files alone.

## 2. Configure

The generated initializer provides sensible defaults. Here's a minimal configuration:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
end
```

For a full list of options, see [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).

### Storage Presets

For quick setup, use a named preset:

```ruby
# In-memory vectors, SQLite metadata, Ollama embeddings (no external services)
Woods.configure_with_preset(:local)

# pgvector + OpenAI embeddings (PostgreSQL required)
Woods.configure_with_preset(:postgresql)

# Qdrant + OpenAI embeddings (production-scale)
Woods.configure_with_preset(:production)
```

The pgvector store keeps its vectors in a dedicated `woods_vectors` table (id, native `vector` column, JSONB metadata, HNSW index), which Woods creates automatically on first use with idempotent DDL. If you prefer to manage that schema through your app's migrations, `rails generate woods:pgvector && rails db:migrate` creates the same table (use `--dimensions` to match your embedding model). MySQL hosts pair with Qdrant (or another external vector store) instead — MySQL has no vector extension; see [BACKEND_MATRIX.md](BACKEND_MATRIX.md).

## 3. Extract

Run a full extraction from your Rails app root:

```bash
bundle exec rake woods:extract
# Alias: woods:scan

# Docker:
# docker compose exec app bundle exec rake woods:extract
```

This will:
1. Boot Rails and eager-load all application classes
2. Run each enabled extractor (models, controllers, services, jobs, etc.)
3. Build the dependency graph with forward and reverse edges
4. Enrich units with git metadata (last modified, contributors, change frequency)
5. Write JSON output to `tmp/woods/`

Extraction time depends on your codebase size. A typical mid-size Rails app (50-100 models) takes 10-30 seconds.

## 4. Inspect the Output

After extraction, explore the output directory:

```bash
# Overview
bundle exec rake woods:stats
# Alias: woods:look

# Check integrity
bundle exec rake woods:validate
# Alias: woods:vet
```

The output directory structure:

```
tmp/woods/
├── manifest.json              # Extraction metadata, git SHA, unit counts
├── dependency_graph.json      # Full graph with forward/reverse edges + PageRank
├── SUMMARY.md                 # Human-readable structural overview
├── models/
│   ├── _index.json            # Quick lookup index for this type
│   ├── User.json              # Full extracted unit
│   └── Order.json
├── controllers/
│   └── OrdersController.json
├── services/
│   └── CheckoutService.json
└── ...
```

Each unit JSON contains:

| Field | Description |
|-------|-------------|
| `identifier` | Unique name (e.g., `User`, `OrdersController`) |
| `type` | Category (model, controller, service, job, etc.) |
| `file_path` | Source file location relative to Rails.root |
| `source_code` | Annotated source with inlined concerns and schema |
| `metadata` | Rich structured data (associations, callbacks, routes, etc.) |
| `dependencies` | What this unit depends on, with relationship type |
| `dependents` | What depends on this unit |
| `estimated_tokens` | Token count estimate for LLM context budgeting |
| `chunks` | Semantic sub-sections (for large models/controllers) |

## 5. Connect to an AI Tool

Woods ships two MCP servers for integrating with AI development tools.

### Index Server (reads pre-extracted data)

```bash
# Start the MCP server pointing at your extraction output
woods-mcp tmp/woods
```

Configure in your AI tool's MCP settings:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp",
      "args": ["/path/to/your-rails-app/tmp/woods"]
    }
  }
}
```

> Use `woods-mcp-start` on Claude Code for automatic restart after crashes. Use `woods-mcp` on Cursor, Windsurf, or other MCP clients.

### Console Server (live Rails queries)

```bash
# Start the console MCP server
woods-console-mcp
```

> **Docker:** The Index Server runs on the host reading volume-mounted output — use the host path in `.mcp.json`. The Console Server connects to the container via `docker compose exec -i`. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for Docker-specific `.mcp.json` examples.

See [MCP_SERVERS.md](MCP_SERVERS.md) for detailed setup instructions.

## 6. Incremental Updates

After the initial extraction, use incremental mode to update only changed files:

```bash
bundle exec rake woods:incremental
# Alias: woods:tend
```

This is ideal for CI pipelines:

```yaml
# .github/workflows/index.yml
jobs:
  index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - name: Update index
        run: bundle exec rake woods:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

For Docker-based CI, replace the run command with your compose equivalent:

```yaml
      - name: Update index
        run: docker compose exec -T app bundle exec rake woods:incremental
```

## Custom Boot Requirements

Woods requires Rails to boot successfully before extraction can run. If your app needs specific environment variables, credentials, or a custom boot sequence, set them up first.

### Environment Variables

Set any required env vars before running `rake woods:extract`:

```bash
# Verify Rails boots cleanly
RAILS_MASTER_KEY=your-key DATABASE_URL=your-url bundle exec rails runner 'puts :OK'

# Then extract with the same env vars
RAILS_MASTER_KEY=your-key DATABASE_URL=your-url bundle exec rake woods:extract
```

Common variables that extraction may need:

| Variable | Why | Notes |
|----------|-----|-------|
| `RAILS_MASTER_KEY` | Decrypt credentials | Or place `config/master.key` in the app |
| `DATABASE_URL` | Database connection | Extraction reads schema from the live database |
| `REDIS_URL` | If Rails config requires Redis at boot | Cache store, Action Cable, etc. |
| `SECRET_KEY_BASE` | Some apps require this to boot | Set to any string for extraction |

### Docker Extraction

Inside Docker, env vars are typically set in `docker-compose.yml` or `.env`. Run extraction through compose:

```bash
docker compose exec app bundle exec rake woods:extract
```

The MCP Index Server runs on the **host**, reading volume-mounted output. Use the host-side path in `.mcp.json`:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

### CI Extraction

In CI, set env vars in your workflow and use the `test` or `development` Rails environment:

```yaml
- name: Extract codebase
  run: bundle exec rake woods:extract
  env:
    RAILS_ENV: test
    RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

### Conditional Configuration

Use environment checks in the initializer to adapt extraction behavior:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.output_dir = ENV.fetch('WOODS_OUTPUT_DIR', Rails.root.join('tmp/woods'))

  # CI: skip framework source extraction for faster builds.
  # (config.extractors can't select a subset — it's accepted for forward
  # compatibility only. See CONFIGURATION_REFERENCE.md#extractors.)
  config.include_framework_sources = false if ENV['CI']

  # Choose embedding provider based on available credentials
  if ENV['OPENAI_API_KEY']
    config.embedding_provider = :openai
    config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
  else
    config.embedding_provider = :ollama
    config.embedding_options = {
      model: 'nomic-embed-text',
      host: ENV.fetch('OLLAMA_URL', 'http://localhost:11434')
    }
  end
end
```

### Troubleshooting Boot Failures

If extraction fails, isolate the problem:

```bash
# 1. Does Rails boot?
bundle exec rails runner 'puts :OK'

# 2. Does eager loading work? (extraction needs this)
bundle exec rails runner 'Rails.application.eager_load!; puts "Loaded #{ActiveRecord::Base.descendants.count} models"'

# 3. If step 2 fails with NameError, which directory causes it?
bundle exec rails runner 'Rails.autoloaders.main.dirs.each { |d| puts d }'
```

The most common boot failures are `NameError` from `app/graphql/` referencing an uninstalled gem, or missing credentials. Woods falls back to per-directory loading when `eager_load!` fails, but some models may be missed.

---

## Common First-Run Issues

**Extraction produces 0 units** — Rails booted but `eager_load!` failed. Run `bundle exec rails runner 'Rails.application.eager_load!; puts "OK"'` and look for `NameError`. The most common cause is `app/graphql/` referencing an uninstalled gem.

**"manifest.json not found" from MCP server** — The Index Server path is wrong. It needs the extraction output directory (`tmp/woods`), not the Rails root. Verify with `ls tmp/woods/manifest.json`.

**Console server shows only 9 tools** — Expected behavior by default. Enable
`console_embedded_read_tools` to register `console_sql` and `console_query` as
well. The remaining schemas are inventory only. See
[CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md).

For more, see [Troubleshooting](TROUBLESHOOTING.md).

## Next Steps

- [Configuration Reference](CONFIGURATION_REFERENCE.md) — all options with defaults and examples
- [MCP Servers](MCP_SERVERS.md) — index server vs console server, tool catalog, setup guides
- [Backend Matrix](BACKEND_MATRIX.md) — supported database, vector store, and embedding combinations
- [FAQ](FAQ.md) — common questions about setup, extraction, MCP, Docker
- [Troubleshooting](TROUBLESHOOTING.md) — symptom → cause → fix for common problems
- [Coverage Gap Analysis](COVERAGE_GAP_ANALYSIS.md) — what's extracted and what's not (yet)
