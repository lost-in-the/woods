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

### PageRank importance

When a graph store supplies PageRank, ranking converts its scores to ordinal
percentiles: the highest-ranked unit receives 1.0 and the lowest receives 1/n,
where n is the number of entries in the PageRank map.
Equal PageRank scores are ordered lexically by identifier before assigning
percentiles. This preserves distinct ordinal weights while making ties independent
of graph insertion order and Ruby version. It does not assign equal importance
weights to tied units. Missing graph entries retain the metadata-based fallback.

### Search strategies

`SearchExecutor` selects one of five strategies based on query classification:

| Strategy | When selected | What it does |
|----------|--------------|-------------|
| `:vector` | `understand`, `debug`, `implement` intents | Embeds query, searches vector store by cosine similarity |
| `:keyword` | `locate`, `reference` intents; `framework` queries | Searches metadata store by extracted keywords |
| `:graph` | `trace` intent | Finds seed identifiers, then walks forward and reverse dependency edges |
| `:hybrid` | `comprehensive` or `exploratory` scope | Runs vector + keyword + graph expansion, deduplicates |
| `:direct` | `locate`/`reference` + `pinpoint` scope | Looks up identifiers directly in metadata store; falls back to keyword |

Graph queries preserve identifier spelling and namespaces: `trace Billing::Invoice`,
`trace ReviewAssignment`, and `trace review_assignment` resolve the subject before
traversing its dependencies and dependents. An exact identifier takes precedence;
an unqualified name without an exact match can seed up to three namespace matches
in storage-identifier order. Use the qualified name to disambiguate. A missing
qualified identifier does not fall back to a different namespace. For unqualified
prose, metadata fallback searches subject terms without instructions such as
`trace`, `follow`, or `who calls`.

Keyword results are scored by how many distinct fields matched (identifier, source, metadata), not by the store's result order. Each matched field adds 0.25, capped at 1.0, so a result matching on identifier and source scores higher than one matching source alone.

---

## Configuring Retrieval

Retrieval requires an embedding provider and a vector store. Set these in `config/initializers/woods.rb`.

### Presets (recommended)

Four named presets cover the supported deployment scenarios:

```ruby
# Local development: in-memory vectors + SQLite metadata + Ollama.
# Requires sqlite3, a running Ollama service, and a pulled embedding model.
Woods.configure_with_preset(:local)

# Separate embed/query processes sharing output_dir. No sqlite3 gem.
# Requires a running Ollama service and a filesystem visible to both processes.
Woods.configure_with_preset(:shared_filesystem)

# PostgreSQL: pgvector + SQLite metadata + OpenAI.
# Requires pgvector, sqlite3, and an OpenAI API key.
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end

# Production: Qdrant + SQLite metadata + OpenAI.
# Requires Qdrant, sqlite3, and an OpenAI API key.
Woods.configure_with_preset(:production) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # only when QDRANT_URL is deliberately private
  }
end
```

Presets accept a block for overrides:

```ruby
Woods.configure_with_preset(:local) { |config| config.max_context_tokens = 12_000 }
```

### Manual configuration

**MySQL host app (Qdrant required. MySQL has no native vector extension):**

```ruby
Woods.configure do |config|
  config.vector_store         = :qdrant
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: 'myapp',
    allow_private_hosts: true # required for trusted localhost/RFC1918 URLs
  }
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

## Embedding-free lexical retrieval

Opt into ranked retrieval over an extract-only published index:

```bash
WOODS_RETRIEVAL_MODE=lexical bundle exec woods-mcp-start ./tmp/woods
```

For a Ruby-built retriever, set `config.retrieval_mode = :lexical` and supply a
populated metadata store to `Builder#build_retriever`. The packaged MCP server
loads published unit JSON itself; it does not boot Rails or read current source
files. Neither path constructs an embedding provider or vector adapter. The
existing `:semantic` mode remains the default; provider failures never switch
modes automatically. A Rails initializer is not loaded by the standalone MCP
process, so set the environment variable in that process's client configuration.

Lexical results use field-aware BM25 scoring over identifiers, source paths,
published source and selected runtime metadata (including callbacks, associations
and validations). Exact full identifiers rank first, with ambiguous typed owners
retained. Other ties are deterministic. Responses name the lexical mode and
matching fields/terms; runtime-field hits include the selected published runtime
values. Lexical Ruby results leave the semantic-only `type_rank_context` table
`nil`; they do not report a global vector rank or vector fallback. The top 20 eligible positive matches are considered for the
output budget; this is ranked discovery, not an exhaustive match listing. Explicit
`types` filters override default exclusions, as in semantic retrieval, and apply
before that limit. A query with no lexical evidence returns no matches; unrelated
graph hubs are never added. Query-seeded graph ranking is evaluation-only.

The budget covers headers, matching explanations and truncation notices using a
labelled character-based estimate, not an exact provider tokenizer. Full source
remains available through `lookup`. Very small budgets can omit all sources. The
reader pins one published generation for building and querying its immutable
lexical snapshot, rebuilding after publication. Corrupt units fail explicitly;
they cannot quietly become a successful partial index. Older flat indexes rebuild
on each query because they lack an immutable generation identity.

See [evaluation](EVALUATION.md) for measured query coverage and limits. Lexical
matching cannot infer synonyms absent from the published text; a miss is not proof
that application behavior is absent. Static Woods self-maps can opt into the same
mode but remain static source maps, not resolved Rails runtime evidence.

---

## Running Retrieval

### MCP tool: `codebase_retrieve`

The primary interface for agents. Available with explicit lexical mode over extraction output, or with an embedding provider and completed `rake woods:embed` in the default semantic mode.

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

`result.tokens_used` and `result.trace.tokens_used` count the final returned
`context`, including the optional formatter output and type-rank table. Counting
uses the same injected token counter or chars-per-token estimate as assembly;
it does not guarantee an exact count for the downstream model. `budget` limits
context assembly, so postprocessing can make the final count exceed it.

Override the token budget per call:

```ruby
result = retriever.retrieve("explain the checkout flow", budget: 16_000)
```

`Woods.build_retriever` instantiates a retriever from the current configuration:

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end
retriever = Woods.build_retriever
result    = retriever.retrieve("what validations does Order have?")
```

---

## Degradation Tiers

Retrieval degrades gracefully when components are unavailable. The Retriever itself does not implement explicit fallback tiers, degradation happens naturally through how each component handles errors:

- **Embedding provider unavailable**: `codebase_retrieve` returns a structured configuration error. Check `woods_status` for retrieval readiness.
- **Vector store unavailable**: vector and hybrid strategies fail at query time. Keyword and graph strategies remain available for direct calls to `SearchExecutor`.
- **Metadata store error**: the structural context overview (unit counts by type) is silently omitted; `Retriever#build_structural_context` rescues `StandardError` and returns `nil`. The retrieval result is still returned without the overview.
- **Graph store unavailable**: graph expansion in hybrid strategy produces no graph candidates; vector and keyword candidates are still ranked and returned.

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

The `ContextAssembler` carves off 10% for the structural overview first, then splits what's left:

- **Framework context active** (the query mentions Rails/framework keywords, `rails`, `activerecord`, `middleware`, etc.): primary 55%, supporting 25%, framework 20%.
- **No framework context**: primary 65%, supporting 35%, the framework section gets nothing, and its share is not proportionally folded into the other two; the fractions are just different, not rescaled.

Separately, if the supporting section ends up with no candidates (it only ever holds `:graph_expansion` results), its reserved budget is reclaimed into primary rather than wasted.

### `context_format`

Controls how assembled units are formatted. Default: `:markdown`. Valid values: `:claude`, `:markdown`, `:plain`, `:json`.

```ruby
config.context_format = :claude # XML-wrapped output for Claude-style context
config.context_format = :json   # Machine-readable output
```

### Switching embedding models

The embedding model must match between `rake woods:embed` and retrieval. Different models produce vectors with different dimensionalities. Woods raises `Woods::MCP::DimensionMismatch` when they disagree, at embed time for durable stores and at MCP boot for dumps. After changing `embedding_model`, drop the vector store and re-run full extraction and embedding:

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
| `codebase_retrieve` tool listed but disabled | Embedding provider not configured or API key missing | Set `embedding_provider`, run `woods:embed`, and check `woods_status` |
| Results clustered around one type | Diversity penalty insufficient for codebase shape | Lower `similarity_threshold` slightly and widen the query scope |
