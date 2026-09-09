# Frequently Asked Questions

---

## Question index

**General**
- [Does Woods work without Rails?](#does-woods-work-without-rails)
- [What Rails versions does Woods support?](#what-rails-versions-does-woods-support)
- [Does Woods work with MySQL?](#does-woods-work-with-mysql)
- [How large a codebase can Woods handle?](#how-large-a-codebase-can-woods-handle)
- [Does extraction modify my database?](#does-extraction-modify-my-database)
- [Can I run Woods in production?](#can-i-run-woods-in-production)
**Setup**
- [How do I install Woods?](#how-do-i-install-woods)
- [What is the minimum configuration?](#what-is-the-minimum-configuration)
- [How do I set up Woods in my MCP client?](#how-do-i-set-up-woods-in-my-mcp-client)
**Extraction**
- [What does Woods extract?](#what-does-woods-extract)
- [Why does Woods inline concerns?](#why-does-woods-inline-concerns)
- [How do I update the index after code changes?](#how-do-i-update-the-index-after-code-changes)
- [How do I add semantic search with embeddings?](#how-do-i-add-semantic-search-with-embeddings)
- [Why do some extractor types re-run wholesale on incremental runs?](#why-do-some-extractor-types-re-run-wholesale-on-incremental-runs)
- [How long does extraction take?](#how-long-does-extraction-take)
**MCP Servers**
- [What's the difference between the Index Server and the Console Server?](#whats-the-difference-between-the-index-server-and-the-console-server)
- [Why do I only see 9 console tools?](#why-do-i-only-see-9-console-tools)
- [Is the Console Server safe to use?](#is-the-console-server-safe-to-use)
- [How do I get access to SQL and structured query tools?](#how-do-i-get-access-to-sql-and-structured-query-tools)
- [Why do my parallel tool calls all fail when only one has a bad argument?](#why-do-my-parallel-tool-calls-all-fail-when-only-one-has-a-bad-argument)
**Docker**
- [Does extraction run inside or outside the container?](#does-extraction-run-inside-or-outside-the-container)
- [Why does the Index Server say no published manifest exists after extraction?](#why-does-the-index-server-say-no-published-manifest-exists-after-extraction)
- [How do I configure the Console Server with Docker?](#how-do-i-configure-the-console-server-with-docker)
**Storage and Embeddings**
- [What storage backends does Woods support?](#what-storage-backends-does-woods-support)
- [What embedding providers does Woods support?](#what-embedding-providers-does-woods-support)
- [What are the storage presets?](#what-are-the-storage-presets)
- [What happens if I change my embedding model after indexing?](#what-happens-if-i-change-my-embedding-model-after-indexing)
**Retrieval**
- [How does semantic search work?](#how-does-semantic-search-work)
- [What is the `codebase_retrieve` tool for?](#what-is-the-codebase_retrieve-tool-for)
- [How do I improve retrieval quality?](#how-do-i-improve-retrieval-quality)
**Temporal Snapshots**
- [What are temporal snapshots?](#what-are-temporal-snapshots)
**Session Tracing**
- [What does the session tracer do?](#what-does-the-session-tracer-do)
**Operations**
- [How do I keep the index in sync in CI?](#how-do-i-keep-the-index-in-sync-in-ci)
- [How do I check if the index is healthy?](#how-do-i-check-if-the-index-is-healthy)
- [Can I add custom extractors?](#can-i-add-custom-extractors)
- [How do I exclude sensitive directories from extraction?](#how-do-i-exclude-sensitive-directories-from-extraction)

## General

### Does Woods work without Rails?

No. Woods requires a booted Rails environment for extraction. It uses runtime introspection APIs (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) that only exist inside a running Rails application. Static analysis of source files alone cannot produce the accurate, inlined output that Woods generates. The MCP Index Server does *not* require Rails, it reads pre-extracted JSON from disk, but the extraction step itself always does.

---

### What Rails versions does Woods support?

Woods supports **Rails 6.0 and newer**, on **Ruby 3.0 through 4.0**. CI runs an end-to-end extraction against Rails 6.0, 6.1, 7.0, 7.1, 7.2, 8.0, and 8.1 (see the version matrix in [CONTRIBUTING.md](../CONTRIBUTING.md)). The gem declares `railties >= 6.0`; the only 6.1-introduced APIs it touches (`connection_db_config`, `has_many_inversing`) are `respond_to?`-guarded and degrade cleanly on 6.0.

---

### Does Woods work with MySQL?

Yes. MySQL, PostgreSQL, and SQLite are all supported equally as application databases. Woods extraction uses ActiveRecord's database-agnostic reflection APIs and never issues raw SQL during extraction. The only backend-specific requirement is pgvector, which is PostgreSQL-only and optional. All other storage backends (SQLite metadata store, Qdrant, in-memory) work identically with MySQL and PostgreSQL. See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

### How large a codebase can Woods handle?

Woods does not publish a supported size ceiling or a universal timing estimate. Extraction cost depends on application boot/eager-load time, enabled framework-source indexing, and codebase shape. Measure a full extraction in your application, then use incremental extraction or the watch daemon for ordinary changes.

---

### Does extraction modify my database?

No. Extraction is entirely read-only. It uses ActiveRecord reflection APIs (`columns`, `reflect_on_all_associations`, `_validators`, etc.) rather than running queries against application data. No records are created, modified, or deleted during extraction.

---

### Can I run Woods in production?

Prefer extraction in development or CI and publish the generated index as a controlled artifact. The Index Server is read-only but its index contains source and schema context; HTTP deployments still require authentication, origin controls, and TLS. Leave the live-data Console Server disabled in production unless a deliberate security review and access policy authorize it. See [MCP HTTP transport](MCP_HTTP_TRANSPORT.md) and [Console MCP setup](CONSOLE_MCP_SETUP.md).

---

## Setup

### How do I install Woods?

Add `gem "woods", "~> 2.0"` to your development group, install it, and run the install generator. Review the initializer. For a new default v2 install, remove the generated legacy application migration instead of running it; shipped v2 extraction and retrieval do not use those tables. Keep it only for a known older/custom integration. Then extract and validate. Follow [Getting started](GETTING_STARTED.md) for the canonical commands and expected result. If an agent is doing the work, use [Agent setup](AGENT_SETUP.md).

---

### What is the minimum configuration?

The generated defaults are enough for structural extraction to `tmp/woods/`. Embeddings are optional. See [Getting started](GETTING_STARTED.md) for the minimal path and [Configuration reference](CONFIGURATION_REFERENCE.md) for supported settings.

---

### How do I set up Woods in my MCP client?

Extract first, then configure a project-scoped stdio server using the application's bundle and an index path visible to the server process. Woods works with any model through a client that supports MCP stdio or Streamable HTTP. Use the verified examples in [MCP servers](MCP_SERVERS.md#configure-a-stdio-client), adapting them to the client's configuration location.

---

## Extraction

### What does Woods extract?

Woods runs **34 extractor classes** on every full extraction, there is no
opt-in/opt-out. Between them they produce 38 distinct unit types (some
extractors emit more than one type. GraphQL alone produces four, and
`RailsSourceExtractor` produces both `rails_source` and `gem_source`).
Coverage
includes models (with inlined concerns and schema), controllers, services,
view components, jobs, mailers, GraphQL types/mutations/queries, serializers,
managers, policies, validators, Rails framework source, state machines,
events, decorators, database views, rake tasks, Action Cable channels, and
more. See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for the full list.

---

### Why does Woods inline concerns?

When a model includes a concern, the behavior defined in that concern is part of the model's effective API, callbacks fire, validations run, scopes are available. A tool that reports only what's in `app/models/user.rb` misses everything defined in included concerns. Woods inlines concern source directly into each unit's `source_code` field so the full behavioral picture is in one place. This is the key differentiator from file-level tools.

---

### How do I update the index after code changes?

Use incremental mode, which re-extracts only files that have changed since the last run:

```bash
bundle exec rake woods:incremental

# Docker:
docker compose exec app bundle exec rake woods:incremental
```

Incremental mode is ideal for CI pipelines and local development workflows. It is typically 5-10× faster than a full extraction. Nine unit types, `route`, `middleware`, `engine`, `scheduled_job`, `state_machine`, `factory`, `event`, `database_view`, and `rails_source`, don't map to individual files, so incremental mode re-runs their extractor **wholesale** whenever the relevant trigger path changes (e.g. `config/routes.rb` for routes, `Gemfile.lock` for middleware/engines/rails_source; `rails_source` participates only when `include_framework_sources` is enabled). You never need to run a full extraction just because one of these changed, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for details.

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

### Why do some extractor types re-run wholesale on incremental runs?

Nine unit types, routes, middleware, engines, scheduled jobs, state machines, events, factories, database views, and Rails/gem sources, don't map to individual files. They're extracted by introspecting the entire application at once rather than one file at a time. Incremental mode handles this by re-running the whole extractor when a trigger path changes (`config/routes.rb`, `Gemfile.lock`, the relevant model/factory directories, and so on) instead of skipping the type; Rails/gem sources participate only when `include_framework_sources` is enabled. A full extraction is only needed if you suspect drift, not as routine maintenance:

```bash
bundle exec rake woods:extract
```

---

### How long does extraction take?

There is no reliable application-independent estimate. Rails boot/eager load, framework-source indexing, and codebase shape dominate the result. Time `woods:extract` in your own environment and use `woods:incremental` or `woods:watch` for ordinary changes.

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

This is an MCP client behavior, not a server bug. Some clients batch parallel tool calls into a single protocol request. If one call in the batch fails (e.g., a typo in an identifier), the transport layer may reject the entire response. There is no server-side fix, the workaround is to validate arguments first (use `search` to confirm identifiers exist) or send calls sequentially when any call is unreliable. See the [Troubleshooting guide](TROUBLESHOOTING.md#parallel-tool-calls-fail-together-sibling-call-failures) for details.

---

## Docker

### Does extraction run inside or outside the container?

Extraction runs **inside** the container because it requires Rails to be booted. By default, launch the Index Server through the same application container so it can use the installed bundle and container index path; it still reads only static files and does not boot Rails. A host-side Index Server is optional when the host has the application bundle and can read the index volume. The Console Server connects to a booted Rails process inside the container.

```
HOST                           APPLICATION CONTAINER
─────────────────              ─────────────────────────
MCP client ── compose exec ──▶ woods-mcp (reads JSON)
Rails commands ──────────────▶ rake extract (writes JSON)
Console client ──────────────▶ rake console (queries Rails)
```

See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker architecture guide.

---

### Why does the Index Server say no published manifest exists after extraction?

The server is usually running in a different filesystem context from the path you supplied. A Docker-launched server needs the container path; an optional host-launched server needs a host-visible path and the application bundle installed on the host.

```jsonc
{
  "mcpServers": {
    "codebase": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

Verify the active v2 generation with `docker compose exec app bundle exec rake woods:validate` and `woods:stats`. Do not require a root `manifest.json`: Woods 2 normally publishes root `generation.json`, which points to the active payload manifest.

---

### How do I configure the Console Server with Docker?

First set `config.console_mcp_enabled = true` in the Rails initializer after reviewing the live-data trust boundary. Stdio does not send a bearer token, but production Rails boot still requires a configured `console_mcp_token` of at least 32 characters whenever Console is enabled. Supply `WOODS_CONSOLE_MCP_TOKEN` through the container's secret mechanism; see [Console MCP setup](CONSOLE_MCP_SETUP.md#option-a-stdio-via-rake-recommended). Then, for the embedded mode (9 Tier 1 tools), point the MCP client at `docker compose exec -T` so Compose does not allocate a pseudo-TTY:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app",
               "bundle", "exec", "rake", "woods:console"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

Compose attaches stdin by default; `-T` disables the pseudo-TTY that would corrupt MCP framing. Plain `docker exec` uses `-i` instead. Enable `console_embedded_read_tools` when SQL/query should also be registered. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for complete examples.

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

Three embedding providers are supported:

- **OpenAI**: `text-embedding-3-small` (1536 dimensions, default) or `text-embedding-3-large`. Requires an `OPENAI_API_KEY`. Billed per token.
- **Ollama**: Any locally installed model (e.g., `nomic-embed-text`, `bge-m3`, `mxbai-embed-large`). Runs locally, no API key or cost. Requires Ollama to be running at `localhost:11434`.
- **Fake** (`:fake`): deterministic vectors with no network or service, for exercising the embed pipeline in tests and smoke checks. See [Configuration reference](CONFIGURATION_REFERENCE.md).

A provider object responding to `#embed` and `#embed_batch` can also be injected directly.

```ruby
# OpenAI
config.embedding_provider = :openai
config.embedding_options = {
  api_key: ENV['OPENAI_API_KEY'],
  model: 'text-embedding-3-small'
}

# Ollama: default (2048-token context)
config.embedding_provider = :ollama
config.embedding_options = { model: 'nomic-embed-text' }

# Ollama: bge-m3 (8192-token context, fewer chunks per unit)
config.embedding_provider = :ollama
config.embedding_options = { model: 'bge-m3' }
```

See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the Ollama model comparison and the procedure for adding a new model.

---

### What are the storage presets?

Presets configure storage and embedding together with a single call:

```ruby
# Local services: in-memory vectors, SQLite metadata, Ollama embeddings
# Requires the sqlite3 gem, a running Ollama service, and the pulled model.
Woods.configure_with_preset(:local)

# Shared filesystem: in-memory stores persisted under output_dir.
# Requires a running Ollama service and shared output_dir; no sqlite3 gem.
Woods.configure_with_preset(:shared_filesystem)

# PostgreSQL + OpenAI: pgvector vectors, SQLite metadata, OpenAI embeddings
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end

# Production scale: Qdrant vectors, SQLite metadata, OpenAI embeddings
Woods.configure_with_preset(:production) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # only when QDRANT_URL is deliberately private
  }
end
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

Switching embedding models requires a full re-index. The new model produces vectors with different dimensions or a different embedding space, making old and new vectors incompatible for similarity search. Woods detects a dimension change and raises `Woods::MCP::DimensionMismatch`, `rake woods:embed` refuses before embedding anything, and the MCP server refuses at boot, so you get an actionable error rather than silently wrong results. Re-index with:

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

`codebase_retrieve` is the primary semantic search tool on the Index Server. It accepts a natural-language description of what you're looking for ("find where user email validation happens", "which services send Stripe API calls") and returns the most relevant extracted units as formatted context. It requires embedding configuration, without an embedding provider the tool responds with an error (`isError`, code `:not_configured`) and a remediation hint covering provider setup and the `search` tool for pattern-based matching in the meantime. Token budget is controlled by `config.max_context_tokens` (default: 8000).

---

### How do I improve retrieval quality?

Several options for tuning retrieval:

- **Increase `max_context_tokens`** to include more units per query (at the cost of larger LLM context).
- **Lower `similarity_threshold`** (default 0.7) to include less similar results.
- **Enable framework sources** (`include_framework_sources: true`) if Rails internals are relevant to your queries.
- **Use retrieval feedback only in a custom embedded server** that wires a feedback store. The normal packaged executable does not register feedback tools.

---

## Temporal Snapshots

### What are temporal snapshots?

Temporal snapshots capture the full extraction state at a point in time, tied to a git SHA. They let you compare how the codebase has changed between snapshots, which units were added, modified, or deleted. Snapshots are opt-in and disabled by default.

Enable them in your initializer:

```ruby
config.enable_snapshots = true
```

Snapshots prefer their own SQLite database (`woods.sqlite3` in the output directory), separate from your Rails app's database. Extraction falls back to JSON files when the `sqlite3` gem is unavailable; other SQLite open/migration failures are reported and do not capture a snapshot. `Woods::Db::Migrator` runs the internal SQLite migrations automatically during extraction and MCP boot; `bundle exec rails db:migrate` does not touch this store and no manual migration step is needed. The packaged MCP server discovers an existing `woods.sqlite3` automatically. When extraction used the JSON fallback, set `WOODS_SNAPSHOTS=true` on the server so it wires `list_snapshots`, `snapshot_diff`, `unit_history`, and `snapshot_detail`.

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

The `session_store` option is required, there is no default store.

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

Two rake tasks validate index integrity. Both are `:environment` tasks, they boot Rails, same as extraction:

```bash
bundle exec rake woods:validate

# Show unit counts and extraction stats
bundle exec rake woods:stats
```

The packaged Index Server's `woods_status` tool reports a single-call health snapshot covering generation freshness, counts, retrieval readiness, and configured optional capabilities. `pipeline_status` requires an operator collaborator that the packaged executable does not wire.

---

### Can I add custom extractors?

Not today. `Woods::Extractor::EXTRACTORS` is a frozen constant listing the 34
built-in extractor classes, and nothing in the extraction path consults
`config.extractors` to add to that list. `config.extractors` exists only for
forward compatibility, setting it to anything other than the default warns
and has no effect on which extractors run. If you need a custom extractor
today, the extractor interface (`initialize` + `extract_all` returning
`Array<ExtractedUnit>`) is stable and documented in
[EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md), but wiring one in requires
patching `EXTRACTORS` directly (a gem fork or monkeypatch), not a config call.

---

### How do I exclude sensitive directories from extraction?

`config.extractors` cannot remove an extractor from the run, see above.
Exclude a directory from eager loading instead:

```ruby
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
