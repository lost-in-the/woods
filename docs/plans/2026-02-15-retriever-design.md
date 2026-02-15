# Retriever, Formatting, Production Hardening & Observability

**Status:** Design approved, ready for implementation
**Date:** 2026-02-15
**Scope:** Tiers 1 + 2 — glue layers (Retriever, formatting, MCP semantic search, OpenAI adapter, rake tasks) + production hardening (error handling, observability, pgvector, Qdrant)

---

## Problem

The storage, embedding, and retrieval components exist as individual classes (QueryClassifier, SearchExecutor, Ranker, ContextAssembler, VectorStore, MetadataStore, GraphStore, EmbeddingProvider) but nothing ties them together into a usable system. There is no top-level `retrieve(query)` call, no context formatting for different LLMs, no production error handling, no observability, and no production-grade vector store adapters.

## Solution

15 new files + 2 extended files across 5 areas:

1. **Retriever orchestrator** — single entry point: `classify → search → rank → assemble`
2. **Context formatting** — LLM-specific output adapters (Claude XML, GPT Markdown, Generic, Human)
3. **MCP + embedding** — semantic search tool, OpenAI adapter, rake tasks
4. **Resilience** — CircuitBreaker, RetryableProvider, IndexValidator, degradation tiers
5. **Infrastructure** — Pgvector adapter, Qdrant adapter, Instrumentation, StructuredLogger, HealthCheck

---

## Architecture

### Retriever Orchestrator

`lib/codebase_index/retriever.rb`

Top-level entry point that wires all retrieval components together.

```ruby
retriever = CodebaseIndex::Retriever.new(
  vector_store: store,
  metadata_store: meta,
  graph_store: graph,
  embedding_provider: provider,
  formatter: Formatting::ClaudeAdapter.new  # optional
)
result = retriever.retrieve("How does User model handle validation?")
result.context          # formatted string
result.sources          # attribution array
result.classification   # QueryClassifier::Classification
result.strategy         # :hybrid
```

Internal flow: `classify → execute → rank → assemble → format`

Includes `RetrievalResult` struct and `StructuralContextBuilder` (generates codebase overview from metadata store for the 10% structural token budget).

~250 lines including result struct and structural builder.

### Context Formatting Adapters

`lib/codebase_index/formatting/`

All implement `format(assembled_context) → String`.

| Adapter | File | Format | Use case |
|---------|------|--------|----------|
| Base | `base.rb` | Interface + shared helpers | Abstract base |
| ClaudeAdapter | `claude_adapter.rb` | XML tags (`<unit>`, `<source>`) | Claude API/MCP |
| GPTAdapter | `gpt_adapter.rb` | Markdown headers + fenced code | OpenAI API |
| GenericAdapter | `generic_adapter.rb` | Plain text with separators | Any LLM |
| HumanAdapter | `human_adapter.rb` | Box-drawing, section headers | CLI/terminal |

~350 lines total across 5 files.

### OpenAI Embedding Adapter

`lib/codebase_index/embedding/openai.rb`

Follows existing Ollama pattern. Same `Provider::Interface` contract.

```ruby
provider = CodebaseIndex::Embedding::Provider::OpenAI.new(
  api_key: ENV['OPENAI_API_KEY'],
  model: 'text-embedding-3-small'  # default, 1536 dimensions
)
```

Uses `net/http` — no new gem dependencies. Supports `text-embedding-3-small` (1536d) and `text-embedding-3-large` (3072d).

~120 lines.

### MCP Semantic Search Tool

Extends `lib/codebase_index/mcp/server.rb` with `codebase_retrieve` tool.

```
Input:  { query: "How does User handle auth?", budget: 4000 }
Output: formatted context + source attributions
```

Requires a configured Retriever instance. Falls back to keyword-only retrieval when no embedding provider is configured. ~70 lines.

### Retrieval Rake Tasks

Extends `lib/tasks/codebase_index.rake`:

- `codebase_index:retrieve[query]` — CLI retrieval for testing
- `codebase_index:embed` — full embedding pipeline
- `codebase_index:embed_incremental` — content_hash-based incremental

~60 lines.

### CircuitBreaker

`lib/codebase_index/resilience/circuit_breaker.rb`

Protects external service calls (embedding providers, vector stores).

```ruby
breaker = CircuitBreaker.new(threshold: 5, reset_timeout: 60)
breaker.call { provider.embed(text) }
```

States: `:closed` (normal) → `:open` (failing, raises `CircuitOpenError`) → `:half_open` (allows one test request after timeout).

~100 lines.

### RetryableProvider

`lib/codebase_index/resilience/retryable_provider.rb`

Wraps any `Embedding::Provider::Interface` with exponential backoff + circuit breaker.

```ruby
provider = RetryableProvider.new(
  provider: openai_provider,
  max_retries: 3,
  circuit_breaker: breaker
)
```

Delegates all Interface methods. Retries on transient errors (network, rate limit). Respects circuit breaker state.

~80 lines.

### Degradation Tiers

Built into `Retriever`, not a separate class. When components fail, the Retriever catches `CircuitOpenError` and falls through:

1. Full retrieval (vector + keyword + graph)
2. Keyword + graph (vector store down)
3. Graph only (metadata store down)
4. Direct file lookup (graph store down)
5. Empty result with error metadata

~40 lines added to retriever.rb.

### IndexValidator

`lib/codebase_index/resilience/index_validator.rb`

Checks extraction output health.

```ruby
validator = IndexValidator.new(index_dir: "/path/to/output")
report = validator.validate
report.valid?     # => true/false
report.warnings   # => ["3 units missing source_hash", ...]
report.errors     # => ["_index.json references nonexistent file: ..."]
```

Checks: file existence, content hash integrity, index consistency, stale detection.

~120 lines.

### Pgvector Vector Store Adapter

`lib/codebase_index/storage/pgvector.rb`

Production vector store for PostgreSQL teams.

```ruby
store = Storage::VectorStore::Pgvector.new(
  connection: ActiveRecord::Base.connection,
  dimensions: 1536
)
```

Same `VectorStore::Interface` as InMemory. Uses HNSW index. Parameterized queries only (no SQL injection). Filter translation to `WHERE` clauses. Schema setup via `ensure_schema!`. Depends on `pg` gem (already a Rails dependency).

~170 lines.

### Qdrant Vector Store Adapter

`lib/codebase_index/storage/qdrant.rb`

Production vector store for Docker/MySQL stacks.

```ruby
store = Storage::VectorStore::Qdrant.new(
  url: "http://localhost:6333",
  collection: "codebase_index"
)
```

HTTP API via `net/http`. Filter translation to Qdrant's JSON filter format. Collection auto-creation. No new gem dependencies.

~120 lines.

### Instrumentation

`lib/codebase_index/observability/instrumentation.rb`

Thin wrapper around `ActiveSupport::Notifications`.

```ruby
CodebaseIndex::Observability.instrument("codebase_index.retrieve", query: q) do
  retriever.retrieve(q)
end
```

Falls back to direct yield when ActiveSupport isn't available (MCP server runs without Rails).

~60 lines.

### StructuredLogger

`lib/codebase_index/observability/structured_logger.rb`

JSON-line logger for pipeline operations.

```ruby
logger = StructuredLogger.new(output: $stderr)
logger.info("extraction.complete", units: 142, duration_ms: 3200)
# => {"timestamp":"...","level":"info","event":"extraction.complete","units":142,"duration_ms":3200}
```

~70 lines.

### HealthCheck

`lib/codebase_index/observability/health_check.rb`

Reports system component status.

```ruby
check = HealthCheck.new(vector_store: vs, metadata_store: ms, embedding_provider: ep)
status = check.run
status.healthy?    # => true
status.components  # => { vector_store: :ok, metadata_store: :ok, embedding: :degraded }
```

~80 lines.

---

## Team Structure

### 5 Agents + Lead

| Agent | Worktree | Owned Files | Phase |
|-------|----------|-------------|-------|
| **retriever-agent** | `rails-tokenizer-retriever` | `retriever.rb`, `spec/retriever_spec.rb` | 1 |
| **formatting-agent** | `rails-tokenizer-formatting` | `formatting/*.rb`, `spec/formatting/*_spec.rb` | 1 |
| **infra-agent** | `rails-tokenizer-infra` | `storage/pgvector.rb`, `storage/qdrant.rb`, `observability/*.rb` + specs | 1 |
| **resilience-agent** | `rails-tokenizer-resilience` | `resilience/*.rb` + specs, extends `retriever.rb` (degradation) | 2 |
| **mcp-agent** | `rails-tokenizer-mcp` | `embedding/openai.rb`, extends `mcp/server.rb`, extends `codebase_index.rake` + specs | 2 |

All agents: `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`.

### Phase Flow

```
Phase 1 (all parallel, no dependencies):
  retriever-agent:   Retriever + RetrievalResult + StructuralContextBuilder
  formatting-agent:  Base + ClaudeAdapter + GPTAdapter + GenericAdapter + HumanAdapter
  infra-agent:       Pgvector + Qdrant + Instrumentation + StructuredLogger + HealthCheck

Phase 2 (after retriever-agent merges to main):
  resilience-agent:  CircuitBreaker + RetryableProvider + IndexValidator + degradation
  mcp-agent:         OpenAI adapter + codebase_retrieve MCP tool + rake tasks

Phase 3 (lead):
  Merge all worktrees back to main
  Run full test suite
  Update docs/backlog.json
  Update docs/README.md status table
```

### File Ownership — No Conflicts

Each agent has exclusive file ownership. Shared files (`codebase_index.rake`, `mcp/server.rb`, `retriever.rb`) are only touched by one agent each. The resilience-agent extends `retriever.rb` after the retriever-agent's worktree is merged.

---

## Backlog Items (B-038 through B-052)

| ID | Title | Agent | Phase | Deps |
|----|-------|-------|-------|------|
| B-038 | Retriever orchestrator | retriever | 1 | — |
| B-039 | StructuralContextBuilder | retriever | 1 | — |
| B-040 | Context formatting base + ClaudeAdapter | formatting | 1 | — |
| B-041 | GPTAdapter + GenericAdapter + HumanAdapter | formatting | 1 | B-040 |
| B-042 | Pgvector vector store adapter | infra | 1 | — |
| B-043 | Qdrant vector store adapter | infra | 1 | — |
| B-044 | Instrumentation module | infra | 1 | — |
| B-045 | StructuredLogger | infra | 1 | — |
| B-046 | HealthCheck | infra | 1 | — |
| B-047 | CircuitBreaker | resilience | 2 | B-038 |
| B-048 | RetryableProvider | resilience | 2 | B-047 |
| B-049 | IndexValidator | resilience | 2 | — |
| B-050 | OpenAI embedding adapter | mcp | 2 | — |
| B-051 | MCP codebase_retrieve tool | mcp | 2 | B-038 |
| B-052 | Retrieval + embedding rake tasks | mcp | 2 | B-038 |

---

## Key References

| Resource | Used By |
|----------|---------|
| `docs/RETRIEVAL_ARCHITECTURE.md` | All agents — interface specs, pseudocode |
| `docs/CONTEXT_AND_CHUNKING.md` | formatting-agent — format specs per LLM |
| `docs/OPERATIONS.md` | resilience-agent, infra-agent — error handling, observability design |
| `lib/codebase_index/retrieval/*.rb` | retriever-agent — existing components to orchestrate |
| `lib/codebase_index/storage/vector_store.rb` | infra-agent — Interface to implement |
| `lib/codebase_index/embedding/provider.rb` | mcp-agent — Interface + Ollama pattern to follow |
| `lib/codebase_index/mcp/server.rb` | mcp-agent — existing tool registration pattern |
| `spec/support/shared_extractor_context.rb` | All agents — test helpers |

---

## Estimated Scope

~1,700 lines of implementation + ~1,200 lines of specs across 15 new files and 2 extended files.

## Risks

- **Pgvector adapter** needs a running PostgreSQL instance for integration testing. Gem-level specs will use mocks; real testing happens in host app.
- **Qdrant adapter** needs a running Qdrant instance. Same approach — mocks for gem specs.
- **Resilience-agent extends retriever.rb** after retriever-agent's work merges. Must rebase cleanly.
- **MCP server extension** adds a tool that depends on Retriever. When Retriever is unavailable (no embedding configured), the tool must degrade gracefully to keyword search.
