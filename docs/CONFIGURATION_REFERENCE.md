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
    config.embedding_model = 'nomic-embed-text'
    config.embedding_options = { base_url: ENV.fetch('OLLAMA_URL', 'http://localhost:11434') }
  end
end
```

---

## Core Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `output_dir` | Pathname/String | `Rails.root.join('tmp/woods')` | Directory where extracted data is written |
| `extractors` | Array&lt;Symbol&gt; | `[:models, :controllers, :services, ...]` | List of enabled extractors (see [Extractors](#extractors) below) |
| `pretty_json` | Boolean | `true` | Format extracted JSON with indentation |
| `max_context_tokens` | Integer | `8000` | Maximum tokens for retrieval context windows |
| `similarity_threshold` | Float | `0.7` | Minimum similarity score (0.0-1.0) for retrieval results |
| `context_format` | Symbol | `:markdown` | Output format for retrieval: `:claude`, `:markdown`, `:plain`, `:json` |
| `include_framework_sources` | Boolean | `true` | Extract Rails and gem source code |
| `concurrent_extraction` | Boolean | `false` | Enable parallel extraction (experimental) |

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
config.embedding_model = 'nomic-embed-text'
config.embedding_options = {
  base_url: 'http://localhost:11434'
}
```

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

## Presets

For quick setup, use named presets that configure storage + embedding together:

```ruby
# Local development — no external services needed
Woods.configure_with_preset(:local)
# → in_memory vectors, SQLite metadata, in_memory graph, Ollama embeddings

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

## Svelte Flow Visualization

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `svelte_flow_enabled` | Boolean | `false` | Mount the visualization middleware in the Rails app |
| `svelte_flow_path` | String | `'/woods/visualize'` | URL path where the visualization UI is served |

### Export Mode (No Configuration Needed)

Generate Svelte Flow-compatible JSON files from extraction output:

```bash
bundle exec rake woods:svelte_flow_export
# Or with the alias:
bundle exec rake woods:map
```

Output is written to `{output_dir}/svelte_flow/` with dependency graph, domain clusters, and flow visualizations.

### Server Mode

Mount an interactive visualization page in your Rails app:

```ruby
Woods.configure do |config|
  config.svelte_flow_enabled = true
  config.svelte_flow_path = '/woods/visualize'  # default
end
```

Visit `/woods/visualize` in your browser to see the interactive graph. The middleware serves a JSON API at `/woods/visualize/api/graph`, `/woods/visualize/api/clusters`, and `/woods/visualize/api/flows`.

For flow visualizations, enable flow precomputation during extraction:

```ruby
config.precompute_flows = true
```

See [SVELTE_FLOW_VISUALIZATION.md](SVELTE_FLOW_VISUALIZATION.md) for the full integration guide.

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

## Environment Variables

These variables are read by the gem and its MCP servers at runtime. They complement (not replace) the configure block — most exist so the MCP servers can self-configure when no explicit config is available.

| Variable | Read by | Default | Purpose |
|----------|---------|---------|---------|
| `WOODS_DIR` | `woods-mcp` bootstrapper | `Dir.pwd` | Path to the extraction output directory. |
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
