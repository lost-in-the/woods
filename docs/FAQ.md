# Frequently Asked Questions

---

## General

### Does Woods work without Rails?

No — Woods requires a booted Rails environment for extraction. It uses runtime introspection APIs (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) that only exist inside a running Rails application. Static analysis of source files alone cannot produce the accurate, inlined output that Woods generates. The MCP Index Server does *not* require Rails — it reads pre-extracted JSON from disk — but the extraction step itself always does.

---

### What Rails versions does Woods support?

Woods supports **Rails 6.0 and newer**, on **Ruby 3.0 through 4.0**. CI runs an end-to-end extraction against Rails 6.0, 6.1, 7.0, 7.1, 7.2, and 8.0 (see the version matrix in [CONTRIBUTING.md](../CONTRIBUTING.md)). The gem declares `railties >= 6.0`; the only 6.1-introduced APIs it touches (`connection_db_config`, `has_many_inversing`) are `respond_to?`-guarded and degrade cleanly on 6.0.

---

### Does Woods work with MySQL?

Yes — MySQL, PostgreSQL, and SQLite are all supported equally as application databases. Woods extraction uses ActiveRecord's database-agnostic reflection APIs and never issues raw SQL during extraction. The only backend-specific requirement is pgvector, which is PostgreSQL-only and optional. All other storage backends (SQLite metadata store, Qdrant, in-memory) work identically with MySQL and PostgreSQL. See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

### How large a codebase can Woods handle?

Woods has been tested on applications with 200+ models and 500+ extractable units. Extraction time scales roughly linearly with codebase size — a mid-size app (50-100 models) takes 10-30 seconds. Very large applications benefit from disabling `include_framework_sources` and using incremental mode for subsequent runs.

---

### Does extraction modify my database?

No. Extraction is entirely read-only. It uses ActiveRecord reflection APIs (`columns`, `reflect_on_all_associations`, `_validators`, etc.) rather than running queries against application data. No records are created, modified, or deleted during extraction.

---

### Can I run Woods in production?

Extraction itself is designed for development and CI — it requires a fully booted Rails environment and takes 10-30 seconds. The MCP Index Server is read-only and can safely run in any environment as long as the HTTP transport is properly secured (bearer token required for non-loopback, origin allow-list via `OriginGuard`, TLS via reverse proxy — see [MCP_HTTP_TRANSPORT.md](MCP_HTTP_TRANSPORT.md)). The Console Server should stay disabled in production regardless of its safety layers. The common production pattern is to extract in CI and publish the JSON output as a build artifact, then run the Index Server against the artifact.

---

## Setup

### How do I install Woods?

Add the gem to your Gemfile and run the install generator:

```ruby
# Gemfile
group :development do
  gem 'woods'
end
```

```bash
bundle install
bundle exec rails generate woods:install
```

The generator creates `config/initializers/woods.rb` with default configuration. For Docker projects, run these commands through `docker compose exec app`. See [GETTING_STARTED.md](GETTING_STARTED.md) for the full setup walkthrough.

---

### What is the minimum configuration?

The only required option is `output_dir`, which has a sensible default:

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')  # default
end
```

With just this, you can run `rake woods:extract` and get full extraction output. Embedding and vector storage require additional configuration — see [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).

---

### How do I set up the MCP server for Claude Code?

Use the `woods-mcp-start` wrapper, which validates the index and restarts on failure:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["/path/to/your-rails-app/tmp/woods"]
    }
  }
}
```

Add this to `.mcp.json` in your Rails app root (for project-scoped config) or to `claude_desktop_config.json` (for global config). Run `rake woods:extract` first to generate the index. See [MCP_SERVERS.md](MCP_SERVERS.md) for the full setup guide.

---

### How do I set up the MCP server for Cursor?

Use `woods-mcp` (without the `-start` wrapper, which is Claude Code-specific):

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp",
      "args": ["/path/to/your-rails-app/tmp/woods"]
    }
  }
}
```

Add this to `.cursor/mcp.json` in your project. See [MCP_SERVERS.md](MCP_SERVERS.md) for details.

---

### How do I set up the MCP server for Windsurf?

The setup is the same as Cursor — use `woods-mcp` (not the `-start` wrapper):

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp",
      "args": ["/path/to/your-rails-app/tmp/woods"]
    }
  }
}
```

Add this to your Windsurf MCP configuration file. The Index Server is transport-agnostic and works with any MCP-compliant client.

---

## Extraction

### What does Woods extract?

Woods extracts 34 types of units from a Rails application. The default extraction set includes models (with inlined concerns and schema), controllers, services, view components, jobs, mailers, GraphQL types/mutations/queries, serializers, managers, policies, validators, and Rails framework source. Additional extractors are available for state machines, events, decorators, database views, rake tasks, Action Cable channels, and more. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for the full extractor list.

---

### Why does Woods inline concerns?

When a model includes a concern, the behavior defined in that concern is part of the model's effective API — callbacks fire, validations run, scopes are available. A tool that reports only what's in `app/models/user.rb` misses everything defined in included concerns. Woods inlines concern source directly into each unit's `source_code` field so the full behavioral picture is in one place. This is the key differentiator from file-level tools.

---

### How do I update the index after code changes?

Use incremental mode, which re-extracts only files that have changed since the last run:

```bash
bundle exec rake woods:incremental

# Docker:
docker compose exec app bundle exec rake woods:incremental
```

Incremental mode is ideal for CI pipelines and local development workflows. It is typically 5-10× faster than a full extraction. Note that some unit types (routes, middleware, engines) require full extraction to update — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for details.

---

### How do I add semantic search with embeddings?

Configure an embedding provider, then run the embed task:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
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
bundle exec rake woods:embed
```

After embedding, the `codebase_retrieve` MCP tool supports natural-language queries ranked by semantic similarity. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for vector storage options.

---

### Why do some extractor types require full extraction?

Unit types that don't map to individual files — routes, middleware, engines, scheduled jobs, state machines, events, and factories — are extracted by introspecting the entire application at once rather than a single file. There's no way to incrementally update them by watching one file change. When any of these types change, run a full extraction:

```bash
bundle exec rake woods:extract
```

---

### How long does extraction take?

A mid-size Rails app (50-100 models, typical controller and service layer) takes 10-30 seconds for a full extraction. Larger apps (200+ models) may take 1-2 minutes. Framework source extraction (Rails, gem internals) adds overhead and can be disabled with `config.include_framework_sources = false` if you don't need it. Incremental extraction for changed files is much faster — typically under 5 seconds.

---

## MCP Servers

### What's the difference between the Index Server and the Console Server?

The Index Server reads pre-extracted JSON from disk and does not require Rails.
The Console Server connects to a live Rails application and registers 9
read-only model/schema tools by default, with `console_sql` and `console_query`
available through explicit read-tool configuration.

---

### Why do I only see 9 console tools?

That is the default supported surface: count, sample, find, pluck, aggregate,
association_count, schema, recent, and status. Enable
`console_embedded_read_tools` to register SQL and query as well. The remaining
schemas are inventory only.

---

### Is the Console Server safe to use?

The executable tools enforce the feature gate, blocked-table checks,
credential scanning, configured column/EAV redaction, and rolled-back
transactions. `console_sql` also runs through `SqlValidator`. These controls
are defense in depth, not a primary authorization boundary.

---

### How do I get access to SQL and structured query tools?

Set `config.console_embedded_read_tools = true` in `Woods.configure`, or pass
`embedded_read_tools: true` when mounting the Rack middleware. Tier 2, Tier 3,
and `console_eval` are not registered in a supported mode.

See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for setup details.

---

### Why do my parallel tool calls all fail when only one has a bad argument?

This is an MCP client behavior, not a server bug. Some clients batch parallel tool calls into a single protocol request. If one call in the batch fails (e.g., a typo in an identifier), the transport layer may reject the entire response. There is no server-side fix — the workaround is to validate arguments first (use `search` to confirm identifiers exist) or send calls sequentially when any call is unreliable. See the [Troubleshooting guide](TROUBLESHOOTING.md#parallel-tool-calls-fail-together-sibling-call-failures) for details.

---

## Docker

### Does extraction run inside or outside the container?

Extraction runs **inside** the container — it requires Rails to be booted. The Index Server runs **outside** the container on the host — it only reads static JSON files. The Console Server connects to a process inside the container through `docker exec -i`. This split architecture means you only need Docker for operations that require Rails.

```
HOST                           CONTAINER
─────────────────              ──────────────────
Index Server (reads JSON) ◀── volume mount ─── rake extract (writes JSON)
woods-console-mcp      ──── docker exec ──▶  rake console (queries Rails)
```

See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker architecture guide.

---

### Why do I get a "No manifest.json" error when I know extraction succeeded?

The Index Server is looking at the wrong path — specifically the container-internal path rather than the host-side path. The Index Server runs on the host and reads from the volume-mounted output directory.

```jsonc
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]    // host path (NOT the container /app/tmp/woods)
    }
  }
}
```

Do not use `/app/tmp/woods` (the container path) — the host process cannot access it. Verify with `ls ./tmp/woods/manifest.json` on the host.

---

### How do I configure the Console Server with Docker?

For the embedded mode (9 Tier 1 tools), point the MCP client at `docker compose exec -i`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-i", "app",
               "bundle", "exec", "rake", "woods:console"]
    }
  }
}
```

The `-i` flag is required to keep stdin attached for MCP protocol
communication. Enable `console_embedded_read_tools` when SQL/query should also
be registered. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for complete examples.

---

## Storage and Embeddings

### What storage backends does Woods support?

Woods supports three vector storage backends and two metadata backends:

| Backend | Type | Use case |
|---------|------|----------|
| `in_memory` | Vector + Metadata | Local dev, no persistence needed |
| `sqlite` | Metadata | Persistent metadata, simple setup |
| `pgvector` | Vector | PostgreSQL apps wanting unified storage |
| `qdrant` | Vector | Production-scale semantic search |

All backends work with both MySQL and PostgreSQL application databases. pgvector requires PostgreSQL for the vector store, but your application database can still be MySQL. See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

### What embedding providers does Woods support?

Two embedding providers are supported:

- **OpenAI** — `text-embedding-3-small` (1536 dimensions, default) or `text-embedding-3-large`. Requires an `OPENAI_API_KEY`. Billed per token.
- **Ollama** — Any locally installed model (e.g., `nomic-embed-text`, `bge-m3`, `mxbai-embed-large`). Runs locally, no API key or cost. Requires Ollama to be running at `localhost:11434`.

```ruby
# OpenAI
config.embedding_provider = :openai
config.embedding_options = {
  api_key: ENV['OPENAI_API_KEY'],
  model: 'text-embedding-3-small'
}

# Ollama — default (2048-token context)
config.embedding_provider = :ollama
config.embedding_options = { model: 'nomic-embed-text' }

# Ollama — bge-m3 (8192-token context, fewer chunks per unit)
config.embedding_provider = :ollama
config.embedding_options = { model: 'bge-m3' }
```

See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the Ollama model comparison and the procedure for adding a new model.

---

### What are the storage presets?

Presets configure storage and embedding together with a single call:

```ruby
# No external services — in-memory vectors, SQLite metadata, Ollama embeddings
Woods.configure_with_preset(:local)

# PostgreSQL + OpenAI — pgvector vectors, SQLite metadata, OpenAI embeddings
Woods.configure_with_preset(:postgresql)

# Production scale — Qdrant vectors, SQLite metadata, OpenAI embeddings
Woods.configure_with_preset(:production)
```

Presets can be overridden with a block:

```ruby
Woods.configure_with_preset(:local) do |config|
  config.max_context_tokens = 16000
  config.embedding_model = 'mxbai-embed-large'
end
```

Start with `:local` for zero-dependency development and upgrade to `:postgresql` or `:production` when you need persistence or scale. See [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) for what each preset configures.

---

### What happens if I change my embedding model after indexing?

Switching embedding models requires a full re-index. The new model produces vectors with different dimensions or a different embedding space, making old and new vectors incompatible for similarity search. Woods detects a dimension change and raises `Woods::MCP::DimensionMismatch` — `rake woods:embed` refuses before embedding anything, and the MCP server refuses at boot — so you get an actionable error rather than silently wrong results. Re-index with:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

---

## Retrieval

### How does semantic search work?

When you run `rake woods:embed`, Woods generates embedding vectors for each extracted unit and stores them in your configured vector store. The `codebase_retrieve` MCP tool accepts a natural-language query, embeds the query using the same provider, and finds the most semantically similar units using cosine similarity. Results are re-ranked using Reciprocal Rank Fusion (RRF) that combines semantic similarity with PageRank importance scores, then assembled into a formatted context block within your configured token budget.

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
config.session_store = Woods::SessionTracer::FileStore.new(
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
        run: bundle exec rake woods:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

For Docker-based CI:

```yaml
      - name: Update index
        run: docker compose exec -T app bundle exec rake woods:incremental
```

---

### How do I check if the index is healthy?

Two rake tasks validate index integrity:

```bash
# Check integrity (no Rails required)
bundle exec rake woods:validate

# Show unit counts and extraction stats
bundle exec rake woods:stats
```

The `pipeline_status` MCP tool reports the last extraction time, unit counts, and whether the index is stale relative to the current git HEAD. The `woods_status` tool (Index Server) reports a single-call health snapshot covering extraction freshness, console-bridge reachability, embedding/Notion/session-tracer configuration state, and index version — useful for agents cold-connecting to a server.

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

The extractor must be accessible at boot time. See the existing extractors in `lib/woods/extractors/` for the interface and conventions.

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
- Only 9 console tools visible → [MCP Server Problems](TROUBLESHOOTING.md#a-console-inventory-tool-is-not-listed)
- Docker path confusion → [Docker Problems](TROUBLESHOOTING.md#path-confusion-index-server-uses-container-path)
- Dimension mismatch on embeddings → [Embedding Problems](TROUBLESHOOTING.md#dimension-mismatch-error-when-querying-embeddings)
