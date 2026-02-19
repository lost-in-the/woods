# CodebaseIndex: Proposal & Deep Plan

## Executive Summary

CodebaseIndex is a framework-aware extraction and retrieval system for Rails applications. It uses runtime introspection—not static parsing—to produce semantically rich, version-accurate representations of a codebase that can be consumed by LLMs, agentic coding tools, analytics pipelines, and human developers.

The extraction layer is complete. This document proposes the retrieval, embedding, storage, and integration layers needed to make extracted data useful across multiple consumption patterns.

The system is designed to be **backend-agnostic**: any vector store, any database, any embedding provider, any background job system. A team running PostgreSQL + Solid Queue + pgvector should be as well-served as one running MySQL + Sidekiq + Qdrant.

---

## Problem Statement

### What Exists Today

AI coding tools (Copilot, Cursor, Claude Code, etc.) interact with codebases through one of two modes:

1. **File-level context** — The tool reads individual files. It sees `app/models/order.rb` but not the inlined concerns, the callback chain, the schema, or the 14 services that depend on it.

2. **Whole-repo ingestion** — The tool indexes everything. Context windows fill with irrelevant code. Retrieval quality degrades with scale.

Both modes share a deeper problem: they treat code as text. A Rails codebase isn't text — it's a runtime system with conventions, metaprogramming, implicit behavior, and version-specific semantics that only exist at boot time.

### What's Missing

**Runtime awareness.** `has_many :items, dependent: :destroy` behaves differently across Rails versions. A model with 3 concerns mixed in has a callback chain invisible in the source file. An `around_action` in a parent controller affects every child action. These are only discoverable through runtime introspection.

**Relationship context.** Knowing that `Order` exists is less useful than knowing that `CheckoutService` creates it, `OrderMailer` notifies about it, `ShipmentWorker` processes it, and 4 controllers expose it via different APIs. The dependency graph is the codebase's actual architecture.

**Proportional context.** Not all code is equally relevant. A model changed 47 times in the last month matters more than one untouched for 2 years. A service with 12 dependents is more architecturally significant than one with none. Token budgets should reflect this.

**Framework fidelity.** When a developer asks "what options does `validates` support?", the answer must come from the exact Rails version in `Gemfile.lock`, not from training data that blends Rails 5, 6, and 7 documentation.

---

## What CodebaseIndex Does

### Extraction (Complete)

The extraction layer runs inside a Rails application and produces structured JSON representations of every meaningful code unit:

| Unit Type | Key Extractions |
|-----------|----------------|
| Models | Schema, associations with options, validations, all callback types, scopes, enums, inlined concerns |
| Controllers | Route mapping (verb → path → action), resolved filter chains, response formats, strong params |
| Services | Entry points, dependency injection, custom errors, return types |
| Jobs/Workers | Queue config, retry/concurrency, perform signatures, ActiveJob + Sidekiq |
| Mailers | Default settings, per-action templates, callbacks |
| Components | Phlex slots/params, rendered sub-components, Stimulus refs |
| GraphQL | Object types, input types, enums, unions, interfaces, mutations, resolvers, field metadata, authorization patterns |
| Framework Source | Version-pinned Rails internals and gem source, importance-rated |

Each unit includes bidirectional dependency edges, git enrichment (change frequency, contributors, recency), semantic chunks for large units, estimated token counts, and content hashes (`source_hash` on each unit, `content_hash` per chunk) for change detection.

The dependency graph supports PageRank scoring (damping: 0.85, 20 iterations) for quantifying architectural importance, and a `GraphAnalyzer` that identifies structural features: orphans, dead ends, hubs, cycles, and bridges.

### Retrieval (Proposed)

The retrieval layer transforms queries into contextually relevant, token-budgeted responses. It classifies queries, selects search strategies, ranks candidates, and assembles context with source attribution.

### Integration (Proposed)

The integration layer connects retrieval to consumption tools: CLI, editor plugins, API endpoints, CI hooks, agentic orchestrators. Each integration point uses the same retrieval core but may configure different budgets, strategies, or output formats.

---

## Design Principles

### 1. Backend Agnosticism

Every infrastructure dependency is behind an interface. Implementations are swappable without touching retrieval logic.

**Vector stores:** Qdrant, pgvector, Pinecone, FAISS, Milvus, Weaviate, SQLite-vss, Chroma
**Metadata stores:** PostgreSQL, MySQL, SQLite, in-memory
**Graph stores:** In-memory (default), PostgreSQL (recursive CTEs), Neo4j
**Embedding providers:** OpenAI, Voyage, Cohere, Ollama/local, Anthropic
**Background jobs:** Sidekiq, Solid Queue, GoodJob, DelayedJob, Resque, inline

A team should be able to start with SQLite + FAISS + Ollama (zero external dependencies) and migrate to Qdrant + PostgreSQL + OpenAI without changing application code.

### 2. Progressive Complexity

The system should be useful immediately with minimal setup and scale to sophisticated configurations:

| Level | Setup | What You Get |
|-------|-------|-------------|
| **Zero-config** | `rake codebase_index:extract` | JSON files on disk, greppable, readable |
| **Local search** | Add SQLite + FAISS | Semantic search, no external services |
| **Production** | Add vector store + embedding API | Full retrieval with CI integration |
| **Advanced** | Add graph DB + custom rankers | Cross-repo tracing, personalized ranking |

### 3. Agentic-First Design

The primary consumer is not a human reading output — it's an AI agent making decisions about what context to load. The system should:

- Expose structured metadata alongside content (not just raw text)
- Support multi-turn retrieval (agent refines based on initial results)
- Provide confidence signals (how relevant is this result?)
- Enable tool-use patterns (agent can call specific retrieval strategies)
- Return attribution so the agent can cite sources

### 4. Extraction Integrity

The extraction layer is the foundation. It must produce correct, complete, version-accurate data. If extraction is wrong, no amount of retrieval sophistication helps. This means:

- Runtime introspection over static parsing
- Exact gem versions from Gemfile.lock
- Concern inlining so the full picture is in one unit
- Schema introspection for actual column types
- Route resolution for real HTTP mappings

### 5. Observability

Every retrieval operation should be fully traceable: what query came in, how it was classified, what strategies ran, what candidates were found, how they were ranked, what was included in the final context, and why. This enables:

- Quality evaluation (are we returning useful context?)
- Debugging (why did this query return irrelevant results?)
- Tuning (which ranking signals matter most?)
- Regression detection (did a change degrade retrieval?)

---

## Retrieval Architecture Overview

```
Query
  │
  ▼
┌──────────────────┐
│ Query Classifier  │  Intent, scope, target type, framework need
└──────────────────┘
  │
  ▼
┌──────────────────┐
│ Strategy Selector │  Choose: vector, keyword, graph, hybrid, direct
└──────────────────┘
  │
  ▼
┌──────────────────┐
│ Search Executor   │  Run against vector store, metadata store, graph
└──────────────────┘
  │
  ▼
┌──────────────────┐
│ Ranker            │  Re-rank by relevance, recency, importance, diversity
└──────────────────┘     (Future: cross-encoder reranking for precision)
  │
  ▼
┌──────────────────┐
│ Context Assembler │  Token budget allocation, dedup, ordering, attribution
└──────────────────┘
  │
  ▼
RetrievalResult { context, tokens_used, sources, classification, trace }
```

### Query Classification

Queries are classified along four dimensions:

**Intent** — What is the user trying to do?
- `understand` — "How does checkout work?"
- `locate` — "Where is the order validation?"
- `trace` — "What happens when an order is placed?"
- `debug` — "Why might this callback fail?"
- `implement` — "How should I add a discount type?"
- `reference` — "What's the User model's primary key?"
- `compare` — "How do ProductOption and OptionGroup differ?"
- `framework` — "What options does has_many support?"

**Scope** — How broad?
- `pinpoint` — Single unit/fact
- `focused` — Small cluster of related units
- `exploratory` — Broad area
- `comprehensive` — Full feature/flow

**Target Type** — What kind of unit?
- `model`, `controller`, `service`, `job`, `mailer`, `component`, `graphql_type`, `graphql_mutation`, `graphql_resolver`, `graphql_query`, `framework`, `schema`, `route`, `unknown`

**Framework Context** — Does this need Rails/gem source?
- Triggered by patterns like "what options does X support", "how does Rails implement Y", "is Z deprecated"

### Search Strategies

| Strategy | When | How |
|----------|------|-----|
| **Vector Search** | Semantic queries, concept lookups | Embed query → cosine similarity against unit embeddings |
| **Keyword Search** | Exact identifiers, class/method names | Match against indexed identifiers, columns, methods |
| **Graph Traversal** | Dependency tracing, impact analysis | BFS/DFS from identified unit through dependency graph |
| **Hybrid** | Most queries | Combine vector + keyword + graph expansion (use Reciprocal Rank Fusion for score merging) |
| **Direct Lookup** | Known identifier, pinpoint queries | Fetch unit by ID |

### Context Assembly

Token budget is allocated in layers:

| Layer | Budget | Purpose |
|-------|--------|---------|
| Structural | 10% | Always-included codebase overview |
| Primary | 50% | Direct query results |
| Supporting | 25% | Dependencies, related context |
| Framework | 15% | Rails/gem source (when needed) |

---

## Backend Adaptability Matrix

The system must work across common Rails infrastructure patterns. See `BACKEND_MATRIX.md` for deep analysis of each combination.

### Common Stacks

| Stack Pattern | Vector Store | Metadata | Graph | Embedding | Jobs |
|--------------|-------------|----------|-------|-----------|------|
| **Modern Rails 8** | pgvector | PostgreSQL | PostgreSQL | OpenAI/Voyage | Solid Queue |
| **Classic Rails (MySQL)** | Qdrant | MySQL 8.0+ | MySQL (recursive CTEs) | OpenAI | Sidekiq |
| **Classic Rails (PG)** | pgvector or Qdrant | PostgreSQL | PostgreSQL | OpenAI | Sidekiq |
| **Self-hosted** | Qdrant/Milvus | PostgreSQL or MySQL | Same DB or in-memory | Ollama | Any |
| **Zero-dependency** | FAISS/SQLite-vss | SQLite | In-memory | Ollama | Inline |
| **Cloud-native** | Pinecone | PostgreSQL or Aurora MySQL | In-memory | OpenAI | Sidekiq/SQS |
| **Enterprise** | Weaviate | PostgreSQL | Neo4j | Azure/Bedrock | Any |

### Interface Contracts

Each backend type satisfies a Ruby module interface:

```ruby
# All vector stores implement:
CodebaseIndex::Storage::VectorStore::Interface
  #upsert(id:, vector:, metadata:)
  #upsert_batch(items)
  #search(vector:, filters:, limit:)
  #delete(ids)
  #delete_by_filter(filters)

# All metadata stores implement:
CodebaseIndex::Storage::MetadataStore::Interface
  #upsert(id:, metadata:)
  #find(id)
  #search_keywords(keywords:, fields:, filters:, limit:)
  #query(filters:, limit:)

# All embedding providers implement:
CodebaseIndex::Embedding::Provider::Interface
  #embed(text)
  #embed_batch(texts)
  #dimensions
  #model_name

# All graph stores implement:
CodebaseIndex::Storage::GraphStore::Interface
  #register(id:, type:, edges:)
  #dependencies_of(id)
  #dependents_of(id)
  #traverse_forward(start:, max_depth:)
  #traverse_reverse(start:, max_depth:)
  #shortest_path(from, to)
```

---

## Agentic Consumption Patterns

The system is designed for AI agents as primary consumers. See `AGENTIC_STRATEGY.md` for detailed patterns.

### Tool-Use Interface

An agent interacting with CodebaseIndex has access to these tools:

```
codebase_retrieve(query)              — Semantic retrieval with auto-classification
codebase_lookup(identifier)           — Direct unit fetch by name
codebase_dependencies(identifier)     — Forward dependency graph
codebase_dependents(identifier)       — Reverse dependency graph ("who uses this?")
codebase_search(keyword)              — Exact match search
codebase_framework(concept)           — Rails/gem source for a concept
codebase_structure()                  — High-level codebase overview
codebase_recent_changes(n)            — Recently modified units
codebase_graph_analysis(analysis)     — Structural analysis (orphans, dead ends, hubs, cycles, bridges)
codebase_pagerank(limit)              — PageRank scores for dependency graph nodes
```

### Multi-Turn Retrieval

Agents should be able to refine their understanding across multiple retrievals:

```
Turn 1: Agent retrieves "checkout flow" → gets CheckoutService, Order, Cart
Turn 2: Agent sees CheckoutService depends on PaymentGateway → retrieves that
Turn 3: Agent needs to understand validation → retrieves Order validations + framework source
```

The retrieval layer supports this by:
- Accepting prior context (what's already been retrieved)
- Deduplicating against previously returned units
- Adjusting token budget for remaining capacity
- Supporting conversation-scoped caching

---

## Evaluation Strategy

Before implementation, the system should be evaluated against these criteria:

### Retrieval Quality

| Metric | Description | Target |
|--------|-------------|--------|
| **Precision@k** | Of k results returned, how many are relevant? | > 0.80 at k=5 |
| **Recall** | Of all relevant units, how many were found? | > 0.70 |
| **MRR** | Mean reciprocal rank of first relevant result | > 0.85 |
| **Context Completeness** | Does assembled context contain enough to answer the query? | Qualitative eval |
| **Token Efficiency** | Ratio of relevant tokens to total tokens in context | > 0.60 |

### Evaluation Methodology

1. **Build a query set** — 50-100 queries spanning all intent types, scope levels, and target types. Include both simple lookups and complex cross-cutting questions.

2. **Annotate ground truth** — For each query, manually identify the units that should appear in the response and the minimum context needed to answer.

3. **Run retrieval** — Execute each query against the system and capture the full trace.

4. **Score** — Compare retrieved results against ground truth using the metrics above.

5. **Iterate** — Tune classification thresholds, ranking weights, budget allocation, and embedding preparation based on results.

### Baseline Comparisons

Compare CodebaseIndex retrieval against:

- **Naive RAG** — Chunk files by line count, embed, search. No runtime introspection.
- **File-level retrieval** — Return whole files matching keywords. No chunking.
- **Grep + context** — Pattern match + surrounding lines. No semantics.
- **Claude Code's built-in** — Tool-use exploration without pre-indexing.

The hypothesis is that runtime-aware extraction + semantic chunking + dependency graph produces meaningfully better context than any of these baselines, particularly for:
- Questions about callback chains and side effects
- Cross-cutting concerns (what uses X?)
- Framework-specific behavior (version-accurate answers)
- Large codebases where naive RAG drowns in noise

---

## Implementation Roadmap

### Phase 1: Storage Interfaces & Embedding Pipeline

**Goal:** Make extracted data searchable.

- Define Ruby module interfaces for all storage backends
- Implement SQLite + FAISS backend (zero-dependency starting point)
- Implement OpenAI embedding provider
- Build text preparation pipeline (format units for embedding)
- Build indexing pipeline (extract → prepare → embed → store)
- Rake tasks: `codebase_index:embed`, `codebase_index:embed_incremental`

**Deliverable:** Given extracted JSON, produce a searchable vector index with metadata.

### Phase 2: Retrieval Core

**Goal:** Answer queries with relevant context.

- Implement query classifier (intent, scope, target type, framework need)
- Implement search strategies (vector, keyword, graph, hybrid, direct)
- Implement ranker with configurable signal weights
- Implement context assembler with token budgeting
- Build structural context builder

**Deliverable:** `CodebaseIndex::Retriever.retrieve("how does checkout work?")` returns token-budgeted context with source attribution.

### Phase 3: Interface Layer

**Goal:** Make retrieval accessible.

- CLI tool (`bin/codebase retrieve "query"`)
- Rake tasks (`codebase_index:retrieve["query"]`)
- Ruby API for in-app consumption
- JSON output format for tool integration

**Deliverable:** Multiple entry points to the same retrieval core.

### Phase 4: Additional Backends

**Goal:** Support common infrastructure variations.

- Qdrant vector store implementation
- pgvector implementation
- PostgreSQL metadata store
- MySQL metadata store
- PostgreSQL graph store (recursive CTEs)
- Voyage embedding provider
- Ollama embedding provider (fully self-hosted)
- Solid Queue integration for background indexing

**Deliverable:** Configuration presets for common stack combinations.

### Phase 5: Evaluation & Tuning

**Goal:** Quantify and improve retrieval quality.

- Build evaluation harness
- Create query set with ground truth annotations
- Run baseline comparisons
- Tune ranking weights, budget allocation, classification thresholds
- Document findings

**Deliverable:** Published evaluation results and tuned defaults.

### Phase 6: Agentic Integration

**Goal:** First-class support for AI agent consumption.

- MCP server implementation
- Tool-use definitions for agent frameworks
- Multi-turn retrieval with conversation context
- Streaming context assembly
- Agent-specific output formatting

**Deliverable:** An MCP server that agents can connect to for codebase-aware assistance.

### Phase 7: Advanced Features

**Goal:** Extend beyond single-codebase retrieval.

- Multi-repo indexing (microservices, engines)
- Runtime correlation (APM data → code)
- Test coverage mapping
- Documentation linking (ADRs, wiki, external docs)
- Code review context (PR-scoped retrieval)

---

## Configuration

### Minimal Setup

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = "tmp/codebase_index"
end

# Extract
CodebaseIndex.extract!

# Index (uses SQLite + FAISS defaults)
CodebaseIndex.index!

# Retrieve
result = CodebaseIndex.retrieve("how does order processing work?")
puts result.context
```

### Production Setup (MySQL)

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join("tmp/codebase_index")

  # Vector store (MySQL has no native vector extension — use Qdrant)
  config.vector_store = :qdrant
  config.vector_store_url = ENV["QDRANT_URL"]

  # Embeddings
  config.embedding_provider = :openai
  config.embedding_model = "text-embedding-3-small"

  # Metadata + graph in existing MySQL 8.0+ database
  config.metadata_store = :mysql
  config.graph_store = :mysql
  config.metadata_connection = ENV["DATABASE_URL"]

  # Retrieval
  config.token_budget = 12_000
  config.max_candidates = 50

  # Framework indexing
  config.include_framework_sources = true
  config.add_gem "devise", priority: :high
  config.add_gem "pundit", priority: :high
end
```

### Production Setup (PostgreSQL)

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join("tmp/codebase_index")

  # Vector store (pgvector keeps everything in one database)
  config.vector_store = :pgvector
  # Or use Qdrant for dedicated vector search:
  # config.vector_store = :qdrant
  # config.vector_store_url = ENV["QDRANT_URL"]

  # Embeddings
  config.embedding_provider = :openai
  config.embedding_model = "text-embedding-3-small"

  # Metadata + graph in PostgreSQL
  config.metadata_store = :postgresql
  config.graph_store = :postgresql
  config.metadata_connection = ENV["DATABASE_URL"]

  # Retrieval
  config.token_budget = 12_000
  config.max_candidates = 50

  # Framework indexing
  config.include_framework_sources = true
  config.add_gem "devise", priority: :high
  config.add_gem "pundit", priority: :high
end
```

### Presets

```ruby
# Zero external dependencies
CodebaseIndex.configure_with_preset(:local)

# MySQL + Qdrant (classic Rails: MySQL/Percona + Sidekiq + Docker)
CodebaseIndex.configure_with_preset(:mysql)

# PostgreSQL + pgvector (Rails 8 / Solid suite style)
CodebaseIndex.configure_with_preset(:postgresql)

# PostgreSQL + Qdrant
CodebaseIndex.configure_with_preset(:postgresql_qdrant)

# Self-hosted, no external APIs (works with either database)
CodebaseIndex.configure_with_preset(:self_hosted)             # defaults to PostgreSQL
CodebaseIndex.configure_with_preset(:self_hosted, db: :mysql)  # MySQL variant
```

---

## Open Questions

1. **Embedding model selection** — Voyage Code 3 (1024 dimensions, 32K context window) vs OpenAI text-embedding-3-small vs code-specific alternatives. Needs benchmarking against Rails code specifically. General-purpose embeddings may miss domain concepts.

2. **Chunk granularity** — Current semantic chunking (summary/associations/callbacks/validations) works for models. Need to validate this produces better retrieval than alternatives (method-level, block-level, file-level).

3. **Graph store scaling** — In-memory graph works for single apps up to ~2000 units. Multi-repo or very large monoliths may need persistent graph storage. At what scale do recursive CTE traversals degrade in MySQL 8.0+ vs PostgreSQL? MySQL's CTE optimizer is less mature — need to benchmark with real dependency graphs at 2000, 5000, and 10000 nodes.

4. **Classification accuracy** — The query classifier is heuristic-based. Should it use an LLM for classification? That adds latency and cost. Needs evaluation of heuristic vs LLM classification accuracy.

5. **Token budget optimization** — The 10/50/25/15 budget split is a starting assumption. Needs tuning per query type — framework questions probably need more framework budget, trace questions need more supporting context.

6. **Incremental embedding** — When a unit changes, does the whole unit need re-embedding or can chunks be updated independently? Depends on whether chunk embeddings are context-dependent.

7. **Multi-language support** — Some Rails apps have significant JavaScript/TypeScript alongside Ruby. Should extraction cover frontend code? Stimulus controllers are already captured via Phlex, but standalone JS modules aren't.

8. **Security** — Extracted data contains source code. Storage backends need appropriate access controls. Self-hosted options may be preferable for security-sensitive codebases. Need to define a security model.

9. **Extraction coverage gaps** — Serializers (ActiveModelSerializers, Blueprinter, Alba) and decorators (Draper) are not yet extracted. View components are Phlex-only; ViewComponent (GitHub) is not covered. These are common patterns in large Rails apps and should be addressed in a future extraction pass.

---

## Next Steps

1. Review this proposal and `BACKEND_MATRIX.md` for backend selection guidance
2. Review `AGENTIC_STRATEGY.md` for consumption pattern design
3. Select a target stack for first implementation
4. Build Phase 1 (storage interfaces + embedding pipeline)
5. Build evaluation harness concurrently with Phase 2
