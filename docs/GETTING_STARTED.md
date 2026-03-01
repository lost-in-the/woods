# Getting Started

This guide walks you through installing CodebaseIndex, running your first extraction, and inspecting the output.

## Prerequisites

- Ruby >= 3.0
- A Rails application (6.1+)
- Bundler

## 1. Install the Gem

Add CodebaseIndex to your Rails app's Gemfile:

```ruby
# Gemfile
group :development do
  gem 'codebase_index'
end
```

```bash
bundle install
```

> **Docker:** Run `docker compose exec app bundle install` and all subsequent commands through `docker compose exec app ...`. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker workflow.

Then run the install generator:

```bash
bundle exec rails generate codebase_index:install
```

This creates `config/initializers/codebase_index.rb` with default configuration.

> **Important:** CodebaseIndex requires a booted Rails environment for extraction. It uses runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) to produce accurate output. It cannot extract from source files alone.

## 2. Configure

The generated initializer provides sensible defaults. Here's a minimal configuration:

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
end
```

For a full list of options, see [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).

### Storage Presets

For quick setup, use a named preset:

```ruby
# In-memory vectors, SQLite metadata, Ollama embeddings (no external services)
CodebaseIndex.configure_with_preset(:local)

# pgvector + OpenAI embeddings (PostgreSQL required)
CodebaseIndex.configure_with_preset(:postgresql)

# Qdrant + OpenAI embeddings (production-scale)
CodebaseIndex.configure_with_preset(:production)
```

## 3. Extract

Run a full extraction from your Rails app root:

```bash
bundle exec rake codebase_index:extract

# Docker:
# docker compose exec app bundle exec rake codebase_index:extract
```

This will:
1. Boot Rails and eager-load all application classes
2. Run each enabled extractor (models, controllers, services, jobs, etc.)
3. Build the dependency graph with forward and reverse edges
4. Enrich units with git metadata (last modified, contributors, change frequency)
5. Write JSON output to `tmp/codebase_index/`

Extraction time depends on your codebase size. A typical mid-size Rails app (50-100 models) takes 10-30 seconds.

## 4. Inspect the Output

After extraction, explore the output directory:

```bash
# Overview
bundle exec rake codebase_index:stats

# Check integrity
bundle exec rake codebase_index:validate
```

The output directory structure:

```
tmp/codebase_index/
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

CodebaseIndex ships two MCP servers for integrating with AI development tools.

### Index Server (reads pre-extracted data)

```bash
# Start the MCP server pointing at your extraction output
codebase-index-mcp tmp/codebase_index
```

Configure in your AI tool's MCP settings:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp",
      "args": ["/path/to/your-rails-app/tmp/codebase_index"]
    }
  }
}
```

### Console Server (live Rails queries)

```bash
# Start the console MCP server
codebase-console-mcp
```

> **Docker:** The Index Server runs on the host reading volume-mounted output — use the host path in `.mcp.json`. The Console Server connects to the container via `docker compose exec -i`. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for Docker-specific `.mcp.json` examples.

See [MCP_SERVERS.md](MCP_SERVERS.md) for detailed setup instructions.

## 6. Incremental Updates

After the initial extraction, use incremental mode to update only changed files:

```bash
bundle exec rake codebase_index:incremental
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
        run: bundle exec rake codebase_index:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

For Docker-based CI, replace the run command with your compose equivalent:

```yaml
      - name: Update index
        run: docker compose exec -T app bundle exec rake codebase_index:incremental
```

## Next Steps

- [Configuration Reference](CONFIGURATION_REFERENCE.md) — all options with defaults and examples
- [MCP Servers](MCP_SERVERS.md) — index server vs console server, tool catalog, setup guides
- [Backend Matrix](BACKEND_MATRIX.md) — supported database, vector store, and embedding combinations
- [Coverage Gap Analysis](COVERAGE_GAP_ANALYSIS.md) — what's extracted and what's not (yet)
