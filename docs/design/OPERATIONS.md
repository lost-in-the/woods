# Operations

## Purpose

This document covers the operational concerns that sit between "it works in development" and "it runs in production": schema management, error handling, graceful degradation, and observability. These are the areas most likely to be underestimated during implementation and most painful to retrofit.

---

## Schema Management

### The Problem

CodebaseIndex needs database tables (`codebase_units`, `codebase_edges`, `codebase_embeddings`) in whatever metadata/graph store the team selects. The question is how those tables get created, how they evolve across versions, and how this works across different environments.

This is complicated by the fact that CodebaseIndex:
- May or may not run inside a Rails application
- Supports multiple database backends (MySQL, PostgreSQL, SQLite)
- May use the application's existing database or a separate one
- Needs to handle upgrades without data loss

### Strategy: Generator + Standalone Tasks

Two paths to schema setup, depending on whether you're inside Rails:

**Inside Rails (primary path):**

```ruby
# Install generator creates a migration
rails generate codebase_index:install

# Generates:
# db/migrate/XXXXXX_create_codebase_index_tables.rb
# config/initializers/codebase_index.rb
```

The generator detects your database adapter and produces the correct migration:

```ruby
class CreateCodebaseIndexTables < ActiveRecord::Migration[7.0]
  def change
    create_table :codebase_units, id: false do |t|
      t.string :id, primary_key: true
      t.string :unit_type, null: false, limit: 50  # model, controller, service, job, mailer, component, graphql_type, graphql_mutation, graphql_resolver, graphql_query, framework_source
      t.string :namespace, limit: 255
      t.string :file_path, limit: 500
      t.text :source_code, size: :medium  # MEDIUMTEXT on MySQL, TEXT on PG
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :codebase_units, :unit_type
    add_index :codebase_units, :namespace

    # Full-text index (adapter-specific)
    if mysql?
      execute "ALTER TABLE codebase_units ADD FULLTEXT INDEX idx_fulltext (id, file_path, source_code)"
    elsif postgresql?
      execute <<~SQL
        CREATE INDEX idx_fulltext ON codebase_units
        USING gin (to_tsvector('english', coalesce(id, '') || ' ' || coalesce(file_path, '') || ' ' || coalesce(source_code, '')))
      SQL
    end

    create_table :codebase_edges, id: false do |t|
      t.string :source_id, null: false
      t.string :target_id, null: false
      t.string :relationship, null: false, limit: 50
    end

    add_index :codebase_edges, [:source_id, :target_id, :relationship], unique: true, name: "idx_edges_pk"
    add_index :codebase_edges, :target_id
    add_index :codebase_edges, :relationship
  end

  private

  def mysql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
  end

  def postgresql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("postgresql")
  end
end
```

**Generated columns (MySQL only):**

A second optional migration adds MySQL generated columns for commonly-filtered JSON fields:

```ruby
rails generate codebase_index:generated_columns

# Generates:
# db/migrate/XXXXXX_add_codebase_index_generated_columns.rb
```

```ruby
class AddCodebaseIndexGeneratedColumns < ActiveRecord::Migration[7.0]
  def up
    return unless mysql?

    execute <<~SQL
      ALTER TABLE codebase_units
        ADD COLUMN change_frequency VARCHAR(20) GENERATED ALWAYS AS (
          JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.git.change_frequency'))
        ) STORED,
        ADD COLUMN importance VARCHAR(20) GENERATED ALWAYS AS (
          JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.importance'))
        ) STORED,
        ADD COLUMN estimated_tokens INT GENERATED ALWAYS AS (
          JSON_EXTRACT(metadata, '$.estimated_tokens')
        ) STORED,
        ADD INDEX idx_change_freq (change_frequency),
        ADD INDEX idx_importance (importance)
    SQL
  end

  def down
    return unless mysql?

    execute <<~SQL
      ALTER TABLE codebase_units
        DROP INDEX idx_change_freq,
        DROP INDEX idx_importance,
        DROP COLUMN change_frequency,
        DROP COLUMN importance,
        DROP COLUMN estimated_tokens
    SQL
  end
end
```

**Outside Rails (standalone):**

For use as a standalone tool or in non-Rails Ruby projects:

```ruby
# Rake task handles schema directly
rake codebase_index:db:setup          # Create tables
rake codebase_index:db:migrate        # Run pending migrations
rake codebase_index:db:status         # Show migration status
rake codebase_index:db:reset          # Drop and recreate
```

Internally, these use a lightweight migration system (not ActiveRecord migrations) that reads SQL from versioned files:

```
lib/codebase_index/db/
├── migrations/
│   ├── 001_create_units.rb
│   ├── 002_create_edges.rb
│   ├── 003_add_generated_columns_mysql.rb
│   └── 004_add_embedding_metadata.rb
├── schema/
│   ├── mysql.sql       # Full schema for MySQL fresh installs
│   ├── postgresql.sql  # Full schema for PostgreSQL fresh installs
│   └── sqlite.sql      # Full schema for SQLite fresh installs
└── migrate.rb          # Migration runner
```

Each migration file is a simple Ruby class:

```ruby
module CodebaseIndex
  module DB
    class Migration001CreateUnits < Migration
      def up(conn, adapter)
        case adapter
        when :mysql
          conn.execute <<~SQL
            CREATE TABLE IF NOT EXISTS codebase_units (
              id VARCHAR(255) PRIMARY KEY,
              -- ... MySQL-specific schema
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
          SQL
        when :postgresql
          conn.execute <<~SQL
            CREATE TABLE IF NOT EXISTS codebase_units (
              id TEXT PRIMARY KEY,
              -- ... PostgreSQL-specific schema
            )
          SQL
        when :sqlite
          conn.execute <<~SQL
            CREATE TABLE IF NOT EXISTS codebase_units (
              id TEXT PRIMARY KEY,
              -- ... SQLite-specific schema
            )
          SQL
        end
      end

      def down(conn, adapter)
        conn.execute "DROP TABLE IF EXISTS codebase_units"
      end
    end
  end
end
```

### Schema Versioning

The gem tracks schema versions in a `codebase_index_schema_migrations` table:

```sql
CREATE TABLE codebase_index_schema_migrations (
  version VARCHAR(20) PRIMARY KEY,
  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

This is separate from Rails' `schema_migrations` to avoid conflicts when CodebaseIndex uses the application database.

### Vector Store Schema

Vector stores (Qdrant, pgvector, Pinecone) handle their own schema:

**Qdrant:** Collection creation is handled by the vector store adapter on first use. No migration needed.

```ruby
# Qdrant adapter auto-creates collection
class QdrantAdapter
  def ensure_collection!
    return if collection_exists?

    client.create_collection(
      collection_name: @collection,
      vectors: { size: @dimensions, distance: "Cosine" }
    )
  end
end
```

**pgvector:** Requires the extension to be enabled (needs superuser), then a migration for the embeddings table:

```ruby
rails generate codebase_index:pgvector

# Generates:
# db/migrate/XXXXXX_create_codebase_embeddings.rb

class CreateCodebaseEmbeddings < ActiveRecord::Migration[7.0]
  def up
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :codebase_embeddings, id: false do |t|
      t.string :id, primary_key: true
      t.column :embedding, "vector(1536)"  # Dimension matches embedding provider
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    execute <<~SQL
      CREATE INDEX ON codebase_embeddings
      USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    SQL

    execute <<~SQL
      CREATE INDEX ON codebase_embeddings
      USING gin (metadata jsonb_path_ops)
    SQL
  end
end
```

**Dimension changes:** If you switch embedding providers (e.g., OpenAI 1536-dim → Voyage 1024-dim), the vector column dimension must change. This requires:

1. Create new column with new dimension
2. Re-embed all units (full re-index)
3. Drop old column
4. Rename new column

The gem should provide a rake task for this:

```ruby
rake codebase_index:reindex[new_provider]
# 1. Creates new vector storage alongside old
# 2. Re-embeds everything with new provider
# 3. Swaps atomically
# 4. Drops old storage
```

### Upgrade Path

When a new version of the gem adds schema changes:

1. Bump gem version
2. Run `rails generate codebase_index:install` (idempotent, only generates new migrations)
3. Run `rails db:migrate`

Or standalone:

1. Bump gem version
2. Run `rake codebase_index:db:migrate`

Schema migrations are forward-only. Downgrades are not guaranteed (consistent with Rails conventions).

---

## Error Handling & Graceful Degradation

### Design Philosophy

CodebaseIndex should never be the reason your application fails. It's a development-time tool that may run alongside production workloads (if using the application database). Errors in indexing or retrieval should degrade gracefully, never crash the host application, and always be observable.

### Error Categories

| Category | Examples | Severity | Strategy |
|----------|----------|----------|----------|
| **Vector store unreachable** | Qdrant down, network timeout, connection refused | Medium | Fall back to keyword-only search |
| **Embedding API failure** | OpenAI rate limit, 500 error, timeout, quota exceeded | Medium | Queue for retry, serve stale embeddings |
| **Metadata store failure** | Database connection lost, query timeout | High | Return cached/stale results or empty with error |
| **Dimension mismatch** | Embedding provider changed, wrong model loaded | Critical | Refuse to index, surface clear error |
| **Corrupt index** | Partial write, interrupted indexing, schema drift | Medium | Validate on startup, rebuild if needed |
| **Token budget exceeded** | Assembled context larger than budget | Low | Truncate with priority ordering |
| **Invalid query** | Empty query, nonsensical input | Low | Return empty with explanation |
| **Permission errors** | Can't read source files, can't access database | High | Skip unit, log, continue extraction |

### Degradation Tiers

The retrieval system operates in tiers. When a component fails, it drops to the next available tier:

```
Tier 1: Full retrieval (vector + keyword + graph + ranking)
  │
  │ Vector store fails
  ▼
Tier 2: Keyword + graph (no semantic search, exact matches only)
  │
  │ Metadata store fails
  ▼
Tier 3: Graph-only (dependency traversal from known identifiers)
  │
  │ Graph store fails
  ▼
Tier 4: Direct file lookup (read from extracted JSON on disk)
  │
  │ Extraction output missing
  ▼
Tier 5: Empty result with diagnostic message
```

### Implementation Patterns

**Circuit breaker for external services:**

```ruby
module CodebaseIndex
  class CircuitBreaker
    STATES = %i[closed open half_open].freeze

    def initialize(name:, failure_threshold: 5, reset_timeout: 60)
      @name = name
      @failure_threshold = failure_threshold
      @reset_timeout = reset_timeout
      @failure_count = 0
      @state = :closed
      @last_failure_at = nil
    end

    def call(&block)
      case @state
      when :closed
        execute_with_tracking(&block)
      when :open
        if Time.now - @last_failure_at > @reset_timeout
          @state = :half_open
          execute_with_tracking(&block)
        else
          raise CircuitOpenError, "Circuit #{@name} is open (#{@failure_count} failures, resets in #{remaining_reset_time}s)"
        end
      when :half_open
        execute_with_tracking(&block)
      end
    end

    private

    def execute_with_tracking
      result = yield
      reset! if @state == :half_open
      result
    rescue StandardError => e
      record_failure!
      raise
    end

    def record_failure!
      @failure_count += 1
      @last_failure_at = Time.now
      @state = :open if @failure_count >= @failure_threshold
    end

    def reset!
      @failure_count = 0
      @state = :closed
    end
  end
end
```

**Retriever with fallback:**

```ruby
module CodebaseIndex
  class Retriever
    def retrieve(query, budget: 8000)
      classification = classify(query)
      trace = RetrievalTrace.new(query: query, classification: classification)

      # Attempt full retrieval
      candidates = search_with_fallback(query, classification, trace)
      ranked = rank(candidates, classification, trace)
      context = assemble(ranked, budget, trace)

      RetrievalResult.new(
        context: context.text,
        tokens_used: context.tokens,
        sources: context.sources,
        classification: classification,
        trace: trace,
        degraded: trace.degraded?,
        degradation_reason: trace.degradation_reason
      )
    end

    private

    def search_with_fallback(query, classification, trace)
      candidates = []

      # Vector search (Tier 1)
      begin
        vector_results = @vector_circuit.call { vector_search(query, classification) }
        candidates.concat(vector_results)
        trace.record(:vector_search, :success, count: vector_results.size)
      rescue CircuitOpenError, VectorStoreError => e
        trace.record(:vector_search, :failed, error: e.message)
        trace.mark_degraded!("Vector search unavailable: #{e.message}")
      end

      # Keyword search (always attempted)
      begin
        keyword_results = keyword_search(query, classification)
        candidates.concat(keyword_results)
        trace.record(:keyword_search, :success, count: keyword_results.size)
      rescue MetadataStoreError => e
        trace.record(:keyword_search, :failed, error: e.message)
        trace.mark_degraded!("Keyword search unavailable: #{e.message}")
      end

      # Graph expansion (if we have any candidates to expand from)
      if candidates.any?
        begin
          graph_results = graph_expand(candidates, classification)
          candidates.concat(graph_results)
          trace.record(:graph_expansion, :success, count: graph_results.size)
        rescue GraphStoreError => e
          trace.record(:graph_expansion, :failed, error: e.message)
          # Graph failure is non-critical — we still have direct results
        end
      end

      # Tier 4 fallback: direct file lookup if nothing worked
      if candidates.empty?
        trace.mark_degraded!("All search backends failed, falling back to file lookup")
        candidates = direct_file_lookup(query)
        trace.record(:file_lookup, :fallback, count: candidates.size)
      end

      candidates
    end
  end
end
```

**Embedding retry with backoff:**

```ruby
module CodebaseIndex
  module Embedding
    class RetryableProvider
      MAX_RETRIES = 3
      BACKOFF_BASE = 2  # seconds

      def initialize(provider)
        @provider = provider
        @retry_queue = []
      end

      def embed_batch(texts)
        results = []
        failed = []

        texts.each_slice(batch_size) do |batch|
          retries = 0
          begin
            results.concat(@provider.embed_batch(batch))
          rescue RateLimitError => e
            retries += 1
            if retries <= MAX_RETRIES
              sleep_time = BACKOFF_BASE ** retries + rand(0.0..1.0)
              log_retry(e, retries, sleep_time)
              sleep(sleep_time)
              retry
            else
              log_failure(e, batch)
              failed.concat(batch)
            end
          rescue EmbeddingError => e
            log_failure(e, batch)
            failed.concat(batch)
          end
        end

        # Queue failed items for later retry
        @retry_queue.concat(failed) if failed.any?

        EmbeddingResult.new(
          embeddings: results,
          failed_count: failed.size,
          retry_queued: failed.size
        )
      end

      def process_retry_queue!
        return if @retry_queue.empty?

        to_retry = @retry_queue.dup
        @retry_queue.clear
        embed_batch(to_retry)
      end
    end
  end
end
```

**Stale index detection:**

```ruby
module CodebaseIndex
  class IndexValidator
    def validate!
      issues = []

      # Check schema version
      current = SchemaVersion.current
      expected = CodebaseIndex::SCHEMA_VERSION
      if current != expected
        issues << SchemaVersionMismatch.new(current: current, expected: expected)
      end

      # Check embedding dimensions match
      if @vector_store.respond_to?(:dimensions)
        stored_dims = @vector_store.dimensions
        provider_dims = @embedding_provider.dimensions
        if stored_dims != provider_dims
          issues << DimensionMismatch.new(
            stored: stored_dims,
            provider: provider_dims,
            message: "Vector index has #{stored_dims}-dim vectors but embedding provider produces #{provider_dims}-dim. Full re-index required."
          )
        end
      end

      # Check manifest freshness
      manifest = Manifest.load(@output_dir)
      if manifest.nil?
        issues << MissingManifest.new
      elsif manifest.extracted_at < 7.days.ago
        issues << StaleIndex.new(extracted_at: manifest.extracted_at)
      end

      # Check unit counts match between extraction and index
      extracted_count = Dir.glob("#{@output_dir}/**/*.json").count { |f| !f.include?("_index") }
      indexed_count = @metadata_store.count
      if (extracted_count - indexed_count).abs > extracted_count * 0.1
        issues << CountMismatch.new(extracted: extracted_count, indexed: indexed_count)
      end

      ValidationResult.new(valid: issues.empty?, issues: issues)
    end
  end
end
```

### Error Reporting to Consumers

When retrieval is degraded, the result object communicates this clearly:

```ruby
result = CodebaseIndex.retrieve("how does checkout work?")

result.degraded?           # => true
result.degradation_reason  # => "Vector search unavailable: Qdrant connection refused"
result.tier                # => 2 (keyword + graph only)
result.trace.to_h          # => full diagnostic trace

# For agents, the suggestions field includes degradation info:
result.suggestions
# => ["Results may be incomplete — vector search was unavailable",
#     "Consider retrying after Qdrant is restored",
#     "Keyword-only results may miss semantically related units"]
```

---

## Observability

### Instrumentation Framework

All operations emit events via a pluggable instrumentation system. The default uses `ActiveSupport::Notifications` when available, falling back to a lightweight internal pub/sub.

```ruby
module CodebaseIndex
  module Instrumentation
    def self.instrument(event_name, payload = {}, &block)
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument("codebase_index.#{event_name}", payload, &block)
      else
        InternalNotifier.instrument(event_name, payload, &block)
      end
    end
  end
end
```

### Event Catalog

Every significant operation emits a structured event:

**Extraction events:**

| Event | Payload | When |
|-------|---------|------|
| `extraction.started` | `{ mode:, extractors:, git_sha: }` | Extraction begins |
| `extraction.unit_extracted` | `{ identifier:, type:, tokens:, chunks:, file_path: }` | Each unit extracted |
| `extraction.unit_skipped` | `{ identifier:, reason: }` | Unit skipped (error, excluded) |
| `extraction.graph_analysis` | `{ orphans:, dead_ends:, hubs:, cycles:, bridges:, duration: }` | Graph structural analysis completes |
| `extraction.completed` | `{ units:, duration:, git_sha:, errors: }` | Extraction finishes |

**Embedding events:**

| Event | Payload | When |
|-------|---------|------|
| `embedding.batch_started` | `{ count:, provider:, model: }` | Batch embedding begins |
| `embedding.batch_completed` | `{ count:, duration:, tokens_used:, cost_estimate: }` | Batch completes |
| `embedding.batch_failed` | `{ count:, error:, retryable:, retry_count: }` | Batch fails |
| `embedding.rate_limited` | `{ retry_after:, provider: }` | Rate limit hit |
| `embedding.dimension_mismatch` | `{ expected:, got:, provider: }` | Dimension mismatch detected |

**Retrieval events:**

| Event | Payload | When |
|-------|---------|------|
| `retrieval.started` | `{ query:, budget: }` | Retrieval begins |
| `retrieval.classified` | `{ intent:, scope:, target_type:, framework_context: }` | Query classified |
| `retrieval.vector_search` | `{ candidates:, duration:, similarity_range: }` | Vector search completes |
| `retrieval.keyword_search` | `{ candidates:, duration:, matched_fields: }` | Keyword search completes |
| `retrieval.graph_expansion` | `{ expanded_from:, candidates:, depth:, duration: }` | Graph traversal completes |
| `retrieval.ranked` | `{ candidates_in:, candidates_out:, top_score:, duration: }` | Ranking completes |
| `retrieval.assembled` | `{ tokens_used:, budget:, sources:, sections:, truncated: }` | Context assembled |
| `retrieval.completed` | `{ total_duration:, tokens:, sources:, tier:, degraded: }` | Retrieval finishes |
| `retrieval.failed` | `{ error:, stage:, partial_results: }` | Retrieval fails |

**Storage events:**

| Event | Payload | When |
|-------|---------|------|
| `storage.vector_upsert` | `{ count:, duration:, store: }` | Vectors written |
| `storage.vector_search` | `{ results:, duration:, store:, filters: }` | Vector query |
| `storage.metadata_query` | `{ results:, duration:, store:, filters: }` | Metadata query |
| `storage.graph_traversal` | `{ start:, depth:, nodes_visited:, duration: }` | Graph traversal |
| `storage.circuit_opened` | `{ name:, failure_count:, last_error: }` | Circuit breaker trips |
| `storage.circuit_closed` | `{ name:, recovery_time: }` | Circuit breaker recovers |

### Retrieval Trace

Every retrieval produces a detailed trace object. This is the primary debugging and evaluation tool:

```ruby
module CodebaseIndex
  class RetrievalTrace
    attr_reader :query, :classification, :steps, :started_at, :completed_at

    def initialize(query:, classification:)
      @query = query
      @classification = classification
      @steps = []
      @started_at = Time.now
      @degraded = false
      @degradation_reasons = []
    end

    def record(stage, status, **details)
      @steps << {
        stage: stage,
        status: status,
        timestamp: Time.now,
        duration_ms: details.delete(:duration_ms),
        **details
      }
    end

    def mark_degraded!(reason)
      @degraded = true
      @degradation_reasons << reason
    end

    def complete!
      @completed_at = Time.now
    end

    def total_duration_ms
      ((@completed_at || Time.now) - @started_at) * 1000
    end

    def degraded?
      @degraded
    end

    def to_h
      {
        query: @query,
        classification: @classification,
        started_at: @started_at.iso8601,
        completed_at: @completed_at&.iso8601,
        total_duration_ms: total_duration_ms.round(1),
        degraded: @degraded,
        degradation_reasons: @degradation_reasons,
        steps: @steps.map { |s|
          s.merge(
            elapsed_ms: ((s[:timestamp] - @started_at) * 1000).round(1)
          )
        }
      }
    end

    # Compact summary for logging
    def to_summary
      stages = @steps.map { |s| "#{s[:stage]}:#{s[:status]}" }.join(" → ")
      "query=#{@query.truncate(60)} #{stages} tokens=#{@tokens_used} duration=#{total_duration_ms.round}ms#{' DEGRADED' if @degraded}"
    end
  end
end
```

### Example Trace Output

```json
{
  "query": "how does checkout work?",
  "classification": {
    "intent": "understand",
    "scope": "focused",
    "target_type": "service",
    "framework_context": false
  },
  "started_at": "2025-02-08T14:30:00.000Z",
  "completed_at": "2025-02-08T14:30:00.247Z",
  "total_duration_ms": 247.3,
  "degraded": false,
  "degradation_reasons": [],
  "steps": [
    {
      "stage": "classification",
      "status": "success",
      "elapsed_ms": 2.1,
      "duration_ms": 2.1
    },
    {
      "stage": "vector_search",
      "status": "success",
      "elapsed_ms": 87.4,
      "duration_ms": 85.3,
      "count": 12,
      "similarity_range": [0.92, 0.61]
    },
    {
      "stage": "keyword_search",
      "status": "success",
      "elapsed_ms": 102.1,
      "duration_ms": 14.7,
      "count": 4,
      "matched_fields": ["id", "method_names"]
    },
    {
      "stage": "graph_expansion",
      "status": "success",
      "elapsed_ms": 118.6,
      "duration_ms": 16.5,
      "count": 8,
      "expanded_from": ["CheckoutService", "Order"],
      "depth": 1
    },
    {
      "stage": "ranking",
      "status": "success",
      "elapsed_ms": 125.2,
      "duration_ms": 6.6,
      "candidates_in": 24,
      "candidates_out": 10,
      "top_score": 0.94,
      "scores": {
        "CheckoutService": 0.94,
        "Order": 0.89,
        "CartService": 0.83,
        "PaymentGateway": 0.78,
        "OrdersController": 0.74
      }
    },
    {
      "stage": "assembly",
      "status": "success",
      "elapsed_ms": 247.0,
      "duration_ms": 121.8,
      "tokens_used": 6841,
      "budget": 8000,
      "sections": {
        "structural": 782,
        "primary": 3420,
        "supporting": 1890,
        "framework": 749
      },
      "sources_included": 7,
      "sources_truncated": 1,
      "sources_dropped": 2
    }
  ]
}
```

### Structured Logging

All events are logged in structured format. The default logger writes JSON for machine consumption:

```ruby
module CodebaseIndex
  class StructuredLogger
    def initialize(output: $stdout, level: :info)
      @output = output
      @level = level
    end

    def log(level, event, **data)
      return if level_value(level) < level_value(@level)

      entry = {
        timestamp: Time.now.iso8601(3),
        level: level,
        event: "codebase_index.#{event}",
        **data
      }

      @output.puts(entry.to_json)
    end
  end
end
```

Example log lines:

```json
{"timestamp":"2025-02-08T14:30:00.087Z","level":"info","event":"codebase_index.retrieval.vector_search","query":"checkout","candidates":12,"duration_ms":85.3,"store":"qdrant"}
{"timestamp":"2025-02-08T14:30:00.247Z","level":"info","event":"codebase_index.retrieval.completed","query":"checkout","tokens":6841,"sources":7,"duration_ms":247.3,"degraded":false}
```

```json
{"timestamp":"2025-02-08T14:31:15.003Z","level":"warn","event":"codebase_index.storage.circuit_opened","name":"qdrant","failure_count":5,"last_error":"Connection refused - connect(2) for \"localhost\" port 6333"}
{"timestamp":"2025-02-08T14:31:15.050Z","level":"warn","event":"codebase_index.retrieval.completed","query":"order validation","tokens":2100,"sources":3,"duration_ms":52.1,"degraded":true,"tier":2}
```

### Integration with Existing Observability

**Rails application logger:**

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.logger = Rails.logger
end
```

**ActiveSupport::Notifications subscribers:**

```ruby
# Subscribe to all CodebaseIndex events
ActiveSupport::Notifications.subscribe(/^codebase_index\./) do |name, start, finish, id, payload|
  Rails.logger.info("#{name}: #{payload.to_json}")
end

# Or specific events
ActiveSupport::Notifications.subscribe("codebase_index.retrieval.completed") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.timing("codebase_index.retrieval", event.duration)
  StatsD.increment("codebase_index.retrieval.degraded") if event.payload[:degraded]
end
```

**Datadog / StatsD:**

```ruby
ActiveSupport::Notifications.subscribe("codebase_index.retrieval.completed") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.distribution("codebase_index.retrieval.duration_ms", event.duration * 1000)
  StatsD.distribution("codebase_index.retrieval.tokens", event.payload[:tokens])
  StatsD.gauge("codebase_index.retrieval.tier", event.payload[:tier])
end

ActiveSupport::Notifications.subscribe("codebase_index.embedding.batch_completed") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.increment("codebase_index.embedding.batches")
  StatsD.distribution("codebase_index.embedding.cost", event.payload[:cost_estimate])
end
```

**ELK / structured log aggregation:**

The JSON log format works directly with Filebeat/Logstash. No parsing rules needed.

### Health Check

A health endpoint for monitoring systems:

```ruby
module CodebaseIndex
  class HealthCheck
    def check
      results = {}

      results[:vector_store] = check_component("vector_store") { @vector_store.ping }
      results[:metadata_store] = check_component("metadata_store") { @metadata_store.ping }
      results[:graph_store] = check_component("graph_store") { @graph_store.ping }
      results[:embedding_provider] = check_component("embedding_provider") { @embedding_provider.ping }
      results[:index] = check_index_health

      overall = results.values.all? { |r| r[:status] == :ok } ? :healthy : :degraded
      { status: overall, components: results, checked_at: Time.now.iso8601 }
    end

    private

    def check_component(name)
      start = Time.now
      yield
      { status: :ok, latency_ms: ((Time.now - start) * 1000).round(1) }
    rescue StandardError => e
      { status: :error, error: e.message }
    end

    def check_index_health
      validator = IndexValidator.new(@config)
      result = validator.validate!
      {
        status: result.valid? ? :ok : :warn,
        issues: result.issues.map(&:to_s)
      }
    end
  end
end

# Rake task
# rake codebase_index:health
```

### Metrics Dashboard Guidance

For teams with existing dashboards (Grafana, Datadog, etc.), these are the metrics worth tracking:

**Retrieval quality (daily/weekly):**
- P50/P95/P99 retrieval latency
- Degradation rate (% of retrievals that fell below Tier 1)
- Average tokens used vs budget (are we using budget efficiently?)
- Top queries by frequency (what are agents actually asking?)

**Indexing health (per-merge / daily):**
- Indexing duration (is it getting slower?)
- Units extracted vs indexed (are we losing units?)
- Embedding failures and retry rate
- Index staleness (time since last successful full index)

**Infrastructure health (continuous):**
- Vector store latency and error rate
- Embedding API latency and rate limit frequency
- Circuit breaker state changes
- Database connection pool utilization (if using app database)

---

## Concurrent Indexing Safety

When CodebaseIndex runs in a shared environment — multiple developers, CI pipelines, and agents all potentially triggering operations — understanding which operations are safe for concurrent access is critical.

### Operation Safety Matrix

| Operation | Concurrent Reads | Concurrent with Writes | Multiple Concurrent Writes |
|-----------|-----------------|----------------------|---------------------------|
| **Extraction: read source files** | Safe | Safe (source files are external) | N/A |
| **Extraction: write JSON output** | Safe to read stale | Unsafe — partial writes visible | Unsafe — interleaved writes corrupt output |
| **Extraction: write manifest.json** | Safe to read stale | Unsafe — manifest may not match units | Unsafe |
| **Extraction: write dependency_graph.json** | Safe to read stale | Unsafe — graph may be incomplete | Unsafe |
| **Embedding: read extracted JSON** | Safe | Safe — reads from completed extraction | N/A |
| **Embedding: write to Qdrant** | Safe | Safe — Qdrant handles concurrent upserts | Safe — Qdrant is designed for concurrent writes |
| **Embedding: write to pgvector** | Safe | Safe — PostgreSQL transactions isolate writes | Safe — row-level locking handles conflicts |
| **Embedding: write to FAISS** | Safe (if index not being rebuilt) | Unsafe — FAISS is not thread-safe for writes | Unsafe — must serialize |
| **Embedding: write to SQLite** | Safe | Unsafe — SQLite allows only one writer | Unsafe — WAL mode helps but still serialized |
| **Retrieval: vector search** | Safe | Safe — searches committed data | N/A |
| **Retrieval: metadata query** | Safe | Safe — standard database reads | N/A |
| **Retrieval: graph traversal** | Safe — in-memory copy | Safe — each process loads its own copy | N/A |
| **Validation: index integrity check** | Safe | May report false issues during writes | N/A |

### Safety Tiers

**Tier 1: Always safe (no coordination needed)**

All read-only retrieval operations. Multiple agents can query the index simultaneously without any locking or coordination. This is the common case.

**Tier 2: Safe with standard database guarantees**

Writing embeddings to Qdrant, PostgreSQL (pgvector), or MySQL. These backends handle concurrent writes through their own concurrency control (Qdrant's segment locks, PostgreSQL's MVCC, MySQL's row-level InnoDB locks). No application-level coordination needed.

**Tier 3: Requires serialization**

Extraction (writes JSON files to disk) and FAISS/SQLite writes. These operations must be serialized — only one writer at a time. Use the `PipelineLock` mechanism described in the Multi-Agent Coordination section of AGENTIC_STRATEGY.md.

### Recommended Patterns by Environment

**Development (single developer):**

No coordination needed. Extraction runs on-demand via rake task. Retrieval reads whatever is on disk. If extraction is running, retrieval may return slightly stale results — acceptable.

**Development (multiple developers, shared database):**

Each developer runs extraction against their own checkout. Extracted JSON lives in `tmp/codebase_index/` (gitignored). No shared write conflicts. If using a shared vector store (e.g., shared Qdrant), namespace embeddings by developer or branch:

```ruby
CodebaseIndex.configure do |config|
  config.vector_store_collection = "codebase_#{ENV['USER']}"
end
```

**CI pipeline:**

Extraction and embedding run sequentially in a CI step. No concurrent writes — the pipeline is the only writer. Multiple agents may read from the production index while CI updates it; they see pre-update data until CI completes, which is acceptable.

```yaml
# .buildkite/pipeline.yml
steps:
  - label: "Update Index"
    command:
      - bundle exec rake codebase_index:extract
      - bundle exec rake codebase_index:index
    concurrency: 1
    concurrency_group: "codebase-index-update"
```

**Production (agents + CI):**

Use advisory locks (PostgreSQL `pg_advisory_lock` or MySQL `GET_LOCK`) to prevent concurrent extraction/embedding. Retrieval is always safe. See the locking implementations in AGENTIC_STRATEGY.md.

### File-System Write Safety

Extraction writes JSON files atomically by writing to a temp file and renaming:

```ruby
module CodebaseIndex
  module IO
    def self.atomic_write(path, content)
      temp_path = "#{path}.#{Process.pid}.tmp"
      File.write(temp_path, content)
      File.rename(temp_path, path)  # Atomic on POSIX
    rescue StandardError => e
      File.delete(temp_path) if File.exist?(temp_path)
      raise
    end
  end
end
```

This ensures readers never see a partially-written JSON file. They either see the old version or the new version, never a corrupt intermediate state.

### SQLite Concurrent Access

SQLite is used for the lightweight development backend. Its concurrency model is limited:

- **WAL mode** (Write-Ahead Logging) allows concurrent reads while a write is in progress
- Only one writer at a time — additional writers block (with a configurable `busy_timeout`)
- For multi-process scenarios (multiple agents in separate processes), WAL mode is required

```ruby
module CodebaseIndex
  module Storage
    class SqliteAdapter
      def initialize(db_path:)
        @db = SQLite3::Database.new(db_path)
        @db.execute("PRAGMA journal_mode=WAL")
        @db.execute("PRAGMA busy_timeout=5000")  # 5 second wait on lock contention
      end
    end
  end
end
```

For environments where multiple agents need concurrent write access, upgrade to PostgreSQL or MySQL for the metadata store. SQLite remains suitable for single-agent development use.

---

## Transitive Invalidation

When extraction produces new or updated units, the embedding layer must be notified so it can re-embed the affected content. This section designs the bridge between the extraction and embedding layers.

### The Invalidation Problem

Extraction and embedding are separate pipeline stages with different lifecycles:

```
Source code → [Extraction] → JSON units → [Embedding] → Vector store
```

When source code changes, extraction produces updated JSON. But the embedding layer doesn't know which units changed, which are new, and which were deleted. Without a bridge, the only option is a full re-embedding — expensive and unnecessary for incremental updates.

### Change Manifest

After each extraction run, the extractor writes a change manifest alongside the extracted units:

```ruby
module CodebaseIndex
  class ChangeManifest
    MANIFEST_FILE = "_change_manifest.json"

    def initialize(output_dir:)
      @output_dir = Pathname.new(output_dir)
      @changes = { added: [], modified: [], deleted: [], unchanged: [] }
    end

    def record_added(identifier, type:, content_hash:)
      @changes[:added] << { identifier: identifier, type: type, content_hash: content_hash }
    end

    def record_modified(identifier, type:, content_hash:, previous_hash:)
      @changes[:modified] << {
        identifier: identifier,
        type: type,
        content_hash: content_hash,
        previous_hash: previous_hash
      }
    end

    def record_deleted(identifier, type:)
      @changes[:deleted] << { identifier: identifier, type: type }
    end

    def record_unchanged(identifier, type:, content_hash:)
      @changes[:unchanged] << { identifier: identifier, type: type, content_hash: content_hash }
    end

    def write!
      CodebaseIndex::IO.atomic_write(
        @output_dir.join(MANIFEST_FILE).to_s,
        {
          generated_at: Time.now.iso8601,
          git_sha: current_git_sha,
          previous_git_sha: previous_manifest&.dig(:git_sha),
          summary: {
            added: @changes[:added].size,
            modified: @changes[:modified].size,
            deleted: @changes[:deleted].size,
            unchanged: @changes[:unchanged].size,
            total: @changes.values.sum(&:size)
          },
          changes: @changes
        }.to_json
      )
    end

    def units_needing_embedding
      @changes[:added] + @changes[:modified]
    end

    def units_needing_deletion
      @changes[:deleted]
    end

    private

    def current_git_sha
      stdout, _status = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)
      stdout.strip
    rescue StandardError
      "unknown"
    end

    def previous_manifest
      path = @output_dir.join(MANIFEST_FILE)
      return nil unless path.exist?

      JSON.parse(File.read(path), symbolize_names: true)
    rescue JSON::ParserError
      nil
    end
  end
end
```

### Content Hashing

The manifest uses content hashes to detect actual changes (not just timestamp changes). A unit is "modified" only if its extracted content actually differs:

```ruby
module CodebaseIndex
  class ContentHasher
    def hash_unit(unit)
      # Hash the fields that affect embedding: source code, metadata, dependencies
      content = [
        unit.identifier,
        unit.source_code,
        unit.metadata.to_json,
        unit.dependencies.sort.to_json
      ].join("\n")

      Digest::SHA256.hexdigest(content)
    end
  end
end
```

This prevents unnecessary re-embedding when extraction produces identical output (e.g., running full extraction without any code changes).

### Embedding Layer Integration

The embedding pipeline reads the change manifest to determine what work is needed:

```ruby
module CodebaseIndex
  module Embedding
    class IncrementalIndexer
      def initialize(pipeline:, output_dir:)
        @pipeline = pipeline
        @manifest = ChangeManifest.load(output_dir)
      end

      def index_changes!
        return full_reindex! if @manifest.nil?

        # Embed new and modified units
        to_embed = @manifest.units_needing_embedding
        if to_embed.any?
          identifiers = to_embed.map { |u| u[:identifier] }
          @pipeline.index_incremental(identifiers)
          CodebaseIndex.logger.info(
            "Embedded #{identifiers.size} units (#{@manifest.changes[:added].size} added, #{@manifest.changes[:modified].size} modified)"
          )
        end

        # Delete removed units from vector store
        to_delete = @manifest.units_needing_deletion
        if to_delete.any?
          identifiers = to_delete.map { |u| u[:identifier] }
          @pipeline.delete_embeddings(identifiers)
          CodebaseIndex.logger.info("Deleted embeddings for #{identifiers.size} removed units")
        end

        # Also delete chunk embeddings for modified units (they'll be re-created)
        modified_ids = @manifest.changes[:modified].map { |u| u[:identifier] }
        if modified_ids.any?
          @pipeline.delete_chunk_embeddings(modified_ids)
        end

        EmbeddingResult.new(
          embedded: to_embed.size,
          deleted: to_delete.size,
          skipped: @manifest.changes[:unchanged].size
        )
      end

      private

      def full_reindex!
        CodebaseIndex.logger.warn("No change manifest found — performing full re-index")
        @pipeline.index_all
      end
    end
  end
end
```

### Invalidation Scope

Changes can cascade. When a concern is modified, every model that includes it has effectively changed, even though the model file itself is untouched. The change manifest must account for this:

| Change Type | Direct Invalidation | Transitive Invalidation |
|-------------|-------------------|------------------------|
| Model source changed | The model itself | None (dependents read from the model's extracted output) |
| Concern source changed | The concern | All models that include the concern (concerns are inlined) |
| Schema changed (migration) | All models on affected tables | None |
| Route changes | Affected controllers | None |
| Association added/removed | Both models in the association | None |

```ruby
module CodebaseIndex
  class TransitiveInvalidator
    def initialize(dependency_graph:, concern_map:)
      @graph = dependency_graph
      @concern_map = concern_map  # { concern_name => [including_model_1, ...] }
    end

    def expand_invalidation(changed_files)
      invalidated = Set.new

      changed_files.each do |file|
        unit = identify_unit(file)
        next unless unit

        invalidated << unit[:identifier]

        # Concern change → invalidate all including models
        if unit[:type] == :concern
          includers = @concern_map[unit[:identifier]] || []
          invalidated.merge(includers)
        end

        # Schema change → invalidate all models on affected tables
        if file.match?(%r{db/migrate/})
          affected_tables = detect_affected_tables(file)
          affected_tables.each do |table|
            models = models_for_table(table)
            invalidated.merge(models)
          end
        end
      end

      invalidated.to_a
    end
  end
end
```

### Deleted Unit Handling

When a model or service is removed from the codebase, three things must happen:

1. **Extracted JSON deleted** — extraction no longer produces the unit file
2. **Vector embedding deleted** — stale embedding would produce false retrieval hits
3. **Graph edges cleaned** — dependency graph entries for the deleted unit must be removed

The change manifest's `deleted` list drives all three cleanups:

```ruby
# In the embedding pipeline
def delete_embeddings(identifiers)
  # Delete unit-level embeddings
  @vector_store.delete(identifiers)

  # Delete chunk-level embeddings
  identifiers.each do |id|
    @vector_store.delete_by_filter({ parent: id, type: "chunk" })
  end

  # Delete from metadata store
  @metadata_store.delete(identifiers)
end
```

### Event-Driven Alternative

For real-time development workflows, a file-watcher approach complements the manifest-based approach:

```ruby
module CodebaseIndex
  class FileWatcher
    WATCH_PATTERNS = %w[
      app/models/**/*.rb
      app/controllers/**/*.rb
      app/services/**/*.rb
      app/jobs/**/*.rb
      app/mailers/**/*.rb
      app/components/**/*.rb
      app/graphql/**/*.rb
    ].freeze

    def start!
      listener = Listen.to(Rails.root.to_s, only: /\.rb$/) do |modified, added, removed|
        changed = modified + added
        relevant = changed.select { |f| WATCH_PATTERNS.any? { |p| File.fnmatch?(p, f, File::FNM_PATHNAME) } }
        next if relevant.empty?

        CodebaseIndex.extract_incremental(relevant)
        # Embedding follows automatically via change manifest
        CodebaseIndex.embed_incremental
      end

      listener.start
    end
  end
end
```

This is useful in development but not recommended for production. In production, extraction should be triggered by CI (post-merge) or by agents via the operator tools described in AGENTIC_STRATEGY.md.

---

## Agent-Driven Operations

This section defines how agents trigger and monitor pipeline tasks — extraction, embedding, and validation — through the MCP tool interface. See AGENTIC_STRATEGY.md for the tool definitions; this section covers the operational implementation behind those tools.

### Agent API Surface

Agents interact with the pipeline through five operations, each mapped to an MCP tool:

| MCP Tool | Pipeline Operation | Blocking? | Typical Duration |
|----------|-------------------|-----------|-----------------|
| `extract` | Run extraction (full or incremental) | Yes (returns when complete) | 5-30s incremental, 30-120s full |
| `embed` | Run embedding pipeline | Yes (returns when complete) | 2-10s incremental, 30-300s full |
| `pipeline_status` | Read pipeline state | No | <10ms |
| `diagnose` | Run validation checks | No | 100-500ms |
| `repair` | Fix specific issues | Yes (returns when complete) | 1-30s depending on scope |

### Task Lifecycle

Every agent-triggered pipeline operation follows this lifecycle:

```
Requested → Validating → Running → Completed
                ↓                       ↓
             Rejected              Failed
```

```ruby
module CodebaseIndex
  module Operator
    class TaskRunner
      def run_extraction(mode:, extractors: nil, dry_run: false)
        # 1. Validate
        validate_extraction_request!(mode, extractors)

        # 2. Acquire lock
        lock = Coordination::PipelineLock.new
        lock.acquire!(operation: "extraction_#{mode}")

        begin
          # 3. Run
          result = if mode == "full"
            run_full_extraction(extractors: extractors, dry_run: dry_run)
          else
            run_incremental_extraction(dry_run: dry_run)
          end

          # 4. Write change manifest
          result.change_manifest.write! unless dry_run

          # 5. Return structured result
          {
            status: "completed",
            mode: mode,
            units_extracted: result.units.size,
            units_changed: result.changed_count,
            duration_seconds: result.duration,
            git_sha: result.git_sha,
            dry_run: dry_run,
            change_summary: result.change_manifest&.summary
          }
        rescue StandardError => e
          {
            status: "failed",
            mode: mode,
            error: e.message,
            error_class: e.class.name,
            duration_seconds: elapsed_time
          }
        ensure
          lock.release!
        end
      end

      def run_embedding(mode:, identifiers: nil)
        validate_embedding_request!(mode, identifiers)

        lock = Coordination::PipelineLock.new
        lock.acquire!(operation: "embedding_#{mode}")

        begin
          result = if mode == "full"
            @embedding_pipeline.index_all
          else
            indexer = Embedding::IncrementalIndexer.new(
              pipeline: @embedding_pipeline,
              output_dir: @config.output_dir
            )
            indexer.index_changes!
          end

          {
            status: "completed",
            mode: mode,
            units_embedded: result.embedded,
            units_deleted: result.deleted,
            units_skipped: result.skipped,
            duration_seconds: result.duration,
            retry_queue_size: @embedding_pipeline.retry_queue_size
          }
        rescue StandardError => e
          {
            status: "failed",
            mode: mode,
            error: e.message,
            error_class: e.class.name
          }
        ensure
          lock.release!
        end
      end

      private

      def validate_extraction_request!(mode, extractors)
        PipelineGuard.new.allow_extraction?(mode)

        if extractors
          unknown = extractors - CodebaseIndex.configuration.available_extractors.map(&:to_s)
          raise ArgumentError, "Unknown extractors: #{unknown.join(', ')}" if unknown.any?
        end
      end

      def validate_embedding_request!(mode, identifiers)
        if mode == "incremental" && identifiers.nil?
          # Incremental without identifiers uses change manifest — valid
        end

        if mode == "full"
          PipelineGuard.new.allow_extraction?("full")  # Same cooldown applies
        end
      end
    end
  end
end
```

### Status Reporting

The `pipeline_status` tool returns a snapshot of the current pipeline state without triggering any operations. It reads from the manifest and component health checks:

```ruby
module CodebaseIndex
  module Operator
    class StatusReporter
      def report
        manifest = load_manifest
        health = HealthCheck.new(@config).check

        {
          extraction: extraction_status(manifest),
          embedding: embedding_status,
          index: index_status(manifest),
          health: health[:components].transform_values { |c| c[:status] }
        }
      end

      private

      def extraction_status(manifest)
        return { status: "never_run" } unless manifest

        {
          last_run: manifest[:generated_at],
          mode: manifest[:mode] || "unknown",
          git_sha: manifest[:git_sha],
          units_total: manifest.dig(:summary, :total) || 0,
          units_changed: (manifest.dig(:summary, :added) || 0) +
                         (manifest.dig(:summary, :modified) || 0),
          status: "completed"
        }
      end

      def embedding_status
        {
          units_embedded: @config.build_vector_store.count,
          retry_queue_size: retry_queue_size,
          status: retry_queue_size > 0 ? "has_pending_retries" : "completed"
        }
      rescue StandardError => e
        { status: "error", error: e.message }
      end

      def index_status(manifest)
        current_sha = current_git_sha
        manifest_sha = manifest&.dig(:git_sha)

        staleness = if manifest_sha.nil?
          "never_indexed"
        elsif manifest_sha == current_sha
          "current"
        else
          commits_behind = count_commits_between(manifest_sha, current_sha)
          "#{commits_behind}_commits_behind"
        end

        {
          total_units: count_extracted_units,
          manifest_git_sha: manifest_sha,
          current_git_sha: current_sha,
          staleness: staleness,
          schema_version: SchemaVersion.current
        }
      end

      def count_commits_between(from_sha, to_sha)
        stdout, _status = Open3.capture2(
          "git", "rev-list", "--count", "#{from_sha}..#{to_sha}",
          chdir: Rails.root.to_s
        )
        stdout.strip.to_i
      rescue StandardError
        -1  # Unknown
      end
    end
  end
end
```

### Error Escalation

Not all errors can be resolved by an agent. The escalation model defines when an agent should retry, when it should try a different approach, and when it should alert a human:

| Error Type | Agent Action | Escalation |
|------------|-------------|------------|
| Lock contention | Wait and retry (up to 3 times with backoff) | After 3 retries, report to human |
| Extraction error (single unit) | Skip unit, continue extraction | Log warning, include in result |
| Extraction error (eager_load! fails) | Fall back to per-directory loading | Log warning, may miss some classes |
| Embedding rate limit | Backoff and retry (built-in via RetryableProvider) | After exhausting retries, queue for later |
| Embedding API unreachable | Skip embedding, extraction still valid | Report to human, retrieval degrades to Tier 2 |
| Vector store unreachable | Cannot embed — report status | Report to human, suggest checking infrastructure |
| Schema mismatch | Cannot proceed — requires migration | Report to human with exact migration command |
| Dimension mismatch | Cannot embed — requires full re-index | Report to human with rake task command |

```ruby
module CodebaseIndex
  module Operator
    class ErrorEscalator
      RETRYABLE_ERRORS = [
        LockContention,
        RateLimitError,
        Timeout::Error
      ].freeze

      HUMAN_ESCALATION_ERRORS = [
        DimensionMismatch,
        SchemaVersionMismatch,
        CircuitOpenError
      ].freeze

      def classify(error)
        case error
        when *RETRYABLE_ERRORS
          {
            action: :retry,
            message: "Temporary error (#{error.class.name}): #{error.message}",
            max_retries: 3,
            backoff: :exponential
          }
        when *HUMAN_ESCALATION_ERRORS
          {
            action: :escalate,
            message: "Requires human intervention: #{error.message}",
            severity: :high,
            suggested_action: suggest_human_action(error)
          }
        when ExtractionError
          {
            action: :skip_and_continue,
            message: "Extraction error for single unit: #{error.message}",
            severity: :low
          }
        else
          {
            action: :escalate,
            message: "Unexpected error: #{error.class.name}: #{error.message}",
            severity: :medium,
            suggested_action: "Check logs and retry manually"
          }
        end
      end

      private

      def suggest_human_action(error)
        case error
        when DimensionMismatch
          "Embedding dimensions changed. Run: bundle exec rake codebase_index:reindex"
        when SchemaVersionMismatch
          "Schema needs migration. Run: bundle exec rake codebase_index:db:migrate"
        when CircuitOpenError
          "Backend service (#{error.service_name}) is down. Check infrastructure and retry."
        end
      end
    end
  end
end
```

### Agent Operational Workflow

A complete agent workflow for maintaining an up-to-date index:

```
1. Agent starts a coding task
2. codebase_pipeline_status()
   → staleness: "5_commits_behind"
3. Agent decides to update the index first:
   codebase_extract(mode: "incremental")
   → Result: 12 units changed, 3 added, 1 deleted
4. codebase_embed(mode: "incremental")
   → Result: 15 units embedded, 1 deleted, 1232 skipped
5. Now proceed with retrieval:
   codebase_retrieve("checkout flow")
   → Returns current, accurate context
6. After making code changes:
   codebase_extract(mode: "incremental")
   → Updates index to reflect the agent's own changes
7. Verify:
   codebase_diagnose()
   → All checks pass
```

This self-service loop means the agent never works with stale context and can maintain the index as part of its normal workflow.
