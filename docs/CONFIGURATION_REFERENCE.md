# Configuration Reference

All configuration is done via the `CodebaseIndex.configure` block, typically in `config/initializers/codebase_index.rb`.

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
  config.max_context_tokens = 8000
  # ...
end
```

## Core Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `output_dir` | Pathname/String | `Rails.root.join('tmp/codebase_index')` | Directory where extracted data is written |
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
bundle exec rails generate codebase_index:pgvector
bundle exec rails db:migrate
```

### Qdrant

```ruby
config.vector_store = :qdrant
config.vector_store_options = {
  url: 'http://localhost:6333',
  collection: 'codebase_index',
  dimensions: 1536
}
```

### SQLite Metadata

```ruby
config.metadata_store = :sqlite
config.metadata_store_options = {
  database: Rails.root.join('tmp/codebase_index/metadata.sqlite3').to_s
}
```

## Presets

For quick setup, use named presets that configure storage + embedding together:

```ruby
# Local development — no external services needed
CodebaseIndex.configure_with_preset(:local)
# → in_memory vectors, SQLite metadata, in_memory graph, Ollama embeddings

# PostgreSQL — requires pgvector extension and OpenAI API key
CodebaseIndex.configure_with_preset(:postgresql)
# → pgvector vectors, SQLite metadata, in_memory graph, OpenAI embeddings

# Production — requires Qdrant server and OpenAI API key
CodebaseIndex.configure_with_preset(:production)
# → Qdrant vectors, SQLite metadata, in_memory graph, OpenAI embeddings
```

Presets can be overridden:

```ruby
CodebaseIndex.configure_with_preset(:local) do |config|
  config.max_context_tokens = 16000
  config.embedding_model = 'mxbai-embed-large'
end
```

## Pipeline Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `precompute_flows` | Boolean | `false` | Pre-compute per-action request flow maps during extraction |
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
config.session_store = CodebaseIndex::SessionTracer::FileStore.new(
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

## Database Compatibility

All storage options work with both MySQL and PostgreSQL, except:

- **pgvector** — PostgreSQL only (requires the pgvector extension)
- **SQLite metadata store** — uses a standalone SQLite database file, independent of your app's database

See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.
