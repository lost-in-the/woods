# Backend Adaptability Matrix

## Purpose

Decision guidance for picking a vector store, metadata store, graph store, and embedding provider. Covers what's implemented today, what's still a design target, and how the four shipped presets map to `lib/woods/builder.rb`.

---

## Persistence Story

Every backend combination falls into one of three shapes based on how data survives process boundaries. The right shape depends on whether the embed process and the query process share a Ruby VM, a filesystem, or neither.

| Shape | Vector store | Metadata store | Durability | Right preset |
|---|---|---|---|---|
| **Local artifact** | `:in_memory` + dump to `output_dir` | `:sqlite` under `output_dir` | Reopens from the published output artifact | `:local` |
| **Shared filesystem** | `:in_memory` + `Snapshotter` dump to `output_dir` | `:in_memory` + `Snapshotter` dump to `output_dir` | Process-local, hydrated from disk on MCP boot; dumps retained per `dump_retention_count` (default 3) | `:shared_filesystem` |
| **Durable vector backend** | `:pgvector` or `:qdrant` | `:sqlite` under `output_dir` | Vectors are external; metadata/config remain a deployed output artifact | `:postgresql`, `:production` |

The shape determines the capability matrix:

| Capability | Local artifact | Shared filesystem | Durable vector backend |
|---|---|---|---|
| Survives process restart | Yes (via output artifact) | Yes (via dump) | Yes (backend + output artifact) |
| Multi-writer embedding | No | No (single writer assumed) | Do not assume it for the complete index; coordinate one publisher even if the vector backend supports concurrent writes |
| Requires sqlite3 gem in host | Yes | No | With `:postgresql`/`:production` |
| Requires embedding/vector service | Ollama | Ollama | OpenAI plus pgvector or Qdrant |
| Cross-machine query | After deploying/copying `output_dir` | Yes, when the filesystem is shared | External vectors are shared; metadata/config still require a shared or deployed `output_dir` |
| `woods.json` schema-versioned config snapshot | Yes | Yes | Yes |

`Builder#build_vector_store` accepts exactly `:in_memory`, `:pgvector`, `:qdrant`, anything else raises `ArgumentError: Unknown vector_store`. `build_metadata_store` accepts `:in_memory`, `:sqlite`. `build_graph_store` accepts `:in_memory` only. Presets are `:local`, `:shared_filesystem`, `:postgresql`, and `:production`.

---

## Vector Stores

### Database compatibility

The vector store you can use depends on the primary database your Rails app uses. MySQL stacks **must** pair with an external vector backend; PostgreSQL stacks have the option of running pgvector inside the same database.

| Primary database | Supported vector stores | Required? |
|---|---|---|
| **MySQL / Percona / MariaDB / Aurora MySQL** | `:qdrant` (external); `:in_memory` (local dev only) | Yes. MySQL has no native vector extension |
| **PostgreSQL / Aurora PostgreSQL** | `:pgvector` (in-database), `:qdrant`; `:in_memory` (local dev only) | No, `:pgvector` runs inside the same database |

**Why MySQL needs an external backend.** MySQL ships no equivalent of the `pgvector` extension. Approximate-nearest-neighbour search over arbitrary float vectors is not part of InnoDB / MyISAM and cannot be added via plugin. Woods does not emulate vector search in MySQL, the gem only ships adapters that delegate to a real vector engine. The shipped pairing for MySQL apps is `:qdrant` for vectors with Woods' own `:sqlite` metadata store; Woods never stores metadata in your application database.

### pgvector (PostgreSQL Extension)

**What it is:** PostgreSQL extension that adds vector similarity search directly to Postgres.

**Best for:** Teams already on PostgreSQL who want to minimize infrastructure. Rails 8 apps with the Solid suite. Codebases under ~5000 units.

**Strengths:**
- Zero additional infrastructure if you're on PostgreSQL
- Transactional consistency with metadata (same database)
- Familiar SQL interface, works with ActiveRecord
- Supports HNSW indexing
- Backed by strong open-source community

**Weaknesses:**
- Search performance degrades at high scale (>100K vectors) without careful tuning
- HNSW index builds are memory-intensive
- Competes for resources with your application database
- No built-in sharding for vectors

**Configuration:**
```ruby
config.vector_store = :pgvector
# pgvector needs a live PostgreSQL connection object (not a URL string).
# When your app runs on PostgreSQL, reuse its connection:
config.vector_store_options = { connection: ActiveRecord::Base.connection }

# Dedicated vector database: e.g. a MySQL app pointing at a separate
# PostgreSQL store: via an abstract class that owns its own connection:
# class VectorDatabase < ActiveRecord::Base
#   self.abstract_class = true
#   establish_connection(ENV.fetch("VECTOR_DATABASE_URL"))
# end
# config.vector_store_options = { connection: VectorDatabase.connection }
```

`vector_store_options` also accepts `:table` (default `woods_vectors`) and `:schema` (both optional); `:dimensions` is inferred from the embedding provider. `Builder#build_pgvector_store` requires `vector_store_options[:connection]` and raises if it is missing.

**Schema** (what `Woods::Storage::VectorStore::Pgvector#ensure_schema!` actually creates, safe to call repeatedly, uses `IF NOT EXISTS`):
```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS woods_vectors (
  id TEXT PRIMARY KEY,
  embedding vector(1536),
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_woods_vectors_embedding_hnsw
  ON woods_vectors USING hnsw (embedding vector_cosine_ops);
```

**Performance notes:**
- HNSW: ~5ms search at 10K vectors, ~20ms at 100K. Memory: ~1.5x vector size.
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

**Weaknesses:**
- Additional infrastructure to manage
- Separate from your application database (no transactional consistency)
- Overkill for small codebases

**Configuration:**
```ruby
config.vector_store         = :qdrant
config.vector_store_options = {
  url:        ENV.fetch("QDRANT_URL", "http://localhost:6333"),
  collection: "woods",
  api_key:    ENV["QDRANT_API_KEY"],  # optional; omit for unauthenticated local instances
  dimensions: 1_536,                  # optional; pre-validates vector length client-side
  distance:   "Cosine",               # Cosine, Dot, Euclid, or Manhattan; verified on reopen
  allow_private_hosts: true           # required for localhost/RFC1918 URLs, the SSRF guard blocks them by default
}
```

The adapter constructor takes these as keyword arguments (`Woods::Storage::VectorStore::Qdrant`); `Builder#build_vector_store` splats `vector_store_options` straight into it. Works identically whether your application database is MySQL or PostgreSQL. Qdrant is a separate service either way.

When an installed `woods-mcp` process reopens `woods.json` without the host initializer, non-secret options such as collection, distance, table, schema, and dimensions come from the snapshot. Credentials and process-specific connections remain serve-time settings:

- `OPENAI_API_KEY` supplies the embedding credential for OpenAI snapshots.
- Qdrant endpoint URLs and API keys are never stored in `woods.json`. `WOODS_QDRANT_URL` is required when serving a Qdrant index; `WOODS_QDRANT_API_KEY` is optional, and `WOODS_QDRANT_COLLECTION` supplies a collection only when the snapshot does not record one.
- `WOODS_PG_URL` is required to construct the Active Record connection for a pgvector snapshot outside its host application.

SQLite metadata is always reopened as `metadata.sqlite3` beneath the supplied index directory, never relative to the MCP process working directory.

**Point IDs.** Qdrant accepts only an unsigned integer or a UUID as a point id, so the adapter cannot store a Woods identifier directly. It derives a deterministic UUIDv5 from the identifier over a pinned namespace (`Qdrant::POINT_ID_NAMESPACE`) and carries the identifier in the payload under `woods_identifier`; `#search` reverse-maps hits back to identifiers and `#delete` translates through the same function. The namespace must never change: a v5 id is what makes re-embedding an unchanged unit *replace* its point instead of adding a second one. See #147.

**Sharing a collection.** `#each_id` enumerates only points carrying a `woods_identifier` payload — points another writer put in the same collection are skipped, not yielded. It backs the embed pipeline's staleness sweep, which deletes anything it enumerates that extraction no longer holds, so yielding a foreign point would destroy another system's vectors on every run. The Indexer applies the same rule a second time, ignoring vanished ids shaped like a canonical UUID or an integer — shapes Woods never mints as an identifier.

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

**When to use:** Docker infrastructure, self-hosted, need for filtered search, multi-codebase, or want separation of concerns between app DB and vector search.

**When to avoid:** Minimal infrastructure footprint is a priority, or team doesn't want another service to manage.

---

### Not implemented

These are aspirational; setting `config.vector_store` to any of them raises `ArgumentError: Unknown vector_store`, and there is no `vector_store_api_key` / `vector_store_environment` / `vector_store_index` accessor on `Configuration`, code written against the examples below will not run against the shipped gem. The interface a real adapter must implement is `Woods::Storage::VectorStore::Interface` (`store`, `search`, `delete`, `each_id`); see `Woods::Storage::VectorStore::Pgvector` or `Qdrant` for a working example to model a new adapter on.

| Backend | Status | Notes |
|---|---|---|
| Pinecone | Planned (#83) | Managed cloud vector DB. Would suit teams that want zero ops and accept vendor lock-in and data leaving the infrastructure. |
| SQLite-vss / FAISS | Planned | File-based local vector search. `:in_memory` (the `:local` preset) already covers the zero-dependency local case today. |
| Chroma | Not planned | Ruby client is third-party and less mature than the Qdrant/pgvector tooling already shipped. |
| Milvus | Not planned | Massive-scale, multi-tenant vector DB. Only worth building if a host needs billions of vectors or GPU-accelerated search across many codebases, well beyond single-codebase indexing. |

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

### Ollama (Self-hosted)

| Model | Native context | Dimensions | Weights | Notes |
|---|---|---|---|---|
| `nomic-embed-text` (default) | 2048 | 768 | 274 MB | General-purpose; pull from Ollama before first use |
| `bge-m3` | **8192** | 1024 | 1.2 GB | Fewer chunks per unit, stronger code-search benchmarks |
| `snowflake-arctic-embed2` | 8192 | 1024 | 1.2 GB | Multilingual variant of bge-m3 |
| `mxbai-embed-large` | 512 | 1024 | 670 MB | Best for short text |
| `all-minilm` | 512 | 384 | 46 MB | Tight-memory environments |

**Cost:** Hardware only
**Latency:** ~200ms single (GPU), ~2s single (CPU)

**Strengths:** Fully self-hosted, no data leaves infrastructure, no API costs, works offline.
**Weaknesses:** Requires GPU for reasonable performance (CPU is 10x slower). `nomic-embed-text`'s 2048-token ceiling requires chunking most real-world Rails units, switch to `bge-m3` for fewer chunks if disk space allows.

**Best for:** Security-sensitive environments, air-gapped networks, cost-sensitive at scale.

> Ollama's `/api/embed` enforces the model's native context length regardless of the `options.num_ctx` override ([ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)). Woods advertises the native ceiling per model so the chunker sizes inputs correctly, see [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md).

### Implemented provider boundary

`Builder#build_embedding_provider` accepts `:openai`, `:ollama`, and `:fake`.
The fake provider is deterministic and offline for specs, CI, and sandbox
contract tests; it does not represent semantic quality. Other values raise
`ArgumentError`. Voyage Code 3/2 and Anthropic embeddings are not wired up:

- **Voyage Code 3 / Code 2**: code-specialized embeddings (1024/1536 dims, up to 32K token context). Would be the best-quality option for code retrieval if implemented; there is no `Woods::Embedding::Provider::Voyage` today.
- **Anthropic**: Anthropic does not currently offer a standalone embedding API. Monitor for availability.

### Embedding Selection Guidance (implemented providers only)

| Priority | Recommendation |
|----------|---------------|
| **Best general-purpose** | OpenAI text-embedding-3-small |
| **Lowest cost / no external dependencies** | Ollama + `nomic-embed-text` |
| **Self-hosted + large units** | Ollama + `bge-m3` (8192-token context vs. 2048) |
| **Maximum quality** | OpenAI text-embedding-3-large |
| **Offline deterministic tests** | `:fake` (contract testing only, not semantic ranking) |

**Critical consideration:** Embedding dimensions must match across your entire index. Changing embedding providers or models requires a full re-index, `rake woods:embed` raises `Woods::MCP::DimensionMismatch` before embedding anything when the configured provider's dimension disagrees with the store's.

---

## Metadata Stores

`build_metadata_store` accepts `:in_memory` and `:sqlite`. Nothing else is implemented.

### SQLite

**Best for:** Local development, zero-dependency setups, testing, and every shipped preset except pure in-memory.

**Key features:**
- JSON1 extension for metadata queries
- FTS5 for full-text search
- Zero setup, single-file database (`metadata.sqlite3` under `output_dir`)

**Limitations:**
- Single writer at a time
- No network access

### In-Memory

**Best for:** Testing, evaluation, small codebases.

Loads from extracted JSON files on startup. All queries run against in-memory hash maps. Fast but ephemeral, nothing survives a process restart without the `Snapshotter` dump (see the Persistence Story table above).

### Not implemented

A PostgreSQL or MySQL metadata store (JSONB/JSON columns, generated columns, full-text search, recursive-CTE graph dual-use) is a plausible future adapter, `config.metadata_store = :postgresql` or `:mysql` today raises `ArgumentError: Unknown metadata_store`, and `metadata_store_connection` is not a `Configuration` accessor. For MySQL- or PostgreSQL-backed deployments today, pair `:sqlite` metadata with your vector store of choice (`:pgvector` or `:qdrant`).

---

## Graph Stores

`build_graph_store` accepts `:in_memory` only.

### In-Memory (the only shipped graph store)

Loads `dependency_graph.json` into a Ruby hash structure. Supports BFS traversal with visited set, PageRank scoring, and structural analysis via `GraphAnalyzer` (orphan detection, dead-end detection, hub identification, cycle detection, bridge detection). Suitable for up to ~5000 nodes.

**Memory:** ~10MB for 2000 nodes with average 5 edges each.
**Traversal:** < 1ms for depth-2 BFS.
**Analysis:** `GraphAnalyzer` provides `orphans`, `dead_ends`, `hubs(limit:)`, `cycles`, `bridges(limit:, sample_size:)`, `domain_clusters`, and a combined `analyze` method.

### Not implemented

A recursive-CTE graph store (MySQL 8.0+ or PostgreSQL, storing edges in a table and traversing with `WITH RECURSIVE`) or Neo4j would only matter past ~50,000 nodes, or for cross-repository tracing and algorithms beyond PageRank/hub/bridge/cycle detection (weighted shortest path, community detection). Neither exists in the shipped gem; `config.graph_store` set to anything but `:in_memory` raises.

---

## Background Job Integration

Indexing can be triggered synchronously (rake task, inline) or from a background job. The pipeline itself is job-system-agnostic, it's synchronous Ruby, and the wrapper below is just scheduling and concurrency control. Use `Woods.extract!` for a full run; incremental runs need a changed-file list, so a job usually just shells out to `rake woods:incremental` (which computes that list from git) rather than calling `Woods.extract_changed!` directly.

### Sidekiq

```ruby
class WoodsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 2

  def perform(mode = "full")
    case mode
    when "full" then Woods.extract!
    when "incremental" then Rake::Task["woods:incremental"].invoke
    end
  end
end
```

### Solid Queue (Rails 8)

```ruby
class WoodsJob < ApplicationJob
  queue_as :low_priority
  limits_concurrency to: 1, key: "woods"

  def perform(mode = "full")
    case mode
    when "full" then Woods.extract!
    when "incremental" then Rake::Task["woods:incremental"].invoke
    end
  end
end
```

### GoodJob

```ruby
class WoodsJob < ApplicationJob
  queue_as :utility
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(mode = "full")
    # Same interface as above
  end
end
```

### Inline (Development/CI)

```ruby
# No job system needed
Woods.extract!
```

---

## Recommended Stack Combinations

### Starter (Local Dependencies)

```ruby
Woods.configure_with_preset(:local)
# Vector: InMemory VectorStore
# Metadata: SQLite
# Graph: In-memory
# Embedding: Ollama (nomic-embed-text)
# Jobs: Inline
```

**Setup:** add the `sqlite3` gem, then install/start Ollama and run
`ollama pull nomic-embed-text`.
**Tradeoff:** Lower retrieval quality, CPU-bound embedding, single-user.

### Rails 8 Standard

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end
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
# No dedicated :mysql preset exists. Use :production and reuse your MySQL
# connection for the app itself: Woods' own metadata store stays SQLite.
Woods.configure_with_preset(:production) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # only for a deliberately trusted private endpoint
  }
end
# Vector: Qdrant
# Metadata: SQLite
# Graph: In-memory
# Embedding: OpenAI
# Jobs: Sidekiq
```

**Setup:** Add Qdrant to docker-compose.
**Tradeoff:** Leverages existing MySQL infrastructure for the app; Qdrant handles vector search, which MySQL can't do natively. Most natural fit for established Rails apps on MySQL/Percona with Docker and Sidekiq.

### Fully Self-Hosted

```ruby
# No dedicated :self_hosted preset exists. Use :production, then override
# embedding_provider to :ollama.
Woods.configure_with_preset(:production) do |config|
  config.embedding_provider = :ollama
  config.embedding_options = {
    model: 'nomic-embed-text',
    host: ENV.fetch('OLLAMA_URL', 'http://localhost:11434')
  }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # Qdrant is deliberately self-hosted/private here
  }
end
# Vector: Qdrant
# Metadata: SQLite
# Graph: In-memory
# Embedding: Ollama (nomic-embed-text or bge-m3)
```

**Setup:** Qdrant + Ollama in docker-compose.
**Tradeoff:** No external API calls, all data stays on-premise. Works with either database. Embedding quality depends on model choice.

---

## Cost and Scale Guidance

Embedding and vector-storage cost are not the bottleneck for a single-codebase index, the numbers below are the reasoning, not a budgeting exercise.

- **Embedding cost is driven by token count, not unit count.** Each unit produces roughly 1–4 chunks (hierarchical chunking: one summary chunk plus semantic sub-chunks), each with a small context prefix. At OpenAI's `text-embedding-3-small` price (~$0.02/1M tokens), a full re-index of a codebase in the thousands-of-units range costs cents, not dollars. Ollama costs nothing per token but requires GPU time.
- **Incremental re-embedding is cheaper still.** Chunk checksumming means only chunks whose source actually changed get re-embedded, a typical merge touches a handful of units.
- **Query-time embedding cost scales with query volume, not index size.** One embedding call per `codebase_retrieve` query; even four-digit daily query volumes stay cheap with the small model.
- **Vector storage is `dimensions × 4 bytes` per vector**, plus adapter overhead. At 1536 dimensions and a few thousand chunks, this is single-digit megabytes, negligible next to the database or Qdrant container it lives in.
- **Infrastructure cost is the real variable.** `:local` and `:postgresql` add no new service. `:production` (Qdrant) adds one container (~300MB RAM) or a managed-cloud free tier.

The actual cost driver is developer time: initial setup (an hour or so per preset), and occasional tuning of chunking/ranking if retrieval quality needs adjustment. Choose the preset that fits infrastructure you already run, the numbers above rarely change that decision.
