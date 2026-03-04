# Frequently Asked Questions

---

## General

### Does CodebaseIndex work without Rails?

No — CodebaseIndex requires a booted Rails environment for extraction. It uses runtime introspection APIs (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) that only exist inside a running Rails application. Static analysis of source files alone cannot produce the accurate, inlined output that CodebaseIndex generates. The MCP Index Server does *not* require Rails — it reads pre-extracted JSON from disk — but the extraction step itself always does.

---

### What Rails versions does CodebaseIndex support?

CodebaseIndex supports Rails 6.1 and newer, with Ruby 3.0 or newer. It is tested against Rails 7.x and 8.x. Rails 6.0 and earlier are not supported because the gem relies on Zeitwerk autoloading and several reflection APIs introduced in 6.1.

---

### Does CodebaseIndex work with MySQL?

Yes — MySQL, PostgreSQL, and SQLite are all supported equally as application databases. CodebaseIndex extraction uses ActiveRecord's database-agnostic reflection APIs and never issues raw SQL during extraction. The only backend-specific requirement is pgvector, which is PostgreSQL-only and optional. All other storage backends (SQLite metadata store, Qdrant, in-memory) work identically with MySQL and PostgreSQL. See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

### How large a codebase can CodebaseIndex handle?

CodebaseIndex has been tested on applications with 200+ models and 500+ extractable units. Extraction time scales roughly linearly with codebase size — a mid-size app (50-100 models) takes 10-30 seconds. Very large applications benefit from disabling `include_framework_sources` and using incremental mode for subsequent runs.

---

### Does extraction modify my database?

No. Extraction is entirely read-only. It uses ActiveRecord reflection APIs (`columns`, `reflect_on_all_associations`, `_validators`, etc.) rather than running queries against application data. No records are created, modified, or deleted during extraction.

---

### Can I run CodebaseIndex in production?

Extraction is designed for development and CI environments — it requires a fully booted Rails environment and takes 10-30 seconds. The MCP servers are read-only development tools. Running extraction in production is technically possible but not recommended. The common pattern is to extract in CI and publish the JSON output as a build artifact.

---

## Setup

### How do I install CodebaseIndex?

Add the gem to your Gemfile and run the install generator:

```ruby
# Gemfile
group :development do
  gem 'codebase_index'
end
```

```bash
bundle install
bundle exec rails generate codebase_index:install
```

The generator creates `config/initializers/codebase_index.rb` with default configuration. For Docker projects, run these commands through `docker compose exec app`. See [GETTING_STARTED.md](GETTING_STARTED.md) for the full setup walkthrough.

---

### What is the minimum configuration?

The only required option is `output_dir`, which has a sensible default:

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')  # default
end
```

With just this, you can run `rake codebase_index:extract` and get full extraction output. Embedding and vector storage require additional configuration — see [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).

---

### How do I set up the MCP server for Claude Code?

Use the `codebase-index-mcp-start` wrapper, which validates the index and restarts on failure:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["/path/to/your-rails-app/tmp/codebase_index"]
    }
  }
}
```

Add this to `.mcp.json` in your Rails app root (for project-scoped config) or to `claude_desktop_config.json` (for global config). Run `rake codebase_index:extract` first to generate the index. See [MCP_SERVERS.md](MCP_SERVERS.md) for the full setup guide.

---

### How do I set up the MCP server for Cursor?

Use `codebase-index-mcp` (without the `-start` wrapper, which is Claude Code-specific):

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

Add this to `.cursor/mcp.json` in your project. See [MCP_SERVERS.md](MCP_SERVERS.md) for details.

---

### How do I set up the MCP server for Windsurf?

The setup is the same as Cursor — use `codebase-index-mcp` (not the `-start` wrapper):

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

Add this to your Windsurf MCP configuration file. The Index Server is transport-agnostic and works with any MCP-compliant client.

---

## Extraction

### What does CodebaseIndex extract?

CodebaseIndex extracts 34 types of units from a Rails application. The default extraction set includes models (with inlined concerns and schema), controllers, services, view components, jobs, mailers, GraphQL types/mutations/queries, serializers, managers, policies, validators, and Rails framework source. Additional extractors are available for state machines, events, decorators, database views, rake tasks, Action Cable channels, and more. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for the full extractor list.

---

### Why does CodebaseIndex inline concerns?

When a model includes a concern, the behavior defined in that concern is part of the model's effective API — callbacks fire, validations run, scopes are available. A tool that reports only what's in `app/models/user.rb` misses everything defined in included concerns. CodebaseIndex inlines concern source directly into each unit's `source_code` field so the full behavioral picture is in one place. This is the key differentiator from file-level tools.

---

### How do I update the index after code changes?

Use incremental mode, which re-extracts only files that have changed since the last run:

```bash
bundle exec rake codebase_index:incremental

# Docker:
docker compose exec app bundle exec rake codebase_index:incremental
```

Incremental mode is ideal for CI pipelines and local development workflows. It is typically 5-10× faster than a full extraction. Note that some unit types (routes, middleware, engines) require full extraction to update — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for details.

---

### How do I add semantic search with embeddings?

Configure an embedding provider, then run the embed task:

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  # OpenAI (cloud)
  config.embedding_provider = :openai
  config.embedding_model = 'text-embedding-3-small'
  config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }

  # Ollama (local, no API key needed)
  # config.embedding_provider = :ollama
  # config.embedding_model = 'nomic-embed-text'
end
```

```bash
bundle exec rake codebase_index:embed
```

After embedding, the `codebase_retrieve` MCP tool supports natural-language queries ranked by semantic similarity. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for vector storage options.

---

### Why do some extractor types require full extraction?

Unit types that don't map to individual files — routes, middleware, engines, scheduled jobs, state machines, events, and factories — are extracted by introspecting the entire application at once rather than a single file. There's no way to incrementally update them by watching one file change. When any of these types change, run a full extraction:

```bash
bundle exec rake codebase_index:extract
```

---

### How long does extraction take?

A mid-size Rails app (50-100 models, typical controller and service layer) takes 10-30 seconds for a full extraction. Larger apps (200+ models) may take 1-2 minutes. Framework source extraction (Rails, gem internals) adds overhead and can be disabled with `config.include_framework_sources = false` if you don't need it. Incremental extraction for changed files is much faster — typically under 5 seconds.

---

## MCP Servers

### What's the difference between the Index Server and the Console Server?

The Index Server reads pre-extracted JSON from disk and does not require Rails. It provides 27 tools for querying extracted codebase structure, dependency graphs, semantic search, and temporal snapshots. The Console Server connects to a live Rails application and provides 31 tools for querying real database records, running diagnostics, and monitoring job queues. Use the Index Server for structural/architectural questions; use the Console Server for live data and runtime diagnostics.

---

### Why do I only see 9 console tools instead of 31?

You're using the embedded console mode (launched via `rake codebase_index:console` or `docker compose exec ... rake codebase_index:console`). Embedded mode intentionally exposes only the 9 Tier 1 read-only tools (count, sample, find, pluck, aggregate, association_count, schema, recent, status). To access all 31 tools across all 4 tiers, use the bridge architecture. See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) Option D for bridge setup.

---

### Is the Console Server safe to use?

The Console Server implements multiple safety layers. Every query runs inside a database transaction that is always rolled back, so writes are silently discarded. `SqlValidator` rejects DML and DDL at the string level before any database interaction. Model names are validated against `ActiveRecord::Base.descendants` to prevent arbitrary class instantiation. Tier 4 tools (eval, raw SQL) require explicit human confirmation. The Console Server is designed for development environments — treat it accordingly and avoid exposing it publicly.

---

### How do I get access to all 31 console tools?

Switch from the embedded mode (Tier 1 only) to the bridge architecture (all 4 tiers). The bridge runs `codebase-console-mcp` on the host and connects to a bridge process inside the Rails environment.

1. Create `~/.codebase_index/console.yml`:

```yaml
connection:
  mode: docker
  service: app
  compose_file: docker-compose.yml
```

2. Update `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "codebase-console-mcp"
    }
  }
}
```

See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full bridge setup guide.

---

## Docker

### Does extraction run inside or outside the container?

Extraction runs **inside** the container — it requires Rails to be booted. The Index Server runs **outside** the container on the host — it only reads static JSON files. The Console Server connects to a process inside the container through `docker exec -i`. This split architecture means you only need Docker for operations that require Rails.

```
HOST                           CONTAINER
─────────────────              ──────────────────
Index Server (reads JSON) ◀── volume mount ─── rake extract (writes JSON)
codebase-console-mcp      ──── docker exec ──▶  rake console (queries Rails)
```

See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker architecture guide.

---

### Why do I get a "No manifest.json" error when I know extraction succeeded?

The Index Server is looking at the wrong path — specifically the container-internal path rather than the host-side path. The Index Server runs on the host and reads from the volume-mounted output directory.

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]    ✓ host path
    }
  }
}
```

Do not use `/app/tmp/codebase_index` (the container path) — the host process cannot access it. Verify with `ls ./tmp/codebase_index/manifest.json` on the host.

---

### How do I configure the Console Server with Docker?

For the embedded mode (9 Tier 1 tools), point the MCP client at `docker compose exec -i`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-i", "app",
               "bundle", "exec", "rake", "codebase_index:console"]
    }
  }
}
```

The `-i` flag is required to keep stdin attached for MCP protocol communication. For all 31 tools, use the bridge architecture instead. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for both configurations with complete examples.

---

## Storage and Embeddings

### What storage backends does CodebaseIndex support?

CodebaseIndex supports three vector storage backends and two metadata backends:

| Backend | Type | Use case |
|---------|------|----------|
| `in_memory` | Vector + Metadata | Local dev, no persistence needed |
| `sqlite` | Metadata | Persistent metadata, simple setup |
| `pgvector` | Vector | PostgreSQL apps wanting unified storage |
| `qdrant` | Vector | Production-scale semantic search |

All backends work with both MySQL and PostgreSQL application databases. pgvector requires PostgreSQL for the vector store, but your application database can still be MySQL. See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

### What embedding providers does CodebaseIndex support?

Two embedding providers are supported:

- **OpenAI** — `text-embedding-3-small` (1536 dimensions, default) or `text-embedding-3-large`. Requires an `OPENAI_API_KEY`. Billed per token.
- **Ollama** — Any locally installed model (e.g., `nomic-embed-text`, `mxbai-embed-large`). Runs locally, no API key or cost. Requires Ollama to be running at `localhost:11434`.

```ruby
# OpenAI
config.embedding_provider = :openai
config.embedding_model = 'text-embedding-3-small'
config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }

# Ollama
config.embedding_provider = :ollama
config.embedding_model = 'nomic-embed-text'
```

---

### What are the storage presets?

Presets configure storage and embedding together with a single call:

```ruby
# No external services — in-memory vectors, SQLite metadata, Ollama embeddings
CodebaseIndex.configure_with_preset(:local)

# PostgreSQL + OpenAI — pgvector vectors, SQLite metadata, OpenAI embeddings
CodebaseIndex.configure_with_preset(:postgresql)

# Production scale — Qdrant vectors, SQLite metadata, OpenAI embeddings
CodebaseIndex.configure_with_preset(:production)
```

Presets can be overridden with a block:

```ruby
CodebaseIndex.configure_with_preset(:local) do |config|
  config.max_context_tokens = 16000
  config.embedding_model = 'mxbai-embed-large'
end
```

Start with `:local` for zero-dependency development and upgrade to `:postgresql` or `:production` when you need persistence or scale. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for what each preset configures.

---

### What happens if I change my embedding model after indexing?

Switching embedding models requires a full re-index. The new model produces vectors with different dimensions or a different embedding space, making old and new vectors incompatible for similarity search. `IndexValidator` detects dimension mismatches before queries fail and logs a warning. Re-index with:

```bash
bundle exec rake codebase_index:extract
bundle exec rake codebase_index:embed
```

---

## Retrieval

### How does semantic search work?

When you run `rake codebase_index:embed`, CodebaseIndex generates embedding vectors for each extracted unit and stores them in your configured vector store. The `codebase_retrieve` MCP tool accepts a natural-language query, embeds the query using the same provider, and finds the most semantically similar units using cosine similarity. Results are re-ranked using Reciprocal Rank Fusion (RRF) that combines semantic similarity with PageRank importance scores, then assembled into a formatted context block within your configured token budget.

---

### What is the `codebase_retrieve` tool for?

`codebase_retrieve` is the primary semantic search tool on the Index Server. It accepts a natural-language description of what you're looking for ("find where user email validation happens", "which services send Stripe API calls") and returns the most relevant extracted units as formatted context. It requires embedding configuration — without an embedding provider, the tool is available but returns no results. Token budget is controlled by `config.max_context_tokens` (default: 8000).

---

### How do I improve retrieval quality?

Several options for tuning retrieval:

- **Increase `max_context_tokens`** to include more units per query (at the cost of larger LLM context).
- **Lower `similarity_threshold`** (default 0.7) to include less similar results.
- **Enable framework sources** (`include_framework_sources: true`) if Rails internals are relevant to your queries.
- **Use the feedback tools** (`retrieval_rate`, `retrieval_report_gap`) to record quality ratings — `retrieval_suggest` analyzes feedback to recommend configuration changes.

---

## Temporal Snapshots

### What are temporal snapshots?

Temporal snapshots capture the full extraction state at a point in time, tied to a git SHA. They let you compare how the codebase has changed between snapshots — which units were added, modified, or deleted. Snapshots are opt-in and disabled by default.

Enable them in your initializer:

```ruby
config.enable_snapshots = true
```

Snapshots require database migrations 004 and 005 to be run first (`bundle exec rails db:migrate`). The `list_snapshots`, `snapshot_diff`, `unit_history`, and `snapshot_detail` MCP tools become available after enabling.

---

## Session Tracing

### What does the session tracer do?

The session tracer is middleware that records which Rails actions are invoked during a browser session, assembles the relevant extracted units, and makes that context available via the `session_trace` MCP tool. It is useful for giving an AI tool accurate context about what code path was active during a specific user interaction.

Session tracing is disabled by default. To enable it:

```ruby
config.session_tracer_enabled = true
config.session_store = CodebaseIndex::SessionTracer::FileStore.new(
  Rails.root.join('tmp/session_traces')
)
```

The `session_store` option is required — there is no default store.

---

## Operations

### How do I keep the index in sync in CI?

Use incremental extraction in your CI pipeline. Fetch enough git history for the incremental diff to work:

```yaml
# .github/workflows/index.yml
jobs:
  index:
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - name: Update index
        run: bundle exec rake codebase_index:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

For Docker-based CI:

```yaml
      - name: Update index
        run: docker compose exec -T app bundle exec rake codebase_index:incremental
```

---

### How do I check if the index is healthy?

Two rake tasks validate index integrity:

```bash
# Check integrity (no Rails required)
bundle exec rake codebase_index:validate

# Show unit counts and extraction stats
bundle exec rake codebase_index:stats
```

The `pipeline_status` MCP tool also reports the last extraction time, unit counts, and whether the index is stale relative to the current git HEAD.

---

### Can I add custom extractors?

Yes. Implement the extractor interface and register it:

```ruby
class MyExtractor
  def initialize; end

  def extract_all
    # Return Array<ExtractedUnit>
  end
end
```

Then add it to the extractors list:

```ruby
config.extractors += [:my_extractor]
```

The extractor must be accessible at boot time. See the existing extractors in `lib/codebase_index/extractors/` for the interface and conventions.

---

### How do I exclude sensitive directories from extraction?

Use `config.extractors` to remove specific extractor types, or exclude directories from eager loading:

```ruby
# Exclude specific extractor types
config.extractors -= %i[factories test_mappings]

# Exclude a directory from eager loading (prevents that dir from being indexed)
# config/application.rb
config.eager_load_paths -= [Rails.root.join('app/internal')]
```

Use `console_redacted_columns` to redact sensitive column values from Console Server results without excluding extraction:

```ruby
config.console_redacted_columns = %w[password_digest api_key ssn token]
```

---

## Troubleshooting

For detailed problem-specific guidance, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Quick links:

- Extraction produces empty output → [Extraction Problems](TROUBLESHOOTING.md#extraction-produces-empty-or-incomplete-output)
- "No manifest.json" error → [MCP Server Problems](TROUBLESHOOTING.md#no-manifestjson-error-when-starting-the-index-server)
- Only 9 console tools visible → [MCP Server Problems](TROUBLESHOOTING.md#tier-2-4-console-tools-return-unsupported-in-embedded-mode)
- Docker path confusion → [Docker Problems](TROUBLESHOOTING.md#path-confusion-index-server-uses-container-path)
- Dimension mismatch on embeddings → [Embedding Problems](TROUBLESHOOTING.md#dimension-mismatch-error-when-querying-embeddings)
