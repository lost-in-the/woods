# Backend Adaptability Matrix

## Purpose

This document provides deep analysis of every backend option CodebaseIndex supports, with tradeoffs, performance characteristics, and guidance for selecting the right combination for a given environment.

The goal is that an agent or developer reading this document can make an informed backend selection without external research.

---

## Vector Stores

### pgvector (PostgreSQL Extension)

**What it is:** PostgreSQL extension that adds vector similarity search directly to Postgres.

**Best for:** Teams already on PostgreSQL who want to minimize infrastructure. Rails 8 apps with the Solid suite. Codebases under ~5000 units.

**Strengths:**
- Zero additional infrastructure if you're on PostgreSQL
- Transactional consistency with metadata (same database)
- Familiar SQL interface, works with ActiveRecord
- Supports HNSW and IVFFlat indexing
- Filtered search via standard WHERE clauses
- Backed by strong open-source community

**Weaknesses:**
- Search performance degrades at high scale (>100K vectors) without careful tuning
- IVFFlat requires periodic reindexing after large batch inserts
- HNSW index builds are memory-intensive
- Competes for resources with your application database
- No built-in sharding for vectors

**Configuration:**
```ruby
config.vector_store = :pgvector
config.vector_store_connection = ENV["DATABASE_URL"]
# Or separate database:
config.vector_store_connection = ENV["VECTOR_DATABASE_URL"]
```

**Schema:**
```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE codebase_embeddings (
  id TEXT PRIMARY KEY,
  embedding vector(1536),
  metadata JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- HNSW index (preferred for < 1M vectors)
CREATE INDEX ON codebase_embeddings
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- GIN index on metadata for filtered queries
CREATE INDEX ON codebase_embeddings
  USING gin (metadata jsonb_path_ops);
```

**Performance notes:**
- HNSW: ~5ms search at 10K vectors, ~20ms at 100K. Memory: ~1.5x vector size.
- IVFFlat: Faster builds, slower search. Better for bulk insert then query patterns.
- For codebase indexing (~1000-5000 units, potentially 5000-20000 chunks), HNSW is appropriate.
- Recommend a separate database from your application if running in production.

**When to use:** PostgreSQL is your primary database, you value simplicity, and scale is under ~50K vectors.

**When to avoid:** MySQL is your primary database (can't use pgvector), you need sub-millisecond search, or you're indexing multiple large codebases.

---

### Qdrant

**What it is:** Purpose-built vector database with native filtering, written in Rust.

**Best for:** Teams with Docker-based infrastructure who want dedicated vector search. Self-hosted environments. Multi-codebase indexing.

**Strengths:**
- Purpose-built for vector search (consistently fast)
- Native payload filtering (no joins needed)
- Built-in quantization for memory efficiency
- Excellent Docker support, trivial to add to docker-compose
- gRPC and REST APIs
- Snapshot and backup support
- Handles batch operations well

**Weaknesses:**
- Additional infrastructure to manage
- Separate from your application database (no transactional consistency)
- Ruby client library is less mature than PostgreSQL tooling
- Overkill for small codebases

**Configuration:**
```ruby
config.vector_store = :qdrant
config.vector_store_url = ENV.fetch("QDRANT_URL", "http://localhost:6333")
config.vector_store_collection = "codebase_index"
```

**Docker Compose:**
```yaml
services:
  qdrant:
    image: qdrant/qdrant:v1.12.1
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - qdrant-data:/qdrant/storage
    environment:
      QDRANT__SERVICE__GRPC_PORT: 6334
    deploy:
      resources:
        limits:
          memory: 512M  # Sufficient for ~50K vectors

volumes:
  qdrant-data:
```

**Performance notes:**
- ~2ms search at 10K vectors, ~5ms at 100K
- Memory: ~100MB for 10K 1536-dim vectors with HNSW
- Quantization can reduce memory by 4x with minimal quality loss
- Batch upsert: ~1000 vectors/second

**When to use:** Docker infrastructure, self-hosted, need for filtered search, multi-codebase, or want separation of concerns between app DB and vector search.

**When to avoid:** Minimal infrastructure footprint is a priority, or team doesn't want another service to manage.

---

### Pinecone

**What it is:** Fully managed cloud vector database.

**Best for:** Teams that prefer managed services and don't want to operate vector infrastructure.

**Strengths:**
- Zero operational overhead
- Scales automatically
- Good SDK and documentation
- Metadata filtering
- Serverless pricing option (pay per query)

**Weaknesses:**
- Vendor lock-in
- Data leaves your infrastructure
- Latency depends on region
- Cost scales with usage
- No self-hosted option
- Free tier is limited

**Configuration:**
```ruby
config.vector_store = :pinecone
config.vector_store_api_key = ENV["PINECONE_API_KEY"]
config.vector_store_environment = "us-east-1"
config.vector_store_index = "codebase-index"
```

**When to use:** Cloud-native teams, no ops capacity for self-hosting, data sensitivity is not a concern.

**When to avoid:** Self-hosted requirements, cost sensitivity at scale, data must stay on-premise.

---

### SQLite-vss / FAISS (Local)

**What it is:** File-based vector search using SQLite for metadata and FAISS for vector operations.

**Best for:** Local development, zero-dependency setups, evaluation, single-developer use.

**Strengths:**
- Zero external dependencies
- No network latency
- Works offline
- Trivial setup
- Good for testing and development

**Weaknesses:**
- Single-process access (no concurrent writes)
- No network access (can't share across services)
- FAISS index must fit in memory
- Limited filtering capabilities
- No built-in persistence management for FAISS

**Configuration:**
```ruby
config.vector_store = :sqlite_faiss
# Automatically uses output_dir for storage
```

**When to use:** Getting started, local development, evaluation, CI testing.

**When to avoid:** Multi-user access, production workloads, CI pipelines that need shared state.

---

### Chroma

**What it is:** Open-source embedding database with a focus on developer experience.

**Best for:** Prototyping, Python-heavy teams (Ruby client exists but is third-party).

**Strengths:**
- Simple API
- Built-in embedding functions
- Document-oriented (stores text alongside vectors)
- Good developer experience

**Weaknesses:**
- Ruby client is community-maintained
- Less mature than Qdrant for production use
- Limited filtering compared to Qdrant/pgvector
- Performance characteristics less documented

**When to use:** Prototyping, if you're already using Chroma elsewhere.

**When to avoid:** Production Rails apps, when Ruby-native tooling matters.

---

### Milvus

**What it is:** Open-source vector database designed for massive scale.

**Best for:** Very large deployments, multi-tenant indexing across many codebases.

**Strengths:**
- Handles billions of vectors
- GPU-accelerated search
- Multi-tenancy support
- Rich indexing options

**Weaknesses:**
- Complex to deploy (requires etcd, MinIO, Pulsar)
- Overkill for single-codebase use
- Operational complexity
- Ruby client is third-party

**When to use:** Indexing dozens of large codebases, enterprise deployment.

**When to avoid:** Single codebase, minimal infrastructure preference.

---

## Embedding Providers

### OpenAI text-embedding-3-small

**Dimensions:** 1536
**Max tokens:** 8191
**Cost:** ~$0.02 per 1M tokens
**Latency:** ~100ms single, ~500ms batch of 100

**Strengths:** Good quality/cost ratio, fast, well-documented, reliable API.
**Weaknesses:** Data sent to OpenAI, API dependency, not code-optimized.

**Best for:** General use, getting started, teams already using OpenAI.

### OpenAI text-embedding-3-large

**Dimensions:** 3072
**Max tokens:** 8191
**Cost:** ~$0.13 per 1M tokens
**Latency:** ~150ms single, ~800ms batch of 100

**Strengths:** Higher quality than small, supports dimension reduction (can use 1536 dims for compatibility).
**Weaknesses:** 6.5x cost of small, marginal quality improvement for code.

**Best for:** When retrieval quality is paramount and cost is not a concern.

### Voyage Code 3 / Code 2

**Dimensions:** 1024 (Code 3) / 1536 (Code 2)
**Max tokens:** 32000 (Code 3) / 16000 (Code 2)
**Cost:** ~$0.06 per 1M tokens (verify current pricing for Code 3)
**Latency:** ~120ms single

**Strengths:** Specifically trained on code. Code 3's 32K context window means even very large units can be embedded without truncation. Code 3 uses 1024 dimensions (smaller vectors, less storage) while maintaining strong retrieval quality. Benchmarks show strong performance on code retrieval tasks.
**Weaknesses:** Smaller community than OpenAI. API availability/reliability less battle-tested.

**Best for:** Code-specific retrieval where embedding quality matters. Code 3's 32K token window is significant — many extracted units exceed 8K tokens, especially with inlined concerns. The lower dimensionality (1024 vs 1536) also reduces vector storage costs.

### Ollama / Nomic-embed-text (Self-hosted)

**Dimensions:** 768 (nomic-embed-text) / varies by model
**Max tokens:** 8192 (nomic)
**Cost:** Hardware only
**Latency:** ~200ms single (GPU), ~2s single (CPU)

**Strengths:** Fully self-hosted, no data leaves infrastructure, no API costs, works offline.
**Weaknesses:** Requires GPU for reasonable performance (CPU is 10x slower), lower quality than commercial models, smaller dimensions may reduce retrieval precision.

**Best for:** Security-sensitive environments, air-gapped networks, cost-sensitive at scale.

### Anthropic Embeddings

**Note:** Anthropic does not currently offer a standalone embedding API. If this changes, it would be a natural fit given the system's agentic focus. Monitor for availability.

### Embedding Selection Guidance

| Priority | Recommendation |
|----------|---------------|
| **Best quality for code** | Voyage Code 3 |
| **Best general-purpose** | OpenAI text-embedding-3-small |
| **Best for large units** | Voyage Code 3 (32K context) |
| **Lowest cost** | Ollama + nomic-embed-text |
| **No external dependencies** | Ollama + nomic-embed-text |
| **Maximum quality** | OpenAI text-embedding-3-large |

**Critical consideration:** Embedding dimensions must match across your entire index. Changing embedding providers requires a full re-index. Choose carefully at the start.

---

## Metadata Stores

### PostgreSQL

**Best for:** Most production deployments. JSON operators for metadata queries, full-text search for keywords, recursive CTEs for graph traversal (can double as graph store).

**Key features:**
- JSONB columns with GIN indexes for fast metadata filtering
- `ts_vector` / `ts_query` for full-text keyword search
- Recursive CTEs for graph operations (can serve as graph store too)
- Familiar to Rails developers
- Works with ActiveRecord

**Dual use as graph store:** PostgreSQL can handle both metadata and graph storage with recursive CTEs, eliminating the need for a separate graph backend at moderate scale (~5000 nodes).

```sql
-- Recursive CTE for dependency traversal
WITH RECURSIVE deps AS (
  SELECT target_id, 1 as depth
  FROM edges
  WHERE source_id = 'Order'
  UNION ALL
  SELECT e.target_id, d.depth + 1
  FROM edges e
  JOIN deps d ON e.source_id = d.target_id
  WHERE d.depth < 3
)
SELECT * FROM deps;
```

### MySQL

**Best for:** Teams already on MySQL who don't want to add PostgreSQL. This is common — MySQL (including Percona, MariaDB, Aurora) remains the most prevalent Rails database in production.

**Key features:**
- JSON functions for metadata (`JSON_EXTRACT`, `JSON_CONTAINS`, `JSON_OVERLAPS`)
- Generated columns for indexable JSON extraction
- Full-text indexes with `MATCH ... AGAINST` for keyword search
- Recursive CTEs in 8.0+ for graph traversal (dual-use as graph store)
- Familiar to Rails developers, works with ActiveRecord

**Schema:**
```sql
CREATE TABLE codebase_units (
  id VARCHAR(255) PRIMARY KEY,
  unit_type VARCHAR(50) NOT NULL,
  namespace VARCHAR(255),
  file_path VARCHAR(500),
  source_code MEDIUMTEXT,
  metadata JSON NOT NULL,
  
  -- Generated columns for indexable fields extracted from JSON
  change_frequency VARCHAR(20) GENERATED ALWAYS AS (
    JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.git.change_frequency'))
  ) STORED,
  importance VARCHAR(20) GENERATED ALWAYS AS (
    JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.importance'))
  ) STORED,
  association_count INT GENERATED ALWAYS AS (
    JSON_LENGTH(JSON_EXTRACT(metadata, '$.associations'))
  ) STORED,
  
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  INDEX idx_type (unit_type),
  INDEX idx_namespace (namespace),
  INDEX idx_change_freq (change_frequency),
  INDEX idx_importance (importance),
  FULLTEXT idx_fulltext (id, file_path, source_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

**Keyword search:**
```sql
-- Full-text search across identifiers and source
SELECT id, MATCH(id, file_path, source_code) AGAINST('checkout payment' IN BOOLEAN MODE) AS relevance
FROM codebase_units
WHERE MATCH(id, file_path, source_code) AGAINST('checkout payment' IN BOOLEAN MODE)
ORDER BY relevance DESC
LIMIT 20;

-- JSON-based method name search
SELECT id FROM codebase_units
WHERE JSON_CONTAINS(
  JSON_EXTRACT(metadata, '$.method_names'),
  '"process_payment"'
);

-- Multi-value filter on metadata
SELECT id FROM codebase_units
WHERE unit_type IN ('model', 'service')
  AND change_frequency IN ('hot', 'active')
  AND JSON_OVERLAPS(
    JSON_EXTRACT(metadata, '$.dependencies'),
    JSON_ARRAY('Order', 'Payment')
  );
```

**Graph traversal (MySQL 8.0+ recursive CTEs):**
```sql
CREATE TABLE codebase_edges (
  source_id VARCHAR(255) NOT NULL,
  target_id VARCHAR(255) NOT NULL,
  relationship VARCHAR(50) NOT NULL,
  PRIMARY KEY (source_id, target_id, relationship),
  INDEX idx_target (target_id),
  INDEX idx_relationship (relationship)
) ENGINE=InnoDB;

-- Forward dependency traversal
WITH RECURSIVE deps AS (
  SELECT target_id, relationship, 1 AS depth
  FROM codebase_edges
  WHERE source_id = 'Order'
  UNION ALL
  SELECT e.target_id, e.relationship, d.depth + 1
  FROM codebase_edges e
  INNER JOIN deps d ON e.source_id = d.target_id
  WHERE d.depth < 3
)
SELECT DISTINCT target_id, MIN(depth) as min_depth
FROM deps
GROUP BY target_id
ORDER BY min_depth;

-- Reverse: who depends on Order?
WITH RECURSIVE dependents AS (
  SELECT source_id, relationship, 1 AS depth
  FROM codebase_edges
  WHERE target_id = 'Order'
  UNION ALL
  SELECT e.source_id, e.relationship, d.depth + 1
  FROM codebase_edges e
  INNER JOIN dependents d ON e.target_id = d.source_id
  WHERE d.depth < 3
)
SELECT DISTINCT source_id, MIN(depth) as min_depth
FROM dependents
GROUP BY source_id
ORDER BY min_depth;
```

**Dual use as graph store:** MySQL 8.0+ supports recursive CTEs, so it can serve as both metadata and graph store — same pattern as PostgreSQL. Performance is adequate for ~5000 nodes. For Percona Cluster / Group Replication setups, the graph table should use InnoDB with appropriate row-level locking.

**MariaDB note:** MariaDB 10.2+ supports recursive CTEs and JSON functions but the syntax diverges slightly from MySQL 8.0 (e.g., `JSON_VALUE` vs `JSON_EXTRACT`). Generated columns are supported. If targeting MariaDB, test JSON function compatibility.

**Vector search with MySQL:** MySQL has no native vector extension equivalent to pgvector. For MySQL-primary stacks, vector search must use a separate backend:
- **Qdrant** — Best fit for Docker/self-hosted MySQL environments
- **Pinecone** — Best fit for managed/cloud MySQL environments
- **FAISS** — Best fit for local development alongside MySQL

This is the primary architectural difference from PostgreSQL: MySQL handles metadata and graph, but vectors live elsewhere.

**Configuration:**
```ruby
config.metadata_store = :mysql
config.metadata_store_connection = ENV["DATABASE_URL"]
# Or use the application's existing ActiveRecord connection:
config.metadata_store_connection = :active_record

# Vector store must be separate
config.vector_store = :qdrant  # or :pinecone, :sqlite_faiss
```

**Performance notes:**
- Generated columns + B-tree indexes make filtered queries fast without parsing JSON at query time
- `JSON_CONTAINS` and `JSON_OVERLAPS` on unindexed JSON paths do full scans — use generated columns for frequently filtered fields
- Full-text search with `MATCH ... AGAINST` is fast but requires InnoDB full-text indexes (available since 5.6)
- Recursive CTEs in MySQL 8.0 are ~20-40% slower than PostgreSQL for deep traversals but adequate for codebase-scale graphs
- For Percona XtraDB Cluster, writes to codebase tables should use a dedicated connection to avoid certification conflicts with application writes

**When to use:** MySQL/Percona/Aurora is your primary database, team has MySQL expertise, you don't want to introduce PostgreSQL.

**When to avoid:** You need vector search in the same database (use PostgreSQL + pgvector instead), or you're on MySQL < 8.0 (no recursive CTEs, limited JSON support).

### SQLite

**Best for:** Local development, zero-dependency setups, testing.

**Key features:**
- JSON1 extension for metadata queries
- FTS5 for full-text search
- Zero setup
- Single-file database

**Limitations:**
- Single writer at a time
- No network access
- Limited JSON querying compared to PostgreSQL

### In-Memory

**Best for:** Testing, evaluation, small codebases.

Loads from extracted JSON files on startup. All queries run against in-memory hash maps. Fast but ephemeral.

---

## Graph Stores

### In-Memory (Default)

Loads `dependency_graph.json` into a Ruby hash structure. Supports BFS traversal with visited set, PageRank scoring, and structural analysis via `GraphAnalyzer` (orphan detection, dead-end detection, hub identification, cycle detection, bridge detection). Suitable for up to ~5000 nodes.

**Memory:** ~10MB for 2000 nodes with average 5 edges each.
**Traversal:** < 1ms for depth-2 BFS.
**Analysis:** GraphAnalyzer provides `orphans`, `dead_ends`, `hubs(limit:)`, `cycles`, `bridges(limit:, sample_size:)`, and a combined `analyze` method.

### MySQL 8.0+ (Recursive CTEs)

Same pattern as PostgreSQL — stores edges in a table, traverses with recursive queries. MySQL 8.0 introduced recursive CTEs (`WITH RECURSIVE`), making this viable for MySQL-primary stacks.

```sql
CREATE TABLE codebase_edges (
  source_id VARCHAR(255) NOT NULL,
  target_id VARCHAR(255) NOT NULL,
  relationship VARCHAR(50) NOT NULL,
  PRIMARY KEY (source_id, target_id, relationship),
  INDEX idx_target (target_id),
  INDEX idx_relationship (relationship)
) ENGINE=InnoDB;

-- Forward traversal
WITH RECURSIVE deps AS (
  SELECT target_id, 1 AS depth
  FROM codebase_edges WHERE source_id = 'Order'
  UNION ALL
  SELECT e.target_id, d.depth + 1
  FROM codebase_edges e
  INNER JOIN deps d ON e.source_id = d.target_id
  WHERE d.depth < 3
)
SELECT DISTINCT target_id, MIN(depth) as min_depth
FROM deps GROUP BY target_id ORDER BY min_depth;
```

**Performance:** MySQL's CTE optimizer is less mature than PostgreSQL's. Expect ~20-40% slower deep traversals. Adequate for single-codebase graphs up to ~5000 nodes. For graphs larger than that, consider in-memory with MySQL as fallback, or PostgreSQL.

**Percona/MariaDB:** Percona Server 8.0 uses the same MySQL CTE implementation. MariaDB 10.2+ has its own CTE implementation with slightly different optimization characteristics — test with your distribution.

**When to use:** MySQL 8.0+ is your primary database and you want graph storage without adding infrastructure.

### PostgreSQL (Recursive CTEs)

Stores edges in a table, traverses with recursive queries. PostgreSQL's CTE optimizer is more mature, with better query planning for deep recursive traversals. Suitable for up to ~50000 nodes.

```sql
CREATE TABLE codebase_edges (
  source_id TEXT NOT NULL,
  target_id TEXT NOT NULL,
  relationship TEXT NOT NULL,
  PRIMARY KEY (source_id, target_id, relationship)
);

CREATE INDEX ON codebase_edges (target_id);  -- For reverse traversal
```

### Neo4j (Advanced)

Full graph database. Only needed for cross-repo analysis or very large monoliths where traversal patterns are complex (paths with conditions, weighted shortest path, community detection).

**When to use:** > 50000 nodes, cross-repository tracing, need for graph algorithms beyond what GraphAnalyzer provides in-memory. Note that basic graph analytics (betweenness centrality via bridge detection, cycle detection, hub identification, PageRank) are now available in-memory via `GraphAnalyzer` and `DependencyGraph#pagerank`, so Neo4j is only warranted for very large graphs or advanced algorithms like community detection and weighted shortest path.

---

## Background Job Integration

Indexing can be triggered synchronously (rake task, inline) or asynchronously (background job). The system supports:

### Sidekiq

```ruby
class CodebaseIndexJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 2

  def perform(mode = "full")
    case mode
    when "full" then CodebaseIndex.index!
    when "incremental" then CodebaseIndex.index_incremental!
    end
  end
end
```

### Solid Queue (Rails 8)

```ruby
class CodebaseIndexJob < ApplicationJob
  queue_as :low_priority
  limits_concurrency to: 1, key: "codebase_index"

  def perform(mode = "full")
    case mode
    when "full" then CodebaseIndex.index!
    when "incremental" then CodebaseIndex.index_incremental!
    end
  end
end
```

### GoodJob

```ruby
class CodebaseIndexJob < ApplicationJob
  queue_as :utility
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(mode = "full")
    # Same interface
  end
end
```

### Inline (Development/CI)

```ruby
# No job system needed
CodebaseIndex.index!
```

The key point: the indexing pipeline itself is agnostic to job system. It's a synchronous Ruby operation. The job wrapper is just scheduling and concurrency control.

---

## Recommended Stack Combinations

### Starter (Zero Dependencies)

```ruby
CodebaseIndex.configure_with_preset(:local)
# Vector: InMemory VectorStore
# Metadata: SQLite
# Graph: In-memory
# Embedding: Ollama (nomic-embed-text)
# Jobs: Inline
```

**Setup:** `brew install ollama && ollama pull nomic-embed-text`
**Tradeoff:** Lower retrieval quality, CPU-bound embedding, single-user.

### Rails 8 Standard

```ruby
CodebaseIndex.configure_with_preset(:postgresql)
# Vector: pgvector
# Metadata: SQLite
# Graph: In-memory
# Embedding: OpenAI
# Jobs: Solid Queue
```

**Setup:** `bundle add pgvector` + enable extension
**Tradeoff:** All-in-one database, good quality, API dependency for embeddings.

### MySQL + Qdrant (Classic Rails)

```ruby
# Note: :mysql preset is not yet implemented. Use :production preset + manual config
CodebaseIndex.configure_with_preset(:production)
# Vector: Qdrant
# Metadata: SQLite
# Graph: In-memory
# Embedding: OpenAI
# Jobs: Sidekiq
```

**Setup:** Add Qdrant to docker-compose, create codebase tables in existing MySQL
**Tradeoff:** Leverages existing MySQL infrastructure for metadata + graph. Qdrant handles vector search (which MySQL can't do natively). Most natural fit for established Rails apps on MySQL/Percona with Docker and Sidekiq.

### Docker-Native

```ruby
# Note: :docker preset is not yet implemented. Use :production preset (Qdrant + SQLite + OpenAI)
CodebaseIndex.configure_with_preset(:production)
# Vector: Qdrant
# Metadata: SQLite
# Graph: In-memory
# Embedding: OpenAI
# Jobs: Sidekiq or Solid Queue
```

**Setup:** Add Qdrant to docker-compose
**Tradeoff:** Additional service, but purpose-built vector search. Best performance/flexibility ratio.

### Fully Self-Hosted

```ruby
# Note: :self_hosted preset is not yet implemented.
# Use :production preset with Ollama as embedding provider via manual config.
CodebaseIndex.configure_with_preset(:production)
# Vector: Qdrant
# Metadata: SQLite
# Graph: In-memory
# Embedding: Ollama (nomic-embed-text or custom)
# Jobs: Any
```

**Setup:** Qdrant + Ollama in docker-compose
**Tradeoff:** No external API calls, all data stays on-premise. Works with either database. Embedding quality depends on model choice.

### Enterprise / Multi-Repo

```ruby
# Note: :enterprise preset is not yet implemented. Multi-repo / Milvus / Neo4j adapters are aspirational.
# Vector: Milvus or Weaviate (not yet implemented)
# Metadata: PostgreSQL (not yet implemented — current adapter: SQLite)
# Graph: Neo4j (not yet implemented — current adapter: InMemory)
# Embedding: OpenAI or Azure OpenAI (Azure not yet implemented)
# Jobs: Any
```

**Setup:** Significant infrastructure
**Tradeoff:** Maximum capability, maximum operational cost.

---

## Cost Modeling

Different stack combinations have very different cost profiles. This section provides rough estimates so teams can budget before committing to an architecture. All prices are approximate as of early 2025 and will change.

### Variables That Drive Cost

| Variable | Range | Impact |
|----------|-------|--------|
| Codebase size (models + services + controllers + GraphQL types + jobs) | 50–2000+ units | Linear on embedding cost, linear on storage |
| Chunk multiplier (chunks per unit, avg) | 1.5–4x | Multiplies embedding cost |
| Embedding dimensions | 256–3072 | Multiplies vector storage |
| Re-index frequency | Weekly / per-merge / per-commit | Multiplies embedding cost over time |
| Retrieval volume | 10–1000 queries/day | Multiplies query-time embedding cost |
| Infrastructure model | Shared app DB / dedicated / managed cloud | Determines hosting cost |

### Embedding Cost per Full Index

Assumptions: average unit produces ~400 tokens of embeddable text. Hierarchical chunking produces ~2.5 chunks per unit on average (1 summary + 1–3 semantic chunks). Each chunk has a ~50-token context prefix.

| Codebase Size | Total Chunks | Embedding Tokens | OpenAI 3-small ($0.02/1M) | OpenAI 3-large ($0.13/1M) | Voyage Code 3 ($0.06/1M) | Ollama (local) |
|--------------|-------------|-----------------|---------------------------|---------------------------|--------------------------|----------------|
| 50 units | ~125 | ~56K | $0.001 | $0.007 | $0.003 | $0 |
| 200 units | ~500 | ~225K | $0.005 | $0.029 | $0.014 | $0 |
| 500 units | ~1,250 | ~562K | $0.011 | $0.073 | $0.034 | $0 |
| 1000 units | ~2,500 | ~1.1M | $0.022 | $0.146 | $0.068 | $0 |

A full index of a 1000-unit codebase costs about two cents with OpenAI's small model. A production Rails app may have ~993 models and 2000+ total units when including controllers, services, jobs, GraphQL types, and mailers. Even at that scale, embedding cost is not the bottleneck.

### Incremental Re-embedding Cost

With chunk checksumming (only re-embed changed chunks), a typical merge touches 2–10 units. Assuming 5 changed units, ~12 chunks:

| Scenario | Tokens | OpenAI 3-small | OpenAI 3-large | Voyage Code 3 |
|----------|--------|----------------|----------------|----------------|
| Single merge (5 units) | ~5.4K | $0.0001 | $0.0007 | $0.0003 |
| Daily (10 merges) | ~54K | $0.001 | $0.007 | $0.003 |
| Monthly (200 merges) | ~1.1M | $0.022 | $0.143 | $0.066 |
| Yearly (2400 merges) | ~13M | $0.26 | $1.69 | $0.78 |

Even with aggressive per-merge re-indexing, the yearly embedding cost for a 1000-unit codebase is under $2 with OpenAI's small model. At the target scale of 2000+ units, multiply these figures by ~2x — still well under $5/year.

### Query-Time Embedding Cost

Each retrieval query must be embedded to perform vector search. One embedding call per query.

| Daily Queries | Monthly Tokens (~100 tokens/query) | OpenAI 3-small | OpenAI 3-large | Voyage Code 3 |
|--------------|-----------------------------------|----------------|----------------|----------------|
| 10 | ~30K | $0.001 | $0.004 | $0.002 |
| 100 | ~300K | $0.006 | $0.039 | $0.018 |
| 1000 | ~3M | $0.060 | $0.390 | $0.180 |

Query volume matters more than index size for ongoing costs, but even 1000 queries/day is cheap.

### Vector Storage Cost

Storage cost depends on embedding dimensions × number of vectors.

Bytes per vector: `dimensions × 4` (float32). With metadata overhead, estimate `dimensions × 4 × 1.3`.

| Codebase (chunks) | 256-dim | 1024-dim | 1536-dim | 3072-dim |
|-------------------|---------|----------|----------|----------|
| 125 | 0.16 MB | 0.65 MB | 0.97 MB | 1.9 MB |
| 500 | 0.64 MB | 2.6 MB | 3.8 MB | 7.7 MB |
| 1,250 | 1.6 MB | 6.4 MB | 9.6 MB | 19 MB |
| 2,500 | 3.2 MB | 13 MB | 19 MB | 38 MB |

**pgvector / MySQL:** Uses your existing database storage. No additional cost beyond disk. At these sizes, vector storage is negligible.

**Qdrant (self-hosted):** Docker container, ~200MB base RAM. For codebases under 5,000 chunks, memory usage is under 100MB for vectors. Total container footprint: ~300MB RAM.

**Qdrant Cloud:** Free tier covers up to 1M vectors. A codebase would need to be enormous to exceed this.

**Pinecone:** Free tier: 1 index, 100K vectors. Starter ($8/mo): more indexes. No codebase will exceed free tier vector counts, but you pay for the pod.

### Infrastructure Hosting Cost

| Component | Shared (use app infra) | Dedicated (self-hosted) | Managed Cloud |
|-----------|----------------------|------------------------|---------------|
| Vector store | $0 (pgvector in app DB) | $5–15/mo (Qdrant VPS) | $0–70/mo (free tiers exist) |
| Metadata store | $0 (app database) | $0 (app database) | $0 (app database) |
| Embedding | — | $5–20/mo (GPU for Ollama) | $0.02–2/yr (API) |
| Background jobs | $0 (app job system) | $0 (app job system) | $0 (app job system) |

### Cost per Preset

| Preset | Setup Cost | Monthly Ongoing | Notes |
|--------|-----------|----------------|-------|
| **local** (InMemory VectorStore + SQLite + Ollama) | $0 | $0 | Requires local GPU for decent embedding speed. CPU works but slow. |
| **postgresql** (pgvector + SQLite + OpenAI) | $0 | $0.05–0.50 | pgvector for vectors, SQLite for metadata. Good quality, API dependency for embeddings. |
| **production** (Qdrant + SQLite + OpenAI) | $0 | $0.05–0.50 | Qdrant for vectors, SQLite for metadata. Slightly better vector search, more infra. |
| **MySQL / Self-hosted / Enterprise** (not yet implemented) | — | — | Aspirational presets. Use :production preset with manual configuration overrides. |

### The Real Cost: Developer Time

Infrastructure and API costs are noise for single-codebase use. The actual cost is:

- **Setup time:** 1–4 hours depending on preset complexity
- **Tuning time:** 4–20 hours to evaluate embedding models, chunk strategies, and ranking weights
- **Maintenance time:** 1–2 hours/month for monitoring, occasional re-tuning

Choose the preset that minimizes setup and maintenance time for your team's existing infrastructure. The cheapest option is always the one that uses what you already run.
