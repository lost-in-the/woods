# Configuration Reference

All configuration is done via the `Woods.configure` block, typically in `config/initializers/woods.rb`.

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
  config.max_context_tokens = 8000
  # ...
end
```

## Common Configuration Patterns

### CI-Only Extraction (Subset of Extractors)

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')

  # In CI, only extract models and controllers for faster builds
  config.extractors = %i[models controllers services] if ENV['CI']
end
```

### Docker Extraction with Environment-Based Paths

```ruby
Woods.configure do |config|
  # Inside Docker, /app is the Rails root
  config.output_dir = ENV.fetch('WOODS_OUTPUT_DIR', Rails.root.join('tmp/woods'))
end
```

### Environment-Conditional Embedding Provider

```ruby
Woods.configure do |config|
  # Use OpenAI in production/CI where the API key is set,
  # fall back to Ollama for local development (free, no API key needed)
  if ENV['OPENAI_API_KEY']
    config.embedding_provider = :openai
    config.embedding_model = 'text-embedding-3-small'
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

---

## Core Options

Columns:

- **User-settable**: a direct `Woods.configure { |c| c.<option> = ... }` writes the value verbatim.
- **Preset-derived**: set by `Builder.preset_config(:local | :postgresql | :production)` as a group. You can override any preset value afterwards in the `configure` block — later writes win.
- **Computed**: derived from other options at read time (or at `build_*` time by `Woods::Builder`). Writing directly has no effect; change the inputs instead.

| Option | Type | Default | Role | Description |
|--------|------|---------|------|-------------|
| `output_dir` | Pathname/String | `Rails.root.join('tmp/woods')` | user-settable | Directory where extracted data is written |
| `extractors` | Array&lt;Symbol&gt; | `[:models, :controllers, :services, ...]` | user-settable | List of enabled extractors (see [Extractors](#extractors) below) |
| `pretty_json` | Boolean | `true` | user-settable | Format extracted JSON with indentation |
| `max_context_tokens` | Integer | `8000` | user-settable | Maximum tokens for retrieval context windows |
| `similarity_threshold` | Float | `0.7` | user-settable | Minimum similarity score (0.0-1.0) for retrieval results |
| `context_format` | Symbol | `:markdown` | user-settable | Output format for retrieval: `:claude`, `:markdown`, `:plain`, `:json` |
| `include_framework_sources` | Boolean | `true` | user-settable | Extract Rails and gem source code |
| `concurrent_extraction` | Boolean | `false` | user-settable | Enable parallel extraction (experimental) |
| `vector_store` / `metadata_store` / `graph_store` / `embedding_provider` | Symbol | — | preset-derived | Adapter types. Set by presets; override individually to mix stacks. |
| chars-per-token ratio (used by ContextAssembler, TextPreparer, Builder, cost_model) | Float | `4.0` (OpenAI) / `1.5` (Ollama) | computed | Derived from the active embedding provider via `Woods::TokenUtils.chars_per_token_for(...)`. Not directly user-settable; change `embedding_provider` to change the ratio. |

## Embedding Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `embedding_provider` | Symbol | — | Embedding backend: `:openai` or `:ollama` |
| `embedding_model` | String | `'text-embedding-3-small'` | Model name for the embedding provider |
| `embedding_options` | Hash | `nil` | Provider-specific options (see below) |

### OpenAI Embeddings

```ruby
config.embedding_provider = :openai
config.embedding_model = 'text-embedding-3-small'
config.embedding_options = {
  api_key: ENV['OPENAI_API_KEY'],
  dimensions: 1536
}
```

### Ollama Embeddings

```ruby
config.embedding_provider = :ollama
config.embedding_options = {
  model: 'nomic-embed-text',
  host: 'http://localhost:11434'
  # num_ctx: 2048  # Optional override — see below
}
```

The provider reads `model:`, `host:`, and `num_ctx:` from `embedding_options`. `num_ctx` is auto-selected from a per-model registry (`nomic-embed-text` → 2048, `bge-m3` → 8192, `snowflake-arctic-embed2` → 8192, `mxbai-embed-large` → 512, `all-minilm` → 256). Unknown models fall back to 2048, matching Ollama's conservative embedding default. Set `num_ctx:` explicitly only when running a model with a known-larger native context that isn't in the registry yet.

**Why `num_ctx` is capped at the native context.** Ollama has an open regression ([ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)) where `options.num_ctx` does not lift the effective ceiling on `/api/embed` for models whose native context is smaller than the override. Woods advertises the native ceiling so the chunker sizes inputs to what Ollama will actually accept.

**Optional exact tokenization.** Install the [`tokenizers`](https://github.com/ankane/tokenizers-ruby) gem alongside Woods to get BERT WordPiece token counting. Without it, Woods falls back to a chars/token ratio, which under-counts dense Ruby source (CamelCase constants, callback DSLs) and can silently over-pack chunks. Recommended for any Ollama setup.

```ruby
# Gemfile (optional)
gem 'tokenizers', '~> 0.5'
```

See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the full model comparison and the procedure for adding a new model to the registry.

## Storage Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vector_store` | Symbol | — | Vector backend: `:in_memory`, `:pgvector`, `:qdrant` |
| `vector_store_options` | Hash | `nil` | Backend-specific connection options |
| `metadata_store` | Symbol | — | Metadata backend: `:in_memory`, `:sqlite` |
| `metadata_store_options` | Hash | `nil` | Backend-specific options |
| `graph_store` | Symbol | — | Graph backend: `:in_memory` |

### pgvector (PostgreSQL)

```ruby
config.vector_store = :pgvector
config.vector_store_options = {
  connection: ActiveRecord::Base.connection,
  dimensions: 1536
}
```

Requires the pgvector extension. Run the generator to create migrations:

```bash
bundle exec rails generate woods:pgvector
bundle exec rails db:migrate
```

### Qdrant

```ruby
config.vector_store = :qdrant
config.vector_store_options = {
  url: 'http://localhost:6333',
  collection: 'woods',
  dimensions: 1536
}
```

### SQLite Metadata

```ruby
config.metadata_store = :sqlite
config.metadata_store_options = {
  database: Rails.root.join('tmp/woods/metadata.sqlite3').to_s
}
```

Requires the `sqlite3` gem in your host bundle. Rails apps backed by
MySQL or PostgreSQL won't have it by default — selecting `:sqlite`
without it raises `Woods::ConfigurationError` with install
instructions. For MySQL/Postgres-only hosts, use `:in_memory` (below)
unless cross-process metadata persistence matters.

### In-Memory Metadata

```ruby
config.metadata_store = :in_memory
```

Pure-Ruby hash-backed store. No external dependencies, no persistence
— vectors and metadata both live in the building process and die with
it. The `_index.json` manifest under `output_dir` is the durable
metadata for the index MCP server, so this is a reasonable default
for hosts that don't bundle `sqlite3`.

## Deployment Shapes

Woods supports three deployment shapes — pick the preset that matches yours.

| Shape | When | Preset |
|---|---|---|
| **Single-process** | Embed + query in one Ruby VM (dev console, tests, `rails runner` scripts). Simplest. | `:local` |
| **Shared filesystem** | Rake task runs `woods:embed`, separate `woods-mcp` server reads the dump. Common with MCP sidecars. | `:shared_filesystem` |
| **Distributed** | Vectors live in an external service (pgvector / Qdrant) queried by both the embed process and the MCP server. Highest durability, highest ops cost. | `:postgresql` or `:production` |

### Shape 2 setup (`:shared_filesystem`)

```ruby
Woods.configure_with_preset(:shared_filesystem) do |config|
  config.output_dir = Rails.root.join('tmp/woods')
  config.embedding_options = {
    model: 'nomic-embed-text',
    host:  ENV.fetch('WOODS_OLLAMA_URL', 'http://localhost:11434')
  }
end
```

The embed run writes `woods.json` + `dumps/<ISO8601>/vectors.bin` + `metadata.msgpack` under `output_dir`. The MCP server reads them at boot — no sqlite3 gem required, no pgvector/Qdrant service needed. Dump retention defaults to the last 3 (configurable via `config.dump_retention_count`).

Requirements:
- `output_dir` must be set and readable by both the embed process and the MCP server.
- The MCP server must know the same `output_dir` (pass via `woods-mcp <DIR>` or set `WOODS_DIR`).

## Presets

For quick setup, use named presets that configure storage + embedding together:

```ruby
# Local development — no external services needed (requires sqlite3 gem)
Woods.configure_with_preset(:local)
# → in_memory vectors, SQLite metadata, in_memory graph, Ollama embeddings

# Shared filesystem — rake embed → separate MCP server reads the dump.
# No sqlite3 gem needed; works on MySQL/Postgres-only hosts.
Woods.configure_with_preset(:shared_filesystem)
# → in_memory everything + Snapshotter-based persistence via output_dir

# PostgreSQL — requires pgvector extension and OpenAI API key
Woods.configure_with_preset(:postgresql)
# → pgvector vectors, SQLite metadata, in_memory graph, OpenAI embeddings

# Production — requires Qdrant server and OpenAI API key
Woods.configure_with_preset(:production)
# → Qdrant vectors, SQLite metadata, in_memory graph, OpenAI embeddings
```

Presets can be overridden:

```ruby
Woods.configure_with_preset(:local) do |config|
  config.max_context_tokens = 16000
  config.embedding_model = 'mxbai-embed-large'
end
```

## Pipeline Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `precompute_flows` | Boolean | `false` | Pre-compute per-action request flow maps during extraction |
| `extract_navigation_edges` | Boolean | `true` | Extract `link_to`, `redirect_to`, and `form_action` navigation edges from views and controllers |
| `enable_snapshots` | Boolean | `false` | Enable temporal snapshots (requires migrations 004+005) |

## Session Tracer Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `session_tracer_enabled` | Boolean | `false` | Enable session tracing middleware |
| `session_store` | Object | `nil` | Store backend: `FileStore`, `RedisStore`, or `SolidCacheStore` |
| `session_id_proc` | Proc | `nil` | Custom proc to extract session ID from requests |
| `session_exclude_paths` | Array&lt;String&gt; | `[]` | Path patterns to exclude from tracing |

```ruby
config.session_tracer_enabled = true
config.session_store = Woods::SessionTracer::FileStore.new(
  Rails.root.join('tmp/session_traces')
)
config.session_exclude_paths = ['/health', '/metrics', '/assets']
```

## Gem Indexing

Register additional gems to extract source from:

```ruby
config.add_gem 'devise', paths: ['lib/devise/models'], priority: :high
config.add_gem 'pundit', paths: ['lib/pundit'], priority: :medium
config.add_gem 'sidekiq', paths: ['lib/sidekiq/worker', 'lib/sidekiq/job'], priority: :high
```

Priority levels (`:low`, `:medium`, `:high`) affect retrieval ranking when framework source is relevant to a query.

## Extractors

The `extractors` config accepts an array of symbols. Default set:

```ruby
config.extractors = %i[
  models controllers services components view_components
  jobs mailers graphql serializers managers policies validators
  rails_source
]
```

Additional extractors available (not in default set):

| Symbol | Extractor | What it adds |
|--------|-----------|-------------|
| `:concerns` | ConcernExtractor | ActiveSupport::Concern modules |
| `:routes` | RouteExtractor | Rails routes (auto-included) |
| `:middleware` | MiddlewareExtractor | Rack middleware stack |
| `:i18n` | I18nExtractor | Locale translation files |
| `:pundit_policies` | PunditExtractor | Pundit authorization policies |
| `:configurations` | ConfigurationExtractor | Rails initializers + behavioral profile |
| `:engines` | EngineExtractor | Mounted Rails engines |
| `:view_templates` | ViewTemplateExtractor | ERB view templates |
| `:migrations` | MigrationExtractor | ActiveRecord migrations |
| `:action_cable_channels` | ActionCableExtractor | ActionCable channels |
| `:scheduled_jobs` | ScheduledJobExtractor | Recurring/scheduled jobs |
| `:rake_tasks` | RakeTaskExtractor | Rake task definitions |
| `:state_machines` | StateMachineExtractor | AASM/Statesman state machines |
| `:events` | EventExtractor | Event publish/subscribe patterns |
| `:decorators` | DecoratorExtractor | Decorators, presenters, form objects |
| `:database_views` | DatabaseViewExtractor | SQL views (Scenic) |
| `:caching` | CachingExtractor | Cache usage patterns |
| `:factories` | FactoryExtractor | FactoryBot factory definitions |
| `:test_mappings` | TestMappingExtractor | Test file → subject class mapping |
| `:poros` | PoroExtractor | Plain Ruby objects in app/models |
| `:libs` | LibExtractor | Ruby files in lib/ |

## Console MCP Options

These options configure the Console MCP server (live database queries via
MCP). See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full
deployment guide including defense layers.

| Key | Type | Default | Description |
|---|---|---|---|
| `console_mcp_enabled` | Boolean | `false` | Master switch. When `false`, the Railtie does not mount the Console MCP middleware. |
| `console_mcp_token` | String | `ENV['WOODS_CONSOLE_MCP_TOKEN']` or `nil` | Bearer token required on every HTTP request. **Required in production** — the Railtie raises `Woods::ConfigurationError` when `console_mcp_enabled` is true but no token is set. In non-prod without a token the middleware refuses to mount (warn + skip). Generate with `SecureRandom.hex(32)`. |
| `console_mcp_allowed_origins` | Array\<String\> | `%w[http://localhost http://127.0.0.1 http://[::1]]` | `OriginGuard` allowlist. Port is stripped before comparison, so `http://localhost` matches any localhost port. Override for tunneled / internal-dashboard access. |
| `console_mcp_path` | String | `/mcp/console` | URL path the Rack middleware responds on. |
| `console_embedded_read_tools` | Boolean | `false` | Enable the Tier 4 read tools `console_sql` / `console_query` in embedded (Rack) mode. Bridge-mode deployments always expose them. |
| `console_blocked_tables` | Array\<String\> | `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` | TableGate denylist (case-insensitive). Bare names match every schema; qualified names (`schema.table`) match exactly. |
| `console_redacted_columns` | Array\<String\> | `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` | Column names whose values are replaced with `[REDACTED]` in responses. |
| `console_redacted_key_values` | Array\<Hash\> | `[]` | EAV-style redaction patterns. Each entry: `{ key_column:, value_column:, sensitive_keys: [] }`. |
| `console_credential_defense_enabled` | Boolean | `true` | Layer 5 toggle for the CredentialScanner. Leave on unless you have a specific reason to disable. |
| `console_credential_rotation_warning` | Boolean | `true` | Emit a structured log warning when any Rails credentials file is modified after process start. |
| `console_unsafe_eval_enabled` | Boolean | `false` | Gate for `console_eval`. Off by default; no execution path is currently wired. |

## Environment Variables

These variables are read by the gem and its MCP servers at runtime. They complement (not replace) the configure block — most exist so the MCP servers can self-configure when no explicit config is available.

| Variable | Read by | Default | Purpose |
|----------|---------|---------|---------|
| `WOODS_DIR` | `woods-mcp` bootstrapper | `Dir.pwd` | Path to the extraction output directory. |
| `WOODS_REQUIRE_INDEX` | `woods-mcp` bootstrapper | unset | Set to `"1"` to fail closed: the Index Server refuses to boot (raises `MissingArtifact`) unless a real index (`woods.json`) is present. By default an extract-only host (ran `woods:extract`, no embedding provider) boots in pattern/structural mode without it. |
| `WOODS_ALLOW_AUTODETECT` | `woods-mcp` bootstrapper | unset | **Deprecated no-op.** Auto-detect is now the default when no `woods.json` and no provider are present; this flag is still accepted for backward compatibility but has no effect. |
| `WOODS_SEARCH_MAX_SCAN` | `woods-mcp` `search` tool | `500` | Cap on the number of unit files loaded during a phase-2 (metadata/source_code) search. When the cap is hit, the response includes `partial: true`. Set empty or unset to use the default. |
| `WOODS_SNAPSHOTS` | `woods-mcp` bootstrapper | unset | Set to `"true"` to force-enable temporal snapshot storage, even without a pre-existing SQLite database. |
| `OPENAI_API_KEY` | `woods-mcp` bootstrapper | — | When set and no embedding provider is configured, the MCP server auto-enables OpenAI-backed semantic search with in-memory stores. |
| `OLLAMA_BASE_URL` | `woods-mcp` bootstrapper auto-detect | `http://localhost:11434` | Base URL the bootstrapper probes (`GET /api/tags`, 500ms timeout) when no embedding provider is configured. A reachable Ollama instance auto-enables local semantic search. |
| `OLLAMA_EMBED_MODEL` | `woods-mcp` bootstrapper auto-detect | `nomic-embed-text` | Model to use when Ollama is auto-detected. |

The `woods-mcp` bootstrapper emits a one-line STDERR banner at startup indicating whether semantic search is enabled and which provider is active. If no key/instance is found, pattern search still works and `codebase_retrieve` surfaces an actionable fix message.

## Database Compatibility

All storage options work with both MySQL and PostgreSQL, except:

- **pgvector** — PostgreSQL only (requires the pgvector extension)
- **SQLite metadata store** — uses a standalone SQLite database file, independent of your app's database

See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.
