# Retrieval Guide

Woods retrieval combines semantic search (vector similarity), keyword search (identifier/text matching), and graph traversal (dependency edges), fusing results with Reciprocal Rank Fusion (RRF) before assembling them into a token-budgeted context string. This is distinct from `search` (exact name/pattern lookup) or `lookup` (direct identifier fetch): retrieval is designed for natural-language questions about behavior, relationships, or concepts that span multiple code units.

---

## The Pipeline at a Glance

```
query
  └─▶ QueryClassifier        classify intent, scope, target type
        └─▶ SearchExecutor   select strategy, run parallel search
              ├── vector search     (semantic similarity)
              ├── keyword search    (identifier/text matching)
              └── graph traversal  (dependency edges)
                └─▶ Ranker         RRF fusion + weighted signal scoring
                      └─▶ ContextAssembler  token-budgeted context string
                            └─▶ RetrievalResult
```

| Stage | Class | Responsibility |
|-------|-------|----------------|
| Classification | `Woods::Retrieval::QueryClassifier` | Detects intent, scope, target type, and framework context from the query text |
| Search | `Woods::Retrieval::SearchExecutor` | Maps classification to a strategy (`:vector`, `:keyword`, `:graph`, `:hybrid`, `:direct`) and executes it |
| Ranking | `Woods::Retrieval::Ranker` | Applies RRF across sources, then weighted signal scoring (semantic, keyword, recency, importance, type match, diversity) |
| Assembly | `Woods::Retrieval::ContextAssembler` | Fills a token budget with ranked units, sectioned into structural / primary / supporting / framework blocks |
| Orchestration | `Woods::Retriever` | Coordinates all four stages; returns a `RetrievalResult` with `context`, `sources`, `strategy`, `tokens_used`, and `trace` |

### Search strategies

`SearchExecutor` selects one of five strategies based on query classification:

| Strategy | When selected | What it does |
|----------|--------------|-------------|
| `:vector` | `understand`, `debug`, `implement` intents | Embeds query, searches vector store by cosine similarity |
| `:keyword` | `locate`, `reference` intents; `framework` queries | Searches metadata store by extracted keywords |
| `:graph` | `trace` intent | Finds seed identifiers, then walks forward and reverse dependency edges |
| `:hybrid` | `comprehensive` or `exploratory` scope | Runs vector + keyword + graph expansion, deduplicates |
| `:direct` | `locate`/`reference` + `pinpoint` scope | Looks up identifiers directly in metadata store; falls back to keyword |

---

## Configuring Retrieval

Retrieval requires an embedding provider and a vector store. Set these in `config/initializers/woods.rb`.

### Presets (recommended)

Three named presets cover the most common deployment scenarios:

```ruby
# Local development — Ollama (local) + in-memory vector store. No external services.
Woods.configure_with_preset(:local)

# PostgreSQL — pgvector + OpenAI. Requires PostgreSQL with the vector extension.
Woods.configure_with_preset(:postgresql)

# Production — Qdrant + OpenAI. Dedicated vector database.
Woods.configure_with_preset(:production)
```

Presets accept a block for overrides:

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options  = { api_key: ENV['OPENAI_API_KEY'] }
  config.max_context_tokens = 12_000
end
```

### Manual configuration

**MySQL host app (Qdrant required — MySQL has no native vector extension):**

```ruby
Woods.configure do |config|
  config.vector_store         = :qdrant
  config.vector_store_options = { url: ENV['QDRANT_URL'], collection: 'myapp' }
  config.metadata_store       = :sqlite
  config.embedding_provider   = :openai
  config.embedding_options    = { api_key: ENV['OPENAI_API_KEY'] }
  config.embedding_model      = 'text-embedding-3-small'
end
```

**PostgreSQL host app (pgvector, all-in-one):**

```ruby
Woods.configure do |config|
  config.vector_store         = :pgvector
  # pgvector takes a live PostgreSQL connection object, not a URL.
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
  config.metadata_store       = :sqlite
  config.embedding_provider   = :openai
  config.embedding_options    = { api_key: ENV['OPENAI_API_KEY'] }
  config.embedding_model      = 'text-embedding-3-small'
end
```

After configuring, generate embeddings before running retrieval:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

---

## Running Retrieval

### MCP tool: `codebase_retrieve`

The primary interface for agents. Available in the Index Server when an embedding provider is configured and `rake woods:embed` has been run.

```
codebase_retrieve(query: "how does billing work?")
codebase_retrieve(query: "what callbacks run when an order is placed?", budget: 12000)
```

Parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | string | required | Natural-language question |
| `budget` | integer | 8000 | Token budget for context assembly |

The tool returns a formatted context string ready for use in a prompt, along with source attributions. Use `search` for exact name/pattern lookups; use `codebase_retrieve` for conceptual or behavioral questions.

### Ruby API

```ruby
retriever = Woods::Retriever.new(
  vector_store:       vector_store,
  metadata_store:     metadata_store,
  graph_store:        graph_store,
  embedding_provider: embedding_provider
)

result = retriever.retrieve("How does the User model work?")

result.context      # => "Codebase: 42 units...\n\n---\n\n## User (model)\n..."
result.strategy     # => :hybrid
result.tokens_used  # => 4200
result.sources      # => [{ identifier: "User", type: "model", score: 0.91, ... }]
result.trace        # => RetrievalTrace with elapsed_ms, candidate_count, etc.
```

Override the token budget per call:

```ruby
result = retriever.retrieve("explain the checkout flow", budget: 16_000)
```

`Woods.build_retriever` instantiates a retriever from the current configuration:

```ruby
Woods.configure_with_preset(:postgresql) { |c| c.embedding_options = { api_key: ENV['OPENAI_API_KEY'] } }
retriever = Woods.build_retriever
result    = retriever.retrieve("what validations does Order have?")
```

---

## Degradation Tiers

Retrieval degrades gracefully when components are unavailable. The Retriever itself does not implement explicit fallback tiers — degradation happens naturally through how each component handles errors:

- **Embedding provider unavailable** — `codebase_retrieve` returns no results. The MCP tool description notes this condition. Check `pipeline_status` to confirm embeddings exist.
- **Vector store unavailable** — vector and hybrid strategies fail at query time. Keyword and graph strategies remain available for direct calls to `SearchExecutor`.
- **Metadata store error** — the structural context overview (unit counts by type) is silently omitted; `Retriever#build_structural_context` rescues `StandardError` and returns `nil`. The retrieval result is still returned without the overview.
- **Graph store unavailable** — graph expansion in hybrid strategy produces no graph candidates; vector and keyword candidates are still ranked and returned.

In all cases, errors in individual components produce empty candidate sets for that source rather than raising through the `Retriever`. Configure circuit breakers via `Woods::Resilience::CircuitBreaker` on external providers (Qdrant, OpenAI) for production deployments.

---

## Tuning

### `similarity_threshold`

Controls which vector search results are considered. Range: `0.0`–`1.0`. Default: `0.7`.

```ruby
config.similarity_threshold = 0.6  # Include less similar results (broader)
config.similarity_threshold = 0.8  # Require higher similarity (narrower)
```

Lower values return more candidates, which can improve recall for broad queries at the cost of precision. Raise it if results seem loosely related.

### `max_context_tokens`

Sets the default token budget for context assembly. Default: `8000`. The `budget` parameter on `codebase_retrieve` and `Retriever#retrieve` overrides this per call.

```ruby
config.max_context_tokens = 12_000  # More context per retrieval
```

The `ContextAssembler` allocates budget across sections: structural (10%), primary (50%), supporting (25%), framework (15%). When the query has no framework context, the framework allocation is redistributed proportionally to primary and supporting.

### `context_format`

Controls how assembled units are formatted. Default: `:markdown`. Valid values: `:markdown`, `:xml`, `:plain`.

```ruby
config.context_format = :xml  # For GPT-family prompts that prefer XML structure
```

### Switching embedding models

The embedding model must match between `rake woods:embed` and retrieval. Different models produce vectors with different dimensionalities — Woods raises `Woods::MCP::DimensionMismatch` when they disagree, at embed time for durable stores and at MCP boot for dumps. After changing `embedding_model`, drop the vector store and re-run full extraction and embedding:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

**OpenAI model dimensions:**

| Model | Dimensions |
|-------|-----------|
| `text-embedding-3-small` (default) | 1536 |
| `text-embedding-3-large` | 3072 |

**Ollama default model:** `nomic-embed-text`. Dimensions are detected dynamically on first embed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `codebase_retrieve` returns no results | Embeddings not generated, or embedding provider not configured | Run `rake woods:embed`; verify `embedding_provider` is set and API key is valid |
| Results are stale or missing recent changes | Index not updated after code changes | Run `rake woods:incremental` (or `rake woods:extract` for route/event changes) |
| Dimension mismatch warning in logs | `embedding_model` changed after embedding was generated | Re-run `rake woods:extract && rake woods:embed` with the new model |
| Empty results for a known class name | Keyword strategy not finding the identifier | Try a conceptual query with `codebase_retrieve`; or use `search` for exact name lookup |
| Very slow retrieval | Large vector index without HNSW index, or Qdrant cold start | For pgvector: create an HNSW index (see `BACKEND_MATRIX.md`). For Qdrant: check collection status |
| `codebase_retrieve` tool listed but disabled | Embedding provider not configured or API key missing | Set `embedding_provider` and check `pipeline_status` for embedding availability |
| Results clustered around one type | Diversity penalty insufficient for codebase shape | Lower `similarity_threshold` slightly and widen the query scope |
