# CodebaseIndex Architecture

This doc explains how CodebaseIndex works from the inside — how extraction, storage, retrieval, and the two MCP servers fit together.

---

## How Does CodebaseIndex Work?

CodebaseIndex runs in three phases across two environments:

```
Inside Rails app (rake task):
  1. Extract — 34 extractors introspect the live Rails environment
  2. Resolve — dependency graph is built and enriched with git data
  3. Write   — one JSON file per code unit to tmp/codebase_index/

On the host / in CI:
  4. Embed  — units are chunked and embedded into a vector store
  5. Query  — MCP server reads the JSON index and answers questions
```

The key insight: **extraction requires a booted Rails application** (`ActiveRecord::Base.descendants`, `Rails.application.routes`, etc.), but *querying* does not. The Index MCP server reads static JSON — no Rails, no database.

---

## Pipeline Overview

```
┌──────────────────────────────────────────────────────────┐
│                    Rails Application                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐             │
│  │ Extract  │──▶│ Resolve  │──▶│  Enrich  │             │
│  │ 34 types │   │  graph   │   │   git    │             │
│  └──────────┘   └──────────┘   └──────────┘             │
│                                     │                    │
│                                     ▼                    │
│                            ┌──────────────┐              │
│                            │ Write JSON   │              │
│                            │ tmp/codebase │              │
│                            │  _index/     │              │
│                            └──────────────┘              │
└──────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌──────────────────────────────────────────────────────────┐
│                 Host / CI Environment                    │
│  ┌──────────┐   ┌──────────┐   ┌──────────────────────┐ │
│  │  Embed   │──▶│  Index   │   │   MCP Index Server   │ │
│  │  OpenAI  │   │  pgvector│   │   27 tools, no Rails │ │
│  │  Ollama  │   │  Qdrant  │   └──────────────────────┘ │
│  └──────────┘   └──────────┘                            │
└──────────────────────────────────────────────────────────┘
                                                 ▲
                        ┌────────────────────────┘
                        │  Console MCP Server
                        │  31 tools, live Rails
                        │  (runs inside the app)
```

---

## What Is an ExtractedUnit?

`ExtractedUnit` is the universal currency of CodebaseIndex. Extractors produce them, the dependency graph connects them, the embedding pipeline consumes them, and the retrieval pipeline returns them.

Every unit carries:

- **`identifier`** — unique key, usually the class name (`"User"`, `"OrdersController"`) or a descriptive string for non-class units (`"POST /orders"`)
- **`type`** — what kind of thing this is (`:model`, `:controller`, `:service`, `:route`, etc.)
- **`file_path`** — relative path from `Rails.root` (e.g., `"app/models/user.rb"`)
- **`source_code`** — the annotated source: for models this includes concerns inlined and schema prepended; for controllers this includes a route context header
- **`metadata`** — type-specific structured data (associations, callbacks, actions, fields, etc.)
- **`dependencies`** — forward edges: `[{ type:, target:, via: }]`
- **`dependents`** — reverse edges, populated in a second pass after all units are registered
- **`chunks`** — semantic sub-sections for large units (populated by `SemanticChunker`)
- **`estimated_tokens`** — approximate token count using 4.0 chars/token (benchmarked conservative floor)

Units are serialized to JSON with two additional fields: `extracted_at` (timestamp) and `source_hash` (SHA-256 of source_code for change detection).

See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for the full field table and a complete example JSON.

---

## How Does Extraction Work?

### Eager Loading

Before any extractor runs, `Rails.application.eager_load!` is called once to load all application classes into memory. If `eager_load!` fails with a `NameError` (common when `app/graphql/` references an uninstalled gem — Zeitwerk processes directories alphabetically, so a failure in `graphql/` can prevent `models/` from loading), the orchestrator falls back to per-directory loading across the 19 directories in `EXTRACTION_DIRECTORIES`.

### Five Phases

```ruby
# Phase 1: Extract
EXTRACTORS.each { |type, klass| @results[type] = klass.new.extract_all }

# Phase 1.5: Deduplicate
# Duplicate identifiers (e.g., engine routes duplicating app routes) are dropped

# Phase 2: Resolve dependents
# Second pass: if A.dependencies includes B, B.dependents gets a back-reference to A

# Phase 3: Graph analysis
# PageRank, orphans, dead ends, hubs, cycles, bridges

# Phase 4: Enrich with git
# batch git log for all file paths → last_modified, contributors, change_frequency

# Phase 5: Write
# One JSON file per unit + _index.json per type + dependency_graph.json + SUMMARY.md + manifest.json
```

### Concurrent Mode

Set `config.concurrent_extraction = true` to run extractors in parallel threads. Thread safety is ensured by:
- Pre-computing `ModelNameCache` before threads start (avoids a `||=` race)
- Each thread gets its own extractor instance (no shared mutable state)
- Results are collected via `Mutex`-protected hash
- Dependency graph registration happens sequentially after all threads join

### Incremental Extraction

`extract_changed(changed_files)` re-extracts only the units affected by a set of changed files. It:
1. Loads the existing `dependency_graph.json`
2. Finds directly-changed units via the file map
3. BFS-traverses reverse edges to find transitively affected units
4. Re-extracts each affected unit using the appropriate extractor method
5. Updates only the affected JSON files and the type-level `_index.json`

**Incremental extraction skips** unit types that don't map to individual files: `route`, `middleware`, `engine`, `scheduled_job`. These require a full extraction to update.

---

## How Does the Dependency Graph Work?

The `DependencyGraph` is a directed graph where nodes are `ExtractedUnit` identifiers and edges are dependency relationships. It tracks:

- **Forward edges** (`@edges`): what each unit depends on — populated when units are registered
- **Reverse edges** (`@reverse`): what depends on each unit — built during registration and in the resolve phase

```ruby
graph = DependencyGraph.new
graph.register(user_unit)     # adds User to nodes, adds User→Order edge (from belongs_to)
graph.register(order_unit)    # adds Order to nodes

graph.dependencies_of("User")  # => ["Order", "UserService"]
graph.dependents_of("Order")   # => ["User", "OrdersController"]

# Blast radius: what needs re-indexing if user.rb changes?
graph.affected_by(["app/models/user.rb"])  # BFS over reverse edges
```

### PageRank Scoring

`DependencyGraph#pagerank` computes importance scores using the reverse edge structure: units with many dependents score higher. This matches the intuition that "important" units are the ones many other units depend on — the same insight as Google's PageRank applied to code graphs.

Scores feed into the retrieval ranker as one signal in the final ranking formula.

### GraphAnalyzer: Structural Metrics

`GraphAnalyzer` computes read-only structural reports from the graph:

| Metric | What it means |
|--------|--------------|
| **Orphans** | Units with no dependents — potential dead code or public entry points. Framework sources are excluded (they're naturally unreferenced in the reverse index). |
| **Dead ends** | Units with no dependencies — self-contained leaf nodes (value objects, standalone utilities) |
| **Hubs** | Units with many dependents — architectural bottlenecks; changes here have high blast radius |
| **Cycles** | Circular dependencies — A→B→C→A. Detected via DFS. |
| **Bridges** | Edges whose removal would disconnect the graph — high-risk structural connections |

Analysis results are written to `graph_analysis.json` and surfaced in `SUMMARY.md`.

---

## How Does Retrieval Work?

Retrieval is a four-stage pipeline coordinated by `Retriever`:

```
Query → [Classify] → [Execute] → [Rank] → [Assemble] → Context string
```

### Stage 1: Query Classification (`QueryClassifier`)

Classifies the query to determine:
- **Intent**: lookup, explanation, tracing, search, framework
- **Scope**: specific identifier, type filter, or broad
- **Target type**: `:model`, `:controller`, `:service`, etc. (or nil for cross-type)

Classification determines which search strategy to use and whether framework source context is relevant.

### Stage 2: Search Execution (`SearchExecutor`)

Executes one or more search strategies based on classification:

| Strategy | When used | How |
|----------|-----------|-----|
| **Vector** | Semantic/conceptual queries | Embeds the query and finds nearest neighbors |
| **Keyword** | Identifier lookups by name | Exact or prefix match on `identifier` field |
| **Graph** | "What uses X?" / "What does X depend on?" | Traverses forward/reverse edges from a starting node |
| **Hybrid** | Default for ambiguous queries | Combines vector + keyword, re-ranked via RRF |

### Stage 3: Ranking (`Ranker`)

Re-ranks candidates using multiple signals with weighted combination:

- Vector similarity score
- Keyword match quality
- PageRank importance score
- Recency (git `last_modified`)
- Type relevance to the query's target type

Uses **Reciprocal Rank Fusion (RRF)** to merge ranked lists from multiple search strategies without score normalization.

### Stage 4: Context Assembly (`ContextAssembler`)

Allocates token budget across layers:

```
Token Budget Allocation:
├── 10%  Structural overview ("Codebase: 42 units — 10 models, 5 controllers, ...")
├── 50%  Primary relevant units (highest-ranked candidates)
├── 25%  Supporting context (direct dependencies of primary units)
└── 15%  Framework reference (Rails source, when query intent = :framework)
```

Units that exceed the budget are truncated to their first semantic chunk. The assembled context string is then optionally post-processed by a formatter (`context_format: :claude`, `:markdown`, `:plain`, `:json`).

---

## What Storage Backends Are Available?

CodebaseIndex uses three independent store abstractions:

| Store | Purpose | Available Backends |
|-------|---------|-------------------|
| **VectorStore** | Embedding vectors for semantic search | In-memory (dev/test), pgvector (PostgreSQL), Qdrant |
| **MetadataStore** | Unit metadata for keyword search and type filtering | In-memory, SQLite, pgvector (JSON columns) |
| **GraphStore** | Dependency graph for graph-based traversal | In-memory, JSON file (via `dependency_graph.json`) |

The gem is backend-agnostic by design. MySQL and PostgreSQL have different JSON querying, indexing, and CTE syntax — no backend-specific SQL is written into the core.

### Configuration Presets

```ruby
# Local development (SQLite + in-memory vector)
CodebaseIndex.configure_with_preset(:local)

# PostgreSQL with pgvector
CodebaseIndex.configure_with_preset(:postgresql)

# Production (Qdrant for vectors, pgvector for metadata)
CodebaseIndex.configure_with_preset(:production)
```

Or wire backends manually:

```ruby
CodebaseIndex.configure do |config|
  config.vector_store = :qdrant
  config.vector_store_options = { url: "http://localhost:6333", collection: "codebase" }
  config.metadata_store = :sqlite
  config.embedding_provider = :openai
  config.embedding_model = "text-embedding-3-small"
end
```

---

## Why Are There Two MCP Servers?

The two servers have fundamentally different runtime requirements:

### Index Server (`codebase-index-mcp`)

**27 tools, 2 resources, 2 templates. Reads pre-extracted JSON. No Rails boot required.**

Starts with a path to the extraction output directory and reads from it:

```bash
codebase-index-mcp-start /path/to/rails-app/tmp/codebase_index
```

Use the Index Server for:
- Looking up models, controllers, services by name
- Dependency graph traversal ("what depends on User?")
- Semantic search across the codebase
- Pipeline management (status, trigger re-extraction)
- Temporal snapshots (comparing codebase state over time)
- Feedback collection

The Index Server is safe to run anywhere — it has no database connection and makes no writes to the Rails application.

### Console Server (`codebase-console-mcp`)

**31 tools, 4 tiers. Bridges to a live Rails process. Runs inside the app.**

Starts via rake task inside the Rails app (or `docker compose exec`):

```bash
bundle exec rake codebase_index:console
```

Use the Console Server for:
- Live database queries (`User.where(...)` with schema awareness)
- Model diagnostics (validate a record, inspect associations)
- Job queue monitoring (pending jobs, failed jobs, queue depths)
- Cache inspection (hit rates, key patterns)
- Guarded write operations (tier 4, requires confirmation)

All Console Server queries run inside a **rolled-back transaction** (`SafeContext`). SQL is validated by `SqlValidator` (rejects DML/DDL at the string level) before any database interaction. Writes are silently discarded by the rollback — this is intentional defense-in-depth. Tier 4 tools that need to actually write require explicit human-in-the-loop confirmation.

### Which Should I Use?

| Task | Server |
|------|--------|
| Find the User model source | Index |
| What jobs does CheckoutService enqueue? | Index |
| How many pending orders are in the database? | Console |
| What does our middleware stack look like? | Index |
| Run a query against the live database | Console |
| Trigger a re-extraction | Index |
| Check Sidekiq queue depth | Console |

---

## How Does Semantic Chunking Work?

Large units are split into semantic chunks before embedding. The `SemanticChunker` is type-aware — it doesn't split on arbitrary token counts.

### Model Chunking

Models are split into purpose-specific sections:

```
summary      — class declaration, table info, concerns list
associations — all has_many, belongs_to, has_one, HABTM
callbacks    — all before/after/around hooks with side-effects
validations  — all validates and validate calls
scopes       — named scopes
methods      — remaining public and private methods
```

Each chunk includes a header with the unit's identifier, type, and file path so it's self-contained when retrieved without the parent.

### Controller Chunking

Controllers chunk per-action:

```
summary      — class declaration, before_action filters, layout
<action>     — each public action method with its applicable filters and route context
```

This matches how queries actually come in: "how does the create action work?" retrieves only the `create` chunk and the filter context, not the entire controller.

### Threshold

Units below 200 estimated tokens stay as a single `:whole` chunk. Above that, the semantic chunker applies type-specific splitting. Units that are still large after splitting use the fallback `build_default_chunks` method (line-based splitting with a 1500-token limit per chunk).

### Why Not Just Split by Token Count?

Token-count splits break semantic units arbitrarily — an `associations` section split mid-way loses context. Semantic splits align with how the code is actually understood: "tell me about the associations" maps to the associations chunk, not to arbitrary line ranges 150–300.
