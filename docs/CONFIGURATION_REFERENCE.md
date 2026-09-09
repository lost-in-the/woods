# Configuration Reference

All configuration is done via the `Woods.configure` block, typically in `config/initializers/woods.rb`.

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
  config.max_context_tokens = 8000
  # ...
end
```

## Options index

- [Common configuration patterns](#common-configuration-patterns)
  - [CI-only extraction (skip framework sources)](#ci-only-extraction-skip-framework-sources)
  - [Docker extraction with environment-based paths](#docker-extraction-with-environment-based-paths)
  - [Environment-conditional embedding provider](#environment-conditional-embedding-provider)
- [Core options](#core-options)
- [Embedding options](#embedding-options)
  - [OpenAI embeddings](#openai-embeddings)
  - [Ollama embeddings](#ollama-embeddings)
  - [Fake embeddings (CI / sandboxes / offline hosts)](#fake-embeddings-ci--sandboxes--offline-hosts)
  - [Injecting a provider object](#injecting-a-provider-object)
- [Storage options](#storage-options)
  - [pgvector (PostgreSQL)](#pgvector-postgresql)
  - [Qdrant](#qdrant)
  - [SQLite metadata](#sqlite-metadata)
  - [In-memory metadata](#in-memory-metadata)
- [Retrieval cache options](#retrieval-cache-options)
- [Deployment shapes](#deployment-shapes)
  - [Shape 2 setup (`:shared_filesystem`)](#shape-2-setup-shared_filesystem)
- [Presets](#presets)
- [Pipeline options](#pipeline-options)
- [Session tracer options](#session-tracer-options)
- [Gem indexing](#gem-indexing)
- [Extractors](#extractors)
- [Console MCP options](#console-mcp-options)
- [Environment variables](#environment-variables)
  - [Index server (`woods-mcp` / `woods-mcp-http` / `woods-mcp-start`)](#index-server-woods-mcp--woods-mcp-http--woods-mcp-start)
  - [Rake tasks](#rake-tasks)
  - [HTTP transport (`woods-mcp-http`)](#http-transport-woods-mcp-http)
  - [Console server (`woods-console-mcp`)](#console-server-woods-console-mcp)
  - [Watch daemon (`woods:watch`)](#watch-daemon-woodswatch)
  - [Extraction rake tasks](#extraction-rake-tasks)
  - [Exporters](#exporters)
- [Database compatibility](#database-compatibility)

## Common configuration patterns

### CI-only extraction (skip framework sources)

`config.extractors` cannot select a subset of extractors, it's accepted for
forward compatibility only (see [Extractors](#extractors) below). To speed up
CI, skip the one extractor that's actually optional instead:

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')

  # In CI, skip Rails/gem framework source extraction for faster builds
  config.include_framework_sources = false if ENV['CI']
end
```

### Docker extraction with environment-based paths

```ruby
Woods.configure do |config|
  # Inside Docker, /app is the Rails root
  config.output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods'))
end
```

### Environment-conditional embedding provider

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

## Core options

Columns:

- **User-settable**: a direct `Woods.configure { |c| c.<option> = ... }` writes the value verbatim.
- **Preset-derived**: set by `Builder.preset_config(:local | :shared_filesystem | :postgresql | :production)` as a group. You can override any preset value afterwards in the `configure` block, later writes win.
- **Computed**: derived from other options at read time (or at `build_*` time by `Woods::Builder`). Writing directly has no effect; change the inputs instead.

| Option | Type | Default | Role | Description |
|--------|------|---------|------|-------------|
| `output_dir` | Pathname/String | `Rails.root.join('tmp/woods')` | user-settable | Directory where extracted data is written |
| `extractors` | Array&lt;Symbol&gt; | `[:models, :controllers, :services, ...]` | accepted, not implemented | Does not select which extractors run. See [Extractors](#extractors) below. |
| `pretty_json` | Boolean | `true` | user-settable | Format extracted JSON with indentation |
| `max_context_tokens` | Integer | `8000` | user-settable | Maximum tokens for retrieval context windows |
| `similarity_threshold` | Float | `0.7` | user-settable | Minimum similarity score (0.0-1.0) for retrieval results |
| `context_format` | Symbol | `:markdown` | user-settable | Output format for retrieval: `:claude`, `:markdown`, `:plain`, `:json` |
| `include_framework_sources` | Boolean | `true` | user-settable | Extract Rails and gem source code |
| `concurrent_extraction` | Boolean | `false` | user-settable | Enable parallel extraction (experimental) |
| `vector_store` / `metadata_store` / `graph_store` / `embedding_provider` | Symbol | n/a | preset-derived | Adapter types. Set by presets; override individually to mix stacks. |
| chars-per-token ratio (used by ContextAssembler, TextPreparer, Builder, cost_model) | Float | `4.0` (OpenAI) / `1.5` (Ollama) | computed | Derived from the active embedding provider via `Woods::TokenUtils.chars_per_token_for(...)`. Not directly user-settable; change `embedding_provider` to change the ratio. |

## Embedding options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `embedding_provider` | Symbol or Object | n/a | Embedding backend: `:openai`, `:ollama`, `:fake` (deterministic, offline, see below), or an already-constructed provider object responding to `#embed`/`#embed_batch` |
| `embedding_model` | String | `'text-embedding-3-small'` | Model name for the embedding provider |
| `embedding_options` | Hash | `nil` | Provider-specific options (see below) |

### OpenAI embeddings

```ruby
config.embedding_provider = :openai
config.embedding_model = 'text-embedding-3-small'
config.embedding_options = {
  api_key: ENV['OPENAI_API_KEY'],
  dimensions: 1536
}
```

### Ollama embeddings

```ruby
config.embedding_provider = :ollama
config.embedding_options = {
  model: 'nomic-embed-text',
  host: 'http://localhost:11434'
  # num_ctx: 2048  # Optional override, see below
}
```

The provider reads `model:`, `host:`, and `num_ctx:` from `embedding_options`. `num_ctx` is auto-selected from a per-model registry (`nomic-embed-text` → 2048, `bge-m3` → 8192, `mxbai-embed-large` → 512, `snowflake-arctic-embed` → 512, `snowflake-arctic-embed2` → 8192, `all-minilm` → 512). Unknown models fall back to 2048, matching Ollama's conservative embedding default. Set `num_ctx:` explicitly only when running a model with a known-larger native context that isn't in the registry yet.

**Why `num_ctx` is capped at the native context.** Ollama has an open regression ([ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)) where `options.num_ctx` does not lift the effective ceiling on `/api/embed` for models whose native context is smaller than the override. Woods advertises the native ceiling so the chunker sizes inputs to what Ollama will actually accept.

**Optional exact tokenization.** Install the [`tokenizers`](https://github.com/ankane/tokenizers-ruby) gem alongside Woods to get BERT WordPiece token counting. Without it, Woods falls back to a chars/token ratio, which under-counts dense Ruby source (CamelCase constants, callback DSLs) and can silently over-pack chunks. Recommended for any Ollama setup.

```ruby
# Gemfile (optional)
gem 'tokenizers', '~> 0.5'
```

See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the full model comparison and the procedure for adding a new model to the registry.

### Fake embeddings (CI / sandboxes / offline hosts)

```ruby
config.embedding_provider = :fake
config.embedding_options = { dims: 128 }  # optional; default 128
```

`:fake` wires `Woods::Embedding::Provider::Fake`, a deterministic bag-of-words hashing provider that needs no network endpoint, so `rake woods:embed` and `rake woods:retrieve` run in CI, sandboxes, and offline hosts. Vectors are L2-normalized, so cosine similarity stays mechanically meaningful (texts sharing vocabulary rank closer), but they are **not semantically meaningful embeddings**: use `:fake` for pipeline smoke tests, never for production retrieval quality. It pairs with any configured store stack: `:in_memory` everywhere for a self-contained smoke run, or the same pgvector/Qdrant + SQLite stores a real provider would use (MySQL-backed hosts pair with Qdrant exactly as in the [backend matrix](BACKEND_MATRIX.md); the provider itself never touches the database).

### Injecting a provider object

Anything responding to `#embed` and `#embed_batch` can be assigned directly, it is used as-is and wrapped in the same retry/circuit-breaker resilience stack as the built-in adapters:

```ruby
config.embedding_provider = MyCompany::CustomEmbedder.new(endpoint: internal_url)
```

## Storage options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vector_store` | Symbol | n/a | Vector backend: `:in_memory`, `:pgvector`, `:qdrant` |
| `vector_store_options` | Hash | `nil` | Backend-specific connection options |
| `metadata_store` | Symbol | n/a | Metadata backend: `:in_memory`, `:sqlite` |
| `metadata_store_options` | Hash | `nil` | Backend-specific options |
| `graph_store` | Symbol | n/a | Graph backend: `:in_memory` |

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
  dimensions: 1536,
  allow_private_hosts: true # explicit opt-in for trusted localhost/private URLs
}
```

### SQLite metadata

```ruby
config.metadata_store = :sqlite
config.metadata_store_options = {
  database: Rails.root.join('tmp/woods/metadata.sqlite3').to_s
}
```

Requires the `sqlite3` gem in your host bundle. Rails apps backed by
MySQL or PostgreSQL won't have it by default, selecting `:sqlite`
without it raises `Woods::ConfigurationError` with install
instructions. For MySQL/Postgres-only hosts, use `:in_memory` (below)
unless cross-process metadata persistence matters.

### In-memory metadata

```ruby
config.metadata_store = :in_memory
```

Pure-Ruby hash-backed store. No external dependencies, no persistence, vectors and metadata both live in the building process and die with
it. The `_index.json` manifest under `output_dir` is the durable
metadata for the index MCP server, so this is a reasonable default
for hosts that don't bundle `sqlite3`.

## Retrieval cache options

The optional cache wraps both embedding-provider calls and assembled retrieval
contexts. It is disabled by default and is separate from the Index Server's
tool-result `_meta` cache hint.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `cache_enabled` | Boolean | `false` | Enable embedding and retrieval-context caching in retrievers built by `Woods::Builder`. |
| `cache_store` | Symbol or `Woods::Cache::CacheStore` | `nil` | Cache backend: `:memory`, `:redis`, `:solid_cache`, or an already-constructed cache-store instance. Must be set when caching is enabled. |
| `cache_options` | Hash | `{}` | Backend constructor options and optional TTL overrides; see below. |

```ruby
# Process-local bounded cache
config.cache_enabled = true
config.cache_store = :memory
config.cache_options = {
  max_entries: 500,
  ttl: { embeddings: 86_400, context: 900 }
}

# Redis-backed cache
config.cache_store = :redis
config.cache_options = {
  redis: Redis.new(url: ENV.fetch('REDIS_URL')),
  default_ttl: 3_600,
  ttl: { embeddings: 86_400, context: 900 }
}
```

`:solid_cache` uses the same shape with `cache:` set to an
`ActiveSupport::Cache::Store`-compatible instance. `default_ttl` applies at the
Redis/Solid Cache store layer when a write supplies no TTL. The `ttl:` hash
overrides the wrapper defaults for `:embeddings` (24 hours) and `:context`
(15 minutes). `:memory` accepts `max_entries` (default 500); it ignores
`default_ttl` because each wrapper write supplies its domain TTL.

## Deployment shapes

Woods supports three deployment shapes, pick the preset that matches yours.

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
    host:  ENV.fetch('OLLAMA_HOST', 'http://localhost:11434') # your own variable; Woods reads none
  }
end
```

The embed run writes `woods.json` + `dumps/<ISO8601>/vectors.bin` + `metadata.msgpack` under `output_dir`. The MCP server reads them at boot, no sqlite3 gem required, no pgvector/Qdrant service needed. Dump retention defaults to the last 3 (configurable via `config.dump_retention_count`).

Requirements:
- `output_dir` must be set and readable by both the embed process and the MCP server.
- The MCP server must know the same `output_dir` (pass via `woods-mcp <DIR>` or set `WOODS_DIR`).

## Presets

For quick setup, use named presets that configure storage + embedding together:

```ruby
# Local development: no cloud key; requires sqlite3 and a running Ollama service
Woods.configure_with_preset(:local)
# → in_memory vectors, SQLite metadata, in_memory graph, Ollama embeddings

# Shared filesystem: rake embed → separate MCP server reads the dump.
# No sqlite3 gem needed; works on MySQL/Postgres-only hosts.
Woods.configure_with_preset(:shared_filesystem)
# → in_memory everything + Snapshotter-based persistence via output_dir

# PostgreSQL: requires pgvector, sqlite3 gem, OpenAI key, and connection
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    connection: ActiveRecord::Base.connection
  }
end
# → pgvector vectors, SQLite metadata, in_memory graph, OpenAI embeddings

# Production: requires Qdrant, sqlite3 gem, and OpenAI API key
Woods.configure_with_preset(:production) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # only when QDRANT_URL is deliberately private
  }
end
# → Qdrant vectors, SQLite metadata, in_memory graph, OpenAI embeddings
```

Presets can be overridden:

```ruby
Woods.configure_with_preset(:local) do |config|
  config.max_context_tokens = 16000
  config.embedding_model = 'mxbai-embed-large'
end
```

## Pipeline options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `precompute_flows` | Boolean | `false` | Pre-compute per-action request flow maps during extraction |
| `extract_navigation_edges` | Boolean | `true` | Extract `link_to`, `redirect_to`, and `form_action` navigation edges from views and controllers |
| `enable_snapshots` | Boolean | `false` | Enable temporal snapshots. Woods automatically migrates its internal output-directory SQLite store; if SQLite is unavailable, it uses the JSON snapshot store. No Rails migration is required. |

## Session tracer options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `session_tracer_enabled` | Boolean | `false` | Enable session tracing middleware |
| `session_tracer_allow_production` | Boolean | `false` | Explicitly allow session tracing in `Rails.env.production?`. Without this opt-in, the Railtie warns and leaves the tracer disabled even when `session_tracer_enabled` is true. Review trace contents, retention, and access controls before enabling it. |
| `session_store` | Object | `nil` | Store backend: `FileStore`, `RedisStore`, or `SolidCacheStore` |
| `session_id_proc` | Proc | `nil` | Custom proc to extract session ID from requests |
| `session_exclude_paths` | Array&lt;String&gt; | `[]` | Path patterns to exclude from tracing |

```ruby
require 'woods/session_tracer/file_store' # the stores are not autoloaded

config.session_tracer_enabled = true
config.session_store = Woods::SessionTracer::FileStore.new(
  Rails.root.join('tmp/session_traces')
)
config.session_exclude_paths = ['/health', '/metrics', '/assets']
```

## Gem indexing

`config.add_gem` is accepted for forward compatibility but **not implemented**: nothing in the
extraction path reads the registered gem configs, and calling it emits a warning.
`RailsSourceExtractor` indexes a fixed set of Rails framework paths only.

Priority levels (`:low`, `:medium`, `:high`) affect retrieval ranking when framework source is relevant to a query.

## Extractors

`config.extractors` accepts an array of symbols but **extractor selection is
not implemented**. All 34 extractors always run during a full extraction,
regardless of what this array holds, nothing in the extraction path reads
it (`Woods::Extractor::EXTRACTORS` is a frozen constant, not derived from
config). Setting `extractors` to anything other than its default value emits
a warning:

```ruby
config.extractors = %i[models controllers services]
# => warns: "config.extractors is accepted for forward compatibility but
#    extractor selection is not implemented; all extractors run."
```

The array exists for forward compatibility with a future selection knob.
Leave it at its default. The full list of what always runs:

| Symbol | Extractor | What it adds |
|--------|-----------|-------------|
| `:models` | ModelExtractor | ActiveRecord models, with concerns inlined and schema prepended |
| `:controllers` | ControllerExtractor | Controllers with route context and filter chains |
| `:services` | ServiceExtractor | Service/interactor/operation objects |
| `:components` | PhlexExtractor | Phlex components |
| `:view_components` | ViewComponentExtractor | ViewComponent classes |
| `:jobs` | JobExtractor | ActiveJob/Sidekiq workers |
| `:mailers` | MailerExtractor | ActionMailer classes |
| `:graphql` | GraphQLExtractor | GraphQL types, mutations, resolvers, queries |
| `:serializers` | SerializerExtractor | AMS/Blueprinter/Alba/Draper serializers |
| `:managers` | ManagerExtractor | SimpleDelegator wrapper classes |
| `:policies` | PolicyExtractor | Non-Pundit domain policy classes |
| `:validators` | ValidatorExtractor | Custom ActiveModel validators |
| `:concerns` | ConcernExtractor | ActiveSupport::Concern modules |
| `:routes` | RouteExtractor | Rails routes |
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
| `:rails_source` | RailsSourceExtractor | Rails/gem framework source (toggle via `include_framework_sources`) |
| `:poros` | PoroExtractor | Plain Ruby objects in app/models |
| `:libs` | LibExtractor | Ruby files in lib/ |

See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for what each one captures in detail.

## Console MCP options

These options configure the Console MCP server (live database queries via
MCP). See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full
deployment guide including defense layers.

| Key | Type | Default | Description |
|---|---|---|---|
| `console_mcp_enabled` | Boolean | `false` | Master switch. When `false`, the Railtie does not mount the Console MCP middleware. |
| `console_mcp_token` | String | `ENV['WOODS_CONSOLE_MCP_TOKEN']` or `nil` | Bearer token required on every Console HTTP request. **Required in production**: the Railtie raises `Woods::ConfigurationError` when `console_mcp_enabled` is true but no token is set. In non-production a missing token warns at boot and every Console request fails closed with `401 Unauthorized`. A configured token shorter than 32 characters raises `Woods::ConfigurationError` at boot in every environment. Generate with `SecureRandom.hex(32)`. |
| `console_mcp_allowed_origins` | Array\<String\> | `%w[http://localhost http://127.0.0.1 http://[::1]]` | `OriginGuard` allowlist. Port is stripped before comparison, so `http://localhost` matches any localhost port. Override for tunneled / internal-dashboard access. |
| `console_mcp_path` | String | `/mcp/console` | URL path the Rack middleware responds on. |
| `console_embedded_read_tools` | Boolean | `false` | Register `console_sql` and `console_query` in supported stdio and Rack modes. |
| `console_blocked_tables` | Array\<String\> | `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` | TableGate denylist (case-insensitive). Bare names match every schema; qualified names (`schema.table`) match exactly. |
| `console_redacted_columns` | Array\<String\> | `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` | Column names whose values are replaced with `[REDACTED]` in responses, and which are refused as aggregate, scope, find, and order inputs. |
| `console_redacted_key_values` | Array\<Hash\> | `[]` | EAV-style redaction patterns. Each entry: `{ key_column:, value_column:, sensitive_keys: [] }`. |
| `console_credential_defense_enabled` | Boolean | `true` | Layer 5 toggle for the CredentialScanner. Leave on unless you have a specific reason to disable. |
| `console_credential_rotation_warning` | Boolean | `true` | Emit a structured log warning when any Rails credentials file is modified after process start. |
| `console_unsafe_eval_enabled` | Boolean | `nil` | Legacy setting. `console_eval` is unavailable; enabling it fails closed at server construction. |
| `console_unsafe_eval_confirmation` | `Confirmation` | `nil` | Legacy option retained for compatibility; passing it fails closed. |
| `console_unsafe_eval_audit_log_path` | String/Pathname | `nil` | Legacy option retained for compatibility; passing it fails closed. |

## Environment variables

These variables are read by the gem and its MCP servers at runtime. They complement (not replace) the configure block, most exist so the MCP servers, rake tasks, and exporters can self-configure or override config without an initializer edit.

### Index server (`woods-mcp` / `woods-mcp-http` / `woods-mcp-start`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `WOODS_DIR` | `Dir.pwd` | Path to the extraction output directory. |
| `WOODS_REQUIRE_INDEX` | unset | Set to `"1"` to fail closed: the server refuses to boot (raises `MissingArtifact`) unless a real index (`woods.json`) is present. By default an extract-only host boots in pattern/structural mode without it. |
| `WOODS_ALLOW_AUTODETECT` | unset | **Deprecated no-op.** Auto-detect is now the default; accepted for backward compatibility only. |
| `WOODS_SEARCH_MAX_SCAN` | `500` | Cap on unit files loaded during a phase-2 (metadata/source_code) `search`. Hitting the cap sets `partial: true` in the response. |
| `WOODS_SNAPSHOTS` | unset | Set to `"true"` to force-enable temporal snapshot storage, even without a pre-existing SQLite database. |
| `WOODS_ALLOW_PURGE` | unset | Set to `"1"` to override the 30%-deletion purge guard in `woods:embed`/`woods:embed_incremental`. |
| `WOODS_PAYLOAD_RETENTION` | `3` | How many past generations' payload directories (`payloads/gen-N/`) to retain, and — when the JSON snapshot store is in use — how many temporal snapshots (`snapshots/`) to keep. A payload pinned by an active reader process is kept temporarily beyond this bound and reconsidered after the pin is released. |
| `WOODS_MCP_CACHE_TTL_MS` | `10000` | Cache TTL advertised in tool result `_meta`. `0` disables caching. |
| `WOODS_NO_UPDATE_CHECK` | unset | Set to `"1"` to skip the `woods_status` RubyGems version check. |
| `XDG_CACHE_HOME` | `~/.cache` | Base directory for the best-effort update-check cache (`$XDG_CACHE_HOME/woods/update_check.json`). An unset or empty value uses `~/.cache`; if the home directory cannot be resolved, Woods falls back to the system temporary directory. |
| `OPENAI_API_KEY` | n/a | When set and no embedding provider is configured, the server auto-enables OpenAI-backed semantic search with in-memory stores. |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Probed (`GET /api/tags`, 500ms timeout) when no embedding provider is configured. A reachable instance auto-enables local semantic search. |
| `OLLAMA_EMBED_MODEL` | `nomic-embed-text` | Model to use when Ollama is auto-detected. |
| `WOODS_QDRANT_URL`, `WOODS_QDRANT_COLLECTION`, `WOODS_QDRANT_API_KEY` | n/a | Override/require Qdrant connection settings when a pgvector/Qdrant-backed index is served outside its host application (no `Woods.configuration` available). |
| `WOODS_PG_URL` | n/a | Required when a pgvector-backed index is served outside its host application. |

### Rake tasks

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_DEPTH` | `5` | Maximum dependency traversal depth for `woods:flow[EntryPoint]`. Parsed as an integer. |
| `FORMAT` | `markdown` | Output format for `woods:flow[EntryPoint]`. Set to `json` for pretty-printed JSON; every other value uses Markdown. |

### HTTP transport (`woods-mcp-http`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `WOODS_MCP_HTTP_TOKEN` | unset | Bearer token required for non-loopback binds; startup refuses without one. |
| `WOODS_MCP_HTTP_ALLOWED_ORIGINS` | loopback only | Comma-separated origin allow-list. |
| `WOODS_MCP_HTTP_STATELESS` | `1` (stateless) | Set to `0`/`false`/`no` to restore session-based mode. |

### Console server (`woods-console-mcp`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `WOODS_CONSOLE_CONFIG` | `~/.woods/console.yml` when present | Explicit launcher YAML path. An explicit missing path fails startup. |
| `WOODS_CONSOLE_MCP_TOKEN` | unset | Bearer token for the embedded Rack middleware; see `console_mcp_token` above. |
| `WOODS_CONSOLE_UNSAFE_EVAL` | unset | Legacy setting. The exact value `true` requests unavailable eval capability and fails server construction closed. |

### Watch daemon (`woods:watch`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `WOODS_IGNORE_WATCH` | unset | Set to `"1"` to make `woods:incremental`/`woods:clean` proceed even when a daemon is (or claims to be) running. For `woods:incremental` this removes daemon coverage: a git range that fails to resolve then exits 1 instead of standing down (see [Incremental Extraction](./INCREMENTAL_EXTRACTION.md#exit-behavior-in-ci-chains)). |
| `WOODS_LOCK_WAIT` | `Watch::Daemon::LOCK_STALE_TIMEOUT` (600s) | How long a rake writer waits for `PipelineLock` before exiting non-zero. |
| `WOODS_WATCH_POLL` | auto-detected | Set to `"1"`/`"0"` to force/disable polling mode (vs. `listen` gem, e.g. in a container without inotify). |
| `WOODS_WATCH_DEBOUNCE` | `0.4` (seconds) | Delay before processing a batch of file-change events. |
| `WOODS_WATCH_FULL_THRESHOLD` | `50` | Number of changed paths in one batch that triggers a full extraction instead of incremental. |
| `WOODS_WATCH_IDLE_TIMEOUT` | unset (no timeout) | Seconds of inactivity before the daemon exits. |
| `WOODS_WATCH_CATCH_UP` | `1` (enabled) | Set to `"0"` to skip generation-watermark catch-up on daemon start. |

### Extraction rake tasks

| Variable | Default | Purpose |
|----------|---------|---------|
| `WOODS_OUTPUT` | `Woods.configuration.output_dir` | Overrides the output directory for `woods:extract`/`woods:incremental`/`woods:watch` without editing the initializer. |
| `CHANGED_FILES` | unset | Comma-separated explicit changed-path list for `woods:incremental`; when set, git range resolution is skipped entirely. |
| `CI_COMMIT_BEFORE_SHA`, `CI_COMMIT_SHA` | unset (GitLab) | Build the diff range `<before>..<after>` for `woods:incremental`. A zero before-SHA (new branch) makes the range unresolvable, which exits 1 unless a running daemon covers the index. |
| `GITHUB_BASE_REF` | unset (GitHub Actions) | Build the diff range `origin/<ref>...HEAD` for `woods:incremental`; an unfetched ref makes the range unresolvable, same exit behavior. |
| `RAILS_ENV` | `development` | Rails environment the rake tasks boot in. |

### Exporters

| Variable | Default | Purpose |
|----------|---------|---------|
| `NOTION_API_TOKEN` | `config.notion_api_token` | Overrides the configured Notion token. |
| `WOODS_NOTION_FORCE` | unset | Set to `"1"` (or pass `force_full: true`) to ignore the Notion sync manifest for one run and re-check every page. |
| `UNBLOCKED_API_TOKEN`, `UNBLOCKED_COLLECTION_ID`, `UNBLOCKED_REPO_URL` | `config.unblocked_*` | Overrides the configured Unblocked connection settings. |
| `UNBLOCKED_DAILY_BUDGET` | `1000` | Per-run call cap for `woods:unblocked_sync`. |
| `UNBLOCKED_FORCE_FULL_SYNC` | unset | Set to `"1"` to re-push every Unblocked document, ignoring the unchanged-hash skip. |
| `UNBLOCKED_FORCE_PURGE` | unset | Set to `"1"` to bypass the Unblocked 30%-deletion guard. |
| `WOODS_OBSIDIAN_VAULT` | `<output_dir>/obsidian_vault` | Vault output path for `woods:obsidian`. |
| `WOODS_OBSIDIAN_INCLUDE_FRAMEWORK`, `WOODS_OBSIDIAN_INCLUDE_SOURCE` | `false` | Include framework units / full source in the exported vault. |
| `WOODS_OBSIDIAN_FORCE_PURGE` | unset | Bypass the Obsidian 30%-deletion guard on the stale-note sweep. |

The `woods-mcp` bootstrapper emits a one-line STDERR banner at startup indicating whether semantic search is enabled and which provider is active. If no key/instance is found, pattern search still works and `codebase_retrieve` surfaces an actionable fix message.

## Database compatibility

All storage options work with both MySQL and PostgreSQL, except:

- **pgvector**: PostgreSQL only (requires the pgvector extension)
- **SQLite metadata store**: uses a standalone SQLite database file, independent of your app's database

See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.
