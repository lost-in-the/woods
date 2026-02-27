# Retrieval Layer Architecture

## Overview

This document defines the retrieval architecture for CodebaseIndex—the system that transforms extracted codebase data into contextually relevant responses for AI-assisted development.

The design prioritizes **adaptability**: while the reference implementation targets a large Rails monolith with MySQL/Redis/Sidekiq, the architecture accommodates PostgreSQL, SQLite, Solid Queue, and other variations through pluggable backends.

---

## Table of Contents

1. [Design Principles](#design-principles)
2. [System Architecture](#system-architecture)
3. [Query Classification](#query-classification)
4. [Search Strategies](#search-strategies)
5. [Storage Backends](#storage-backends)
6. [Embedding Pipeline](#embedding-pipeline)
7. [Context Assembly](#context-assembly)
8. [Ranking & Relevance](#ranking--relevance)
9. [Interface Layer](#interface-layer)
10. [Configuration & Adaptability](#configuration--adaptability)
11. [Reference Implementation](#reference-implementation)
12. [Future Considerations](#future-considerations)

---

## Design Principles

### 1. Backend Agnosticism

The retrieval layer must not assume any specific:
- Vector store (Qdrant, Pgvector, Pinecone, FAISS, SQLite-vss)
- Embedding provider (OpenAI, Voyage, Cohere, local models)
- Primary database (MySQL, PostgreSQL, SQLite)
- Background job system (Sidekiq, Solid Queue, GoodJob, DelayedJob)

Each integration point is defined by an interface (Ruby module) with swappable implementations.

### 2. Layered Retrieval

Different queries need different retrieval strategies. A question about "how checkout works" requires broad context assembly; "what's the User model's primary key" needs precise lookup. The system classifies queries and selects appropriate strategies.

### 3. Token Budget Awareness

LLM context windows are finite. The retrieval layer must:
- Track token counts for all retrieved content
- Allocate budget across context layers (structural, primary, supporting, framework)
- Truncate intelligently when over budget
- Prioritize high-relevance content

### 4. Incremental & Continuous

Retrieval indexes must support:
- Full rebuild (initial indexing)
- Incremental updates (CI integration)
- Hot reloading (development mode)
- Version tracking (correlate index state with git SHA)

### 5. Observability

Every retrieval operation should be traceable:
- What query came in
- How it was classified
- What search strategies were used
- What was retrieved and why
- What was included in final context and why

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Query Interface                                 │
│                   (Ruby API / CLI / HTTP / Editor Plugin)                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Query Classifier                                  │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   Intent    │  │   Scope     │  │   Depth     │  │  Framework  │        │
│  │  Detection  │  │  Detection  │  │  Detection  │  │  Detection  │        │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Strategy Selector                                  │
│                                                                             │
│  Chooses retrieval strategy based on classification:                        │
│  • Vector Search (semantic similarity)                                      │
│  • Keyword Search (exact identifiers)                                       │
│  • Graph Traversal (dependency following)                                   │
│  • Hybrid (combined approaches)                                             │
│  • Direct Lookup (known identifier)                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Search Executor                                   │
│                                                                             │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
│  │  Vector Store    │  │  Metadata Store  │  │  Graph Store     │          │
│  │  (embeddings)    │  │  (attributes)    │  │  (dependencies)  │          │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘          │
│           │                     │                     │                     │
│           └─────────────────────┴─────────────────────┘                     │
│                                 │                                           │
│                                 ▼                                           │
│                        Candidate Set                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Ranker                                          │
│                                                                             │
│  Re-ranks candidates based on:                                              │
│  • Semantic relevance score                                                 │
│  • Recency (git data)                                                       │
│  • Importance (complexity metrics)                                          │
│  • Query-specific signals                                                   │
│  • Diversity (avoid redundant content)                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Context Assembler                                   │
│                                                                             │
│  Budget Allocation:                                                         │
│  ├── 10%  Structural Overview (always included)                             │
│  ├── 50%  Primary Results                                                   │
│  ├── 25%  Supporting Context (dependencies, related)                        │
│  └── 15%  Framework Reference (when needed)                                 │
│                                                                             │
│  Operations:                                                                │
│  • Token counting                                                           │
│  • Deduplication                                                            │
│  • Ordering (relevance vs logical flow)                                     │
│  • Metadata stripping for output                                            │
│  • Source attribution                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Response                                        │
│                                                                             │
│  {                                                                          │
│    context: "...",           # Assembled context string                     │
│    tokens_used: 4521,        # Actual token count                           │
│    sources: [...],           # Attribution for retrieved units              │
│    classification: {...},    # How query was classified                     │
│    strategy: "hybrid",       # Which strategy was used                      │
│    trace: {...}              # Full retrieval trace for debugging           │
│  }                                                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Query Classification

The classifier analyzes incoming queries to determine optimal retrieval strategy.

### Classification Dimensions

#### 1. Intent

What is the user trying to accomplish?

| Intent | Description | Example Queries |
|--------|-------------|-----------------|
| `understand` | Learn how something works | "How does checkout work?" |
| `locate` | Find where something is | "Where is the order validation?" |
| `trace` | Follow execution/data flow | "What happens when an order is placed?" |
| `debug` | Investigate an issue | "Why might this callback fail?" |
| `implement` | Build something new | "How should I add a discount type?" |
| `reference` | Quick factual lookup | "What's the User table's primary key?" |
| `compare` | Understand differences | "How do ProductOption and OptionGroup differ?" |
| `framework` | Rails/gem behavior | "What options does has_many support?" |

#### 2. Scope

How broad is the query?

| Scope | Description | Retrieval Approach |
|-------|-------------|-------------------|
| `pinpoint` | Single unit/fact | Direct lookup, minimal expansion |
| `focused` | Small cluster of related units | Vector search + immediate dependencies |
| `exploratory` | Broad area of codebase | Multi-query, graph traversal |
| `comprehensive` | Full feature/flow | Heavy graph traversal, high token budget |

#### 3. Target Type

What kind of code unit is being asked about?

- `model` - ActiveRecord models
- `controller` - Request handlers
- `service` - Service objects
- `job` - Background workers
- `mailer` - Email senders
- `component` - View components
- `graphql_type` - GraphQL object types, input types, enums, unions, interfaces
- `graphql_mutation` - GraphQL mutations
- `graphql_resolver` - GraphQL resolvers
- `graphql_query` - GraphQL query fields
- `framework` - Rails/gem internals
- `schema` - Database structure
- `route` - URL mappings
- `unknown` - Needs inference

#### 4. Framework Context

Does this query need Rails/gem source context?

| Signal | Interpretation |
|--------|---------------|
| "what options does X support" | Framework reference needed |
| "how does Rails implement Y" | Framework reference needed |
| "is Z deprecated" | Framework reference needed |
| "how do we handle X" | Application code focus |
| "where is our Y logic" | Application code focus |

### Classifier Implementation

```ruby
# Pseudocode for query classification
module CodebaseIndex
  module Retrieval
    class QueryClassifier
      def classify(query, context: {})
        {
          intent: detect_intent(query),
          scope: detect_scope(query),
          target_type: detect_target_type(query, context),
          framework_context: needs_framework_context?(query),
          
          # Extracted entities
          entities: extract_entities(query),
          
          # Confidence scores
          confidence: {
            intent: 0.85,
            scope: 0.72,
            target_type: 0.91
          }
        }
      end
      
      private
      
      def detect_intent(query)
        # Pattern matching + embedding similarity to intent exemplars
        # Returns: [:understand, :locate, :trace, :debug, :implement, :reference, :compare, :framework]
      end
      
      def detect_scope(query)
        # Heuristics:
        # - Question words: "what is" → pinpoint, "how does...work" → focused/exploratory
        # - Plural vs singular: "the model" → pinpoint, "models" → exploratory
        # - Breadth indicators: "all", "every", "across" → comprehensive
        # Returns: [:pinpoint, :focused, :exploratory, :comprehensive]
      end
      
      def detect_target_type(query, context)
        # Entity extraction + context clues
        # "User model" → :model
        # "checkout controller" → :controller
        # "order processing" → :unknown (needs inference)
      end
      
      def needs_framework_context?(query)
        framework_signals = [
          /what options does .* support/i,
          /how does rails/i,
          /what callbacks/i,
          /is .* deprecated/i,
          /activerecord|actioncontroller|activejob/i,
          /rails (source|implementation|internals)/i
        ]
        framework_signals.any? { |pattern| query.match?(pattern) }
      end
      
      def extract_entities(query)
        # Extract mentioned identifiers
        # "How does the User model validate emails?"
        # → { models: ["User"], methods: ["validate"], concepts: ["emails"] }
      end
    end
  end
end
```

### Classification Examples

```yaml
# Example 1: Pinpoint reference
query: "What's the primary key for the Order model?"
classification:
  intent: reference
  scope: pinpoint
  target_type: model
  framework_context: false
  entities:
    models: ["Order"]
    attributes: ["primary_key"]
strategy: direct_lookup

# Example 2: Focused understanding
query: "How does the checkout process validate addresses?"
classification:
  intent: understand
  scope: focused
  target_type: unknown  # Could be service, controller, or model
  framework_context: false
  entities:
    concepts: ["checkout", "validate", "addresses"]
strategy: vector_search + dependency_expansion

# Example 3: Framework reference
query: "What options does belongs_to support in Rails 7?"
classification:
  intent: framework
  scope: pinpoint
  target_type: framework
  framework_context: true
  entities:
    framework_concepts: ["belongs_to", "options"]
strategy: framework_source_search

# Example 4: Comprehensive trace
query: "Walk me through what happens when a customer places an order"
classification:
  intent: trace
  scope: comprehensive
  target_type: unknown
  framework_context: false
  entities:
    concepts: ["customer", "order", "places"]
strategy: graph_traversal + vector_search
```

---

## Search Strategies

Based on classification, the system selects and executes one or more search strategies.

### Strategy: Vector Search

**When to use:** Semantic similarity queries, concept-based lookups, exploratory questions.

```ruby
module CodebaseIndex
  module Retrieval
    module Strategies
      class VectorSearch
        def initialize(vector_store:, embedding_provider:)
          @vector_store = vector_store
          @embedding_provider = embedding_provider
        end
        
        def search(query, filters: {}, limit: 20)
          # 1. Generate query embedding
          query_embedding = @embedding_provider.embed(query)
          
          # 2. Search vector store with optional filters
          results = @vector_store.search(
            vector: query_embedding,
            filters: filters,  # e.g., { type: :model, namespace: "Checkout" }
            limit: limit
          )
          
          # 3. Return candidates with scores
          results.map do |result|
            Candidate.new(
              identifier: result.identifier,
              score: result.similarity,
              source: :vector_search,
              metadata: result.metadata
            )
          end
        end
      end
    end
  end
end
```

**Filter patterns:**

```ruby
# Type-scoped search
vector_search.search("order validation", filters: { type: :model })

# Namespace-scoped search
vector_search.search("payment processing", filters: { namespace: "Billing" })

# Recency-weighted search
vector_search.search("recent changes to checkout", filters: { change_frequency: [:hot, :active] })

# Combined filters
vector_search.search(
  "discount calculation",
  filters: {
    type: [:model, :service],
    namespace: ["Billing", "Checkout"],
    change_frequency: [:hot, :active, :stable]
  }
)
```

### Strategy: Keyword Search

**When to use:** Exact identifier lookups, class/method name searches, grep-style queries.

```ruby
module CodebaseIndex
  module Retrieval
    module Strategies
      class KeywordSearch
        def initialize(metadata_store:)
          @metadata_store = metadata_store
        end
        
        def search(keywords, filters: {}, limit: 20)
          # Search against indexed identifiers, method names, etc.
          results = @metadata_store.search_keywords(
            keywords: keywords,
            fields: [:identifier, :method_names, :association_names, :column_names],
            filters: filters,
            limit: limit
          )
          
          results.map do |result|
            Candidate.new(
              identifier: result.identifier,
              score: result.match_score,
              source: :keyword_search,
              metadata: result.metadata,
              matched_fields: result.matched_fields
            )
          end
        end
      end
    end
  end
end
```

**Use cases:**

```ruby
# Find by class name
keyword_search.search(["User", "Account"])

# Find by method name
keyword_search.search(["validate_email", "process_payment"])

# Find by column name
keyword_search.search(["stripe_customer_id"], filters: { type: :model })
```

### Strategy: Graph Traversal

**When to use:** Dependency tracing, impact analysis, "what uses X" queries.

```ruby
module CodebaseIndex
  module Retrieval
    module Strategies
      class GraphTraversal
        def initialize(graph_store:)
          @graph_store = graph_store
        end
        
        # Find everything that depends on a unit
        def dependents_of(identifier, depth: 2)
          @graph_store.traverse_reverse(
            start: identifier,
            max_depth: depth
          )
        end
        
        # Find everything a unit depends on
        def dependencies_of(identifier, depth: 2)
          @graph_store.traverse_forward(
            start: identifier,
            max_depth: depth
          )
        end
        
        # Find units related by shared dependencies
        def related_to(identifier, relationship_types: nil)
          direct_deps = @graph_store.dependencies_of(identifier)
          
          # Find other units that share these dependencies
          direct_deps.flat_map do |dep|
            @graph_store.dependents_of(dep)
          end.uniq - [identifier]
        end
        
        # Trace a path between two units
        def path_between(from:, to:)
          @graph_store.shortest_path(from, to)
        end
      end
    end
  end
end
```

**Use cases:**

```ruby
# "What would be affected if I change the Order model?"
graph.dependents_of("Order", depth: 2)
# Returns: OrdersController, CheckoutService, OrderMailer, OrderWebhookWorker, ...

# "What does CheckoutService depend on?"
graph.dependencies_of("CheckoutService", depth: 1)
# Returns: Order, Cart, PaymentGateway, ShippingCalculator, ...

# "How is Order related to Shipment?"
graph.path_between(from: "Order", to: "Shipment")
# Returns: Order -> OrderItem -> Shipment
```

### Strategy: Hybrid Search

**When to use:** Most queries benefit from combining strategies.

```ruby
module CodebaseIndex
  module Retrieval
    module Strategies
      class HybridSearch
        def initialize(vector_search:, keyword_search:, graph_traversal:)
          @vector = vector_search
          @keyword = keyword_search
          @graph = graph_traversal
        end
        
        def search(query, classification:, limit: 30)
          candidates = []
          
          # 1. Vector search for semantic matches
          candidates += @vector.search(query, limit: limit)
          
          # 2. Keyword search for exact matches (if entities extracted)
          if classification[:entities][:models].any?
            candidates += @keyword.search(
              classification[:entities][:models],
              filters: { type: :model }
            )
          end
          
          # 3. Graph expansion for top vector results
          top_identifiers = candidates.first(5).map(&:identifier)
          top_identifiers.each do |id|
            # Add immediate dependencies
            candidates += @graph.dependencies_of(id, depth: 1).map do |dep|
              Candidate.new(
                identifier: dep,
                score: 0.5,  # Lower score for expanded results
                source: :graph_expansion,
                expanded_from: id
              )
            end
          end
          
          # 4. Deduplicate and merge scores
          merge_candidates(candidates)
        end
        
        private
        
        def merge_candidates(candidates)
          # Reciprocal Rank Fusion (RRF) — robust score merging across
          # heterogeneous retrieval sources without score normalization.
          #
          # RRF formula: score(d) = Σ 1/(k + rank_i(d))
          # where k = 60 (standard constant that controls rank vs score balance)
          #
          # Each source's candidates are ranked independently, then RRF
          # combines ranks into a single score. This avoids the problem of
          # comparing vector similarity scores (0.0-1.0) against keyword
          # match scores (arbitrary range) or graph expansion scores.
          k = 60

          # Build per-source ranked lists
          by_source = candidates.group_by(&:source)
          ranked_lists = by_source.transform_values do |source_candidates|
            source_candidates.sort_by { |c| -c.score }.each_with_index.to_a
          end

          # Compute RRF score per identifier
          rrf_scores = Hash.new(0.0)
          source_map = Hash.new { |h, id| h[id] = [] }
          metadata_map = {}

          ranked_lists.each do |source, ranked|
            ranked.each do |candidate, rank|
              rrf_scores[candidate.identifier] += 1.0 / (k + rank)
              source_map[candidate.identifier] << source
              metadata_map[candidate.identifier] ||= candidate.metadata
            end
          end

          # Build merged candidates sorted by RRF score
          rrf_scores
            .sort_by { |_id, score| -score }
            .map do |identifier, score|
              Candidate.new(
                identifier: identifier,
                score: score,
                sources: source_map[identifier].uniq,
                metadata: metadata_map[identifier]
              )
            end
        end
      end
    end
  end
end
```

### Strategy: Direct Lookup

**When to use:** Known identifier, pinpoint queries.

```ruby
module CodebaseIndex
  module Retrieval
    module Strategies
      class DirectLookup
        def initialize(unit_store:)
          @unit_store = unit_store
        end
        
        def lookup(identifier)
          unit = @unit_store.find(identifier)
          return nil unless unit
          
          Candidate.new(
            identifier: identifier,
            score: 1.0,
            source: :direct_lookup,
            metadata: unit.metadata,
            content: unit.source_code
          )
        end
        
        def lookup_many(identifiers)
          identifiers.filter_map { |id| lookup(id) }
        end
      end
    end
  end
end
```

---

## Storage Backends

The retrieval layer defines interfaces for three storage concerns, each with pluggable implementations.

### Vector Store Interface

```ruby
module CodebaseIndex
  module Storage
    module VectorStore
      # Interface that all vector store implementations must satisfy
      module Interface
        # Store a vector with metadata
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] Embedding vector
        # @param metadata [Hash] Filterable attributes
        def upsert(id:, vector:, metadata:)
          raise NotImplementedError
        end
        
        # Batch upsert for efficiency
        def upsert_batch(items)
          raise NotImplementedError
        end
        
        # Search for similar vectors
        # @param vector [Array<Float>] Query vector
        # @param filters [Hash] Metadata filters
        # @param limit [Integer] Max results
        # @return [Array<SearchResult>]
        def search(vector:, filters: {}, limit: 10)
          raise NotImplementedError
        end
        
        # Delete vectors
        def delete(ids)
          raise NotImplementedError
        end
        
        # Delete all vectors matching filter
        def delete_by_filter(filters)
          raise NotImplementedError
        end
      end
    end
  end
end
```

#### Implementation: Qdrant

```ruby
module CodebaseIndex
  module Storage
    module VectorStore
      class Qdrant
        include Interface
        
        def initialize(url:, collection:, api_key: nil)
          @client = QdrantClient.new(url: url, api_key: api_key)
          @collection = collection
        end
        
        def upsert(id:, vector:, metadata:)
          @client.upsert_points(
            collection_name: @collection,
            points: [{
              id: id,
              vector: vector,
              payload: metadata
            }]
          )
        end
        
        def search(vector:, filters: {}, limit: 10)
          qdrant_filter = build_filter(filters)
          
          results = @client.search(
            collection_name: @collection,
            query_vector: vector,
            filter: qdrant_filter,
            limit: limit
          )
          
          results.map do |r|
            SearchResult.new(
              identifier: r.id,
              similarity: r.score,
              metadata: r.payload
            )
          end
        end
        
        private
        
        def build_filter(filters)
          return nil if filters.empty?
          
          conditions = filters.map do |key, value|
            if value.is_a?(Array)
              { key: key.to_s, match: { any: value.map(&:to_s) } }
            else
              { key: key.to_s, match: { value: value.to_s } }
            end
          end
          
          { must: conditions }
        end
      end
    end
  end
end
```

#### Implementation: Pgvector

```ruby
module CodebaseIndex
  module Storage
    module VectorStore
      class Pgvector
        include Interface
        
        def initialize(connection_string:, table_name: "codebase_embeddings")
          @conn = PG.connect(connection_string)
          @table = table_name
          ensure_extension
          ensure_table
        end
        
        def upsert(id:, vector:, metadata:)
          @conn.exec_params(
            "INSERT INTO #{@table} (id, embedding, metadata)
             VALUES ($1, $2, $3)
             ON CONFLICT (id) DO UPDATE
             SET embedding = $2, metadata = $3",
            [id, "[#{vector.join(',')}]", metadata.to_json]
          )
        end
        
        def search(vector:, filters: {}, limit: 10)
          where_clause, filter_params = build_where(filters)

          results = @conn.exec_params(
            "SELECT id, metadata, 1 - (embedding <=> $1) as similarity
             FROM #{@table}
             #{where_clause}
             ORDER BY embedding <=> $1
             LIMIT $2",
            ["[#{vector.join(',')}]", limit, *filter_params]
          )
          
          results.map do |r|
            SearchResult.new(
              identifier: r["id"],
              similarity: r["similarity"].to_f,
              metadata: JSON.parse(r["metadata"])
            )
          end
        end
        
        private
        
        def ensure_extension
          @conn.exec("CREATE EXTENSION IF NOT EXISTS vector")
        end
        
        def ensure_table
          @conn.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{@table} (
              id TEXT PRIMARY KEY,
              embedding vector(1536),
              metadata JSONB,
              created_at TIMESTAMP DEFAULT NOW(),
              updated_at TIMESTAMP DEFAULT NOW()
            )
          SQL
          @conn.exec("CREATE INDEX IF NOT EXISTS #{@table}_embedding_idx ON #{@table} USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)")
        end
        
        ALLOWED_FILTER_KEYS = %w[type namespace file_path change_frequency importance].freeze

        def build_where(filters)
          return ["", []] if filters.empty?

          conditions = []
          params = []
          # Parameter index starts after the vector ($1) and limit ($2) params
          param_idx = 3

          filters.each do |key, value|
            key_s = key.to_s
            unless ALLOWED_FILTER_KEYS.include?(key_s)
              raise ArgumentError, "Unknown filter key: #{key_s}. Allowed: #{ALLOWED_FILTER_KEYS.join(', ')}"
            end

            quoted_key = PG::Connection.quote_ident(key_s)

            if value.is_a?(Array)
              placeholders = value.map { params << _1.to_s; "$#{param_idx}".tap { param_idx += 1 } }
              conditions << "metadata->>#{quoted_key} IN (#{placeholders.join(',')})"
            else
              conditions << "metadata->>#{quoted_key} = $#{param_idx}"
              params << value.to_s
              param_idx += 1
            end
          end

          ["WHERE #{conditions.join(' AND ')}", params]
        end
      end
    end
  end
end
```

#### Implementation: SQLite + FAISS (Local/Development)

```ruby
module CodebaseIndex
  module Storage
    module VectorStore
      class SqliteFaiss
        include Interface
        
        # Lightweight implementation for local development
        # Uses SQLite for metadata, FAISS for vector search
        
        def initialize(db_path:, index_path:, dimensions: 1536)
          @db = SQLite3::Database.new(db_path)
          @dimensions = dimensions
          @index_path = index_path
          
          ensure_tables
          load_or_create_index
        end
        
        # ... implementation details
      end
    end
  end
end
```

### Metadata Store Interface

For structured queries on extracted metadata (not vector similarity).

```ruby
module CodebaseIndex
  module Storage
    module MetadataStore
      module Interface
        # Store unit metadata
        def upsert(id:, metadata:)
          raise NotImplementedError
        end
        
        # Find by ID
        def find(id)
          raise NotImplementedError
        end
        
        # Search by keyword across specified fields
        def search_keywords(keywords:, fields:, filters: {}, limit: 10)
          raise NotImplementedError
        end
        
        # Query by metadata attributes
        def query(filters:, limit: 100)
          raise NotImplementedError
        end
        
        # List all units of a type
        def list_by_type(type, limit: 1000)
          raise NotImplementedError
        end
      end
    end
  end
end
```

#### Implementations

- **PostgreSQL** - Full-featured, JSON operators for metadata queries
- **MySQL** - JSON functions for metadata, full-text for keywords
- **SQLite** - Lightweight, JSON1 extension for metadata
- **In-Memory** - For testing, loads from JSON files

### Graph Store Interface

For dependency graph operations.

```ruby
module CodebaseIndex
  module Storage
    module GraphStore
      module Interface
        # Register a node with its edges
        def register(id:, type:, edges:)
          raise NotImplementedError
        end
        
        # Get direct dependencies
        def dependencies_of(id)
          raise NotImplementedError
        end
        
        # Get direct dependents
        def dependents_of(id)
          raise NotImplementedError
        end
        
        # Traverse forward (dependencies) up to max_depth
        def traverse_forward(start:, max_depth:)
          raise NotImplementedError
        end
        
        # Traverse reverse (dependents) up to max_depth
        def traverse_reverse(start:, max_depth:)
          raise NotImplementedError
        end
        
        # Find shortest path between two nodes
        def shortest_path(from, to)
          raise NotImplementedError
        end
        
        # Get subgraph containing specified types
        # Supported types include: :model, :controller, :service, :job, :mailer,
        # :component, :graphql_type, :graphql_mutation, :graphql_resolver,
        # :graphql_query, :rails_source
        def subgraph_for_types(types)
          raise NotImplementedError
        end
      end
    end
  end
end
```

#### Implementations

- **In-Memory** - Default, loaded from dependency_graph.json
- **PostgreSQL** - Using recursive CTEs for traversal
- **Neo4j** - For very large graphs (optional advanced backend)
- **SQLite** - Recursive CTEs work here too

---

## Embedding Pipeline

The embedding pipeline transforms extracted units into vectors for semantic search.

### Pipeline Architecture

```
Extracted Units (JSON)
        │
        ▼
┌───────────────────┐
│  Chunker          │  Split large units, preserve context
└───────────────────┘
        │
        ▼
┌───────────────────┐
│  Text Preparer    │  Format for embedding (strip noise, add context)
└───────────────────┘
        │
        ▼
┌───────────────────┐
│  Embedding        │  Generate vectors (batched)
│  Provider         │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│  Vector Store     │  Persist with metadata
└───────────────────┘
```

### Embedding Provider Interface

```ruby
module CodebaseIndex
  module Embedding
    module Provider
      module Interface
        # Embed a single text
        # @param text [String]
        # @return [Array<Float>] Vector
        def embed(text)
          raise NotImplementedError
        end
        
        # Embed multiple texts (batched for efficiency)
        # @param texts [Array<String>]
        # @return [Array<Array<Float>>] Vectors
        def embed_batch(texts)
          raise NotImplementedError
        end
        
        # Vector dimensions
        def dimensions
          raise NotImplementedError
        end
        
        # Model identifier
        def model_name
          raise NotImplementedError
        end
      end
    end
  end
end
```

#### Implementation: OpenAI

```ruby
module CodebaseIndex
  module Embedding
    module Provider
      class OpenAI
        include Interface
        
        MODELS = {
          "text-embedding-3-small" => { dimensions: 1536, max_tokens: 8191 },
          "text-embedding-3-large" => { dimensions: 3072, max_tokens: 8191 },
          "text-embedding-ada-002" => { dimensions: 1536, max_tokens: 8191 }  # Legacy — use text-embedding-3-small instead
        }.freeze

        def initialize(api_key:, model: "text-embedding-3-small")
          @client = OpenAI::Client.new(api_key: api_key)
          @model = model
          @config = MODELS.fetch(model)
        end
        
        def embed(text)
          response = @client.embeddings(
            model: @model,
            input: truncate(text)
          )
          response.dig("data", 0, "embedding")
        end
        
        def embed_batch(texts, batch_size: 100)
          texts.each_slice(batch_size).flat_map do |batch|
            response = @client.embeddings(
              model: @model,
              input: batch.map { |t| truncate(t) }
            )
            response["data"].sort_by { |d| d["index"] }.map { |d| d["embedding"] }
          end
        end
        
        def dimensions
          @config[:dimensions]
        end
        
        def model_name
          @model
        end
        
        private
        
        def truncate(text)
          # Rough token estimation: ~4 chars per token
          max_chars = @config[:max_tokens] * 4
          text.length > max_chars ? text[0...max_chars] : text
        end
      end
    end
  end
end
```

#### Implementation: Voyage

```ruby
module CodebaseIndex
  module Embedding
    module Provider
      class Voyage
        include Interface
        
        MODELS = {
          "voyage-code-3" => { dimensions: 1024, max_tokens: 32000 },
          "voyage-code-2" => { dimensions: 1536, max_tokens: 16000 },
          "voyage-large-2" => { dimensions: 1536, max_tokens: 16000 }
        }.freeze

        def initialize(api_key:, model: "voyage-code-3")
          @api_key = api_key
          @model = model
          @config = MODELS.fetch(model)
        end
        
        def embed(text)
          embed_batch([text]).first
        end
        
        def embed_batch(texts)
          response = HTTP.auth("Bearer #{@api_key}")
            .post("https://api.voyageai.com/v1/embeddings",
              json: {
                model: @model,
                input: texts,
                input_type: "document"
              }
            )
          
          JSON.parse(response.body)["data"]
            .sort_by { |d| d["index"] }
            .map { |d| d["embedding"] }
        end
        
        def dimensions
          @config[:dimensions]
        end
        
        def model_name
          @model
        end
      end
    end
  end
end
```

#### Implementation: Local (Ollama/Nomic)

```ruby
module CodebaseIndex
  module Embedding
    module Provider
      class Ollama
        include Interface
        
        def initialize(url: "http://localhost:11434", model: "nomic-embed-text")
          @url = url
          @model = model
        end
        
        def embed(text)
          response = HTTP.post(
            "#{@url}/api/embeddings",
            json: { model: @model, prompt: text }
          )
          JSON.parse(response.body)["embedding"]
        end
        
        def embed_batch(texts)
          # Ollama doesn't support batching natively, parallelize
          texts.map { |t| embed(t) }
        end
        
        def dimensions
          768  # nomic-embed-text default
        end
        
        def model_name
          @model
        end
      end
    end
  end
end
```

### Text Preparation

How units are formatted for embedding affects retrieval quality.

```ruby
module CodebaseIndex
  module Embedding
    class TextPreparer
      # Prepare a unit for embedding
      # Goal: Create text that embeds well for semantic search
      
      def prepare(unit)
        case unit.type
        when :model
          prepare_model(unit)
        when :controller
          prepare_controller(unit)
        when :service
          prepare_service(unit)
        when :job
          prepare_job(unit)
        when :graphql_type, :graphql_mutation, :graphql_resolver, :graphql_query
          prepare_graphql(unit)
        when :rails_source
          prepare_framework(unit)
        else
          prepare_generic(unit)
        end
      end
      
      private
      
      def prepare_model(unit)
        parts = []
        
        # Identity
        parts << "Model: #{unit.identifier}"
        parts << "Table: #{unit.metadata[:table_name]}" if unit.metadata[:table_name]
        parts << "Namespace: #{unit.namespace}" if unit.namespace
        
        # Semantic description (generated from metadata)
        parts << describe_associations(unit.metadata[:associations])
        parts << describe_validations(unit.metadata[:validations])
        parts << describe_callbacks(unit.metadata[:callbacks])
        
        # Key code (methods that define behavior)
        parts << "\n# Source:\n#{unit.source_code}"
        
        parts.compact.join("\n")
      end
      
      def describe_associations(associations)
        return nil if associations.nil? || associations.empty?
        
        desc = associations.map do |a|
          "#{a[:type]} #{a[:name]} (#{a[:target]})"
        end.join(", ")
        
        "Associations: #{desc}"
      end
      
      def describe_validations(validations)
        return nil if validations.nil? || validations.empty?
        
        grouped = validations.group_by { |v| v[:attribute] }
        desc = grouped.map do |attr, vals|
          "#{attr}: #{vals.map { |v| v[:type] }.join(', ')}"
        end.join("; ")
        
        "Validations: #{desc}"
      end
      
      def describe_callbacks(callbacks)
        return nil if callbacks.nil? || callbacks.empty?
        
        grouped = callbacks.group_by { |c| c[:type] }
        desc = grouped.map do |type, cbs|
          "#{type}: #{cbs.map { |c| c[:filter] }.join(', ')}"
        end.join("; ")
        
        "Callbacks: #{desc}"
      end
      
      # ... similar methods for other types
    end
  end
end
```

### Indexing Pipeline

```ruby
module CodebaseIndex
  module Embedding
    class IndexingPipeline
      def initialize(
        extracted_dir:,
        vector_store:,
        metadata_store:,
        embedding_provider:,
        text_preparer: TextPreparer.new
      )
        @extracted_dir = Pathname.new(extracted_dir)
        @vector_store = vector_store
        @metadata_store = metadata_store
        @embedding_provider = embedding_provider
        @text_preparer = text_preparer
      end
      
      def index_all
        units = load_all_units
        
        # Prepare texts
        prepared = units.map do |unit|
          {
            unit: unit,
            text: @text_preparer.prepare(unit)
          }
        end
        
        # Generate embeddings in batches
        texts = prepared.map { |p| p[:text] }
        embeddings = @embedding_provider.embed_batch(texts)
        
        # Store vectors and metadata
        prepared.zip(embeddings).each do |item, embedding|
          unit = item[:unit]
          
          @vector_store.upsert(
            id: unit.identifier,
            vector: embedding,
            metadata: {
              type: unit.type.to_s,
              namespace: unit.namespace,
              file_path: unit.file_path,
              change_frequency: unit.metadata.dig(:git, :change_frequency)&.to_s,
              importance: calculate_importance(unit)
            }
          )
          
          @metadata_store.upsert(
            id: unit.identifier,
            metadata: unit.to_h
          )
        end
        
        # Also index chunks for large units
        index_chunks(units)
      end
      
      def index_incremental(changed_identifiers)
        changed_identifiers.each do |identifier|
          # Reload unit from JSON
          unit = load_unit(identifier)
          next unless unit
          
          # Re-embed and store
          text = @text_preparer.prepare(unit)
          embedding = @embedding_provider.embed(text)
          
          @vector_store.upsert(
            id: unit.identifier,
            vector: embedding,
            metadata: build_metadata(unit)
          )
          
          @metadata_store.upsert(
            id: unit.identifier,
            metadata: unit.to_h
          )
        end
      end
      
      private
      
      def load_all_units
        units = []
        
        Dir[@extracted_dir.join("*")].each do |type_dir|
          next unless File.directory?(type_dir)
          next if File.basename(type_dir).start_with?("_")
          
          Dir[File.join(type_dir, "*.json")].each do |file|
            next if File.basename(file).start_with?("_")
            
            data = JSON.parse(File.read(file), symbolize_names: true)
            units << OpenStruct.new(data)
          end
        end
        
        units
      end
      
      def calculate_importance(unit)
        score = 0
        meta = unit.metadata || {}

        # Complexity signals
        score += 2 if (meta[:callback_count] || 0) > 5
        score += 2 if (meta[:association_count] || 0) > 5
        score += 1 if (meta[:loc] || 0) > 200

        # Change signals
        score += 2 if meta.dig(:git, :change_frequency)&.to_sym == :hot

        # Type signals
        score += 1 if unit.type.to_sym == :model
        score += 1 if unit.type.to_sym == :service

        # TODO: Incorporate PageRank score from DependencyGraph#pagerank
        # (damping: 0.85, iterations: 20) as an importance signal.
        # GraphAnalyzer hub/bridge detection can further boost score.
        
        case score
        when 0..2 then "low"
        when 3..5 then "medium"
        else "high"
        end
      end
      
      def index_chunks(units)
        units.each do |unit|
          next if unit.chunks.nil? || unit.chunks.empty?
          
          unit.chunks.each do |chunk|
            text = chunk[:content]
            embedding = @embedding_provider.embed(text)
            
            @vector_store.upsert(
              id: chunk[:identifier],
              vector: embedding,
              metadata: {
                type: "chunk",
                chunk_type: chunk[:chunk_type].to_s,
                parent: unit.identifier,
                parent_type: unit.type.to_s
              }
            )
          end
        end
      end
    end
  end
end
```

---

## Context Assembly

The context assembler transforms retrieved candidates into a token-budgeted context string.

### Budget Allocation Strategy

```ruby
module CodebaseIndex
  module Retrieval
    class ContextAssembler
      DEFAULT_BUDGET = 8000  # tokens
      
      BUDGET_ALLOCATION = {
        structural: 0.10,   # Always-included overview
        primary: 0.50,      # Direct query results
        supporting: 0.25,   # Dependencies, related context
        framework: 0.15     # Rails/gem source (when needed)
      }.freeze
      
      def initialize(
        unit_store:,
        token_counter: TokenCounter.new,
        budget: DEFAULT_BUDGET
      )
        @unit_store = unit_store
        @token_counter = token_counter
        @budget = budget
      end
      
      def assemble(candidates:, classification:, structural_context: nil)
        context_parts = []
        tokens_used = 0
        sources = []
        
        # 1. Structural context (always first)
        if structural_context
          structural_budget = (@budget * BUDGET_ALLOCATION[:structural]).to_i
          structural_text = truncate_to_budget(structural_context, structural_budget)
          context_parts << { section: :structural, content: structural_text }
          tokens_used += @token_counter.count(structural_text)
        end
        
        # 2. Determine budget for other sections
        remaining_budget = @budget - tokens_used
        needs_framework = classification[:framework_context]
        
        if needs_framework
          primary_budget = (remaining_budget * 0.55).to_i
          supporting_budget = (remaining_budget * 0.25).to_i
          framework_budget = (remaining_budget * 0.20).to_i
        else
          primary_budget = (remaining_budget * 0.65).to_i
          supporting_budget = (remaining_budget * 0.35).to_i
          framework_budget = 0
        end
        
        # 3. Primary results
        primary_candidates = candidates.select { |c| c.source != :graph_expansion }
        primary_content, primary_sources = assemble_section(
          primary_candidates,
          primary_budget
        )
        context_parts << { section: :primary, content: primary_content }
        sources.concat(primary_sources)
        
        # 4. Supporting context (expanded dependencies)
        supporting_candidates = candidates.select { |c| c.source == :graph_expansion }
        if supporting_candidates.any?
          supporting_content, supporting_sources = assemble_section(
            supporting_candidates,
            supporting_budget
          )
          context_parts << { section: :supporting, content: supporting_content }
          sources.concat(supporting_sources)
        end
        
        # 5. Framework context (if needed)
        if needs_framework && framework_budget > 0
          framework_candidates = candidates.select { |c| c.metadata[:type] == "rails_source" }
          if framework_candidates.any?
            framework_content, framework_sources = assemble_section(
              framework_candidates,
              framework_budget
            )
            context_parts << { section: :framework, content: framework_content }
            sources.concat(framework_sources)
          end
        end
        
        # 6. Combine and return
        final_context = context_parts.map { |p| p[:content] }.join("\n\n---\n\n")
        final_tokens = @token_counter.count(final_context)
        
        AssembledContext.new(
          context: final_context,
          tokens_used: final_tokens,
          budget: @budget,
          sources: sources.uniq,
          sections: context_parts.map { |p| p[:section] }
        )
      end
      
      private
      
      def assemble_section(candidates, budget)
        content_parts = []
        sources = []
        tokens_used = 0
        
        candidates.sort_by { |c| -c.score }.each do |candidate|
          unit = @unit_store.find(candidate.identifier)
          next unless unit
          
          unit_text = format_unit(unit)
          unit_tokens = @token_counter.count(unit_text)
          
          # Check if we can fit this unit
          if tokens_used + unit_tokens <= budget
            content_parts << unit_text
            sources << {
              identifier: candidate.identifier,
              type: unit[:type],
              score: candidate.score,
              file_path: unit[:file_path]
            }
            tokens_used += unit_tokens
          else
            # Try to fit a truncated version
            remaining = budget - tokens_used
            if remaining > 200  # Minimum useful content
              truncated = truncate_to_budget(unit_text, remaining)
              content_parts << truncated
              sources << {
                identifier: candidate.identifier,
                type: unit[:type],
                score: candidate.score,
                file_path: unit[:file_path],
                truncated: true
              }
            end
            break  # Budget exhausted
          end
        end
        
        [content_parts.join("\n\n"), sources]
      end
      
      def format_unit(unit)
        # Format for inclusion in context
        <<~UNIT
        ## #{unit[:identifier]} (#{unit[:type]})
        File: #{unit[:file_path]}
        
        #{unit[:source_code]}
        UNIT
      end
      
      def truncate_to_budget(text, token_budget)
        current_tokens = @token_counter.count(text)
        return text if current_tokens <= token_budget
        
        # Rough truncation: estimate chars from tokens
        target_chars = (token_budget * 4 * 0.9).to_i  # 10% safety margin
        text[0...target_chars] + "\n... [truncated]"
      end
    end
    
    # Simple token counter (can be swapped for tiktoken for accuracy)
    class TokenCounter
      def count(text)
        # Rough estimate: 1 token ≈ 4 characters for code
        (text.length / 4.0).ceil
      end
    end
    
    AssembledContext = Struct.new(
      :context,
      :tokens_used,
      :budget,
      :sources,
      :sections,
      keyword_init: true
    )
  end
end
```

### Structural Context

The structural context provides an always-available overview of the codebase.

```ruby
module CodebaseIndex
  module Retrieval
    class StructuralContextBuilder
      def initialize(extracted_dir:)
        @extracted_dir = Pathname.new(extracted_dir)
        @summary_path = @extracted_dir.join("SUMMARY.md")
        @manifest_path = @extracted_dir.join("manifest.json")
      end
      
      def build
        parts = []
        
        # Rails version and key info
        if @manifest_path.exist?
          manifest = JSON.parse(File.read(@manifest_path))
          parts << "Rails #{manifest['rails_version']} / Ruby #{manifest['ruby_version']}"
          parts << "Extracted: #{manifest['extracted_at']}"
          parts << ""
        end
        
        # Unit counts
        parts << "## Codebase Overview"
        parts << ""
        
        manifest&.dig("counts")&.each do |type, count|
          parts << "- #{type.titleize}: #{count}"
        end
        
        # Key models (top 20 by importance)
        parts << ""
        parts << "## Key Models"
        parts << ""
        key_models = load_key_units(:models, limit: 20)
        key_models.each do |model|
          associations = model[:metadata][:associations]&.size || 0
          parts << "- #{model[:identifier]} (#{associations} associations)"
        end
        
        # Key services
        parts << ""
        parts << "## Key Services"
        parts << ""
        key_services = load_key_units(:services, limit: 15)
        key_services.each do |service|
          parts << "- #{service[:identifier]}"
        end
        
        parts.join("\n")
      end
      
      private
      
      def load_key_units(type, limit:)
        type_dir = @extracted_dir.join(type.to_s)
        return [] unless type_dir.exist?
        
        index_path = type_dir.join("_index.json")
        return [] unless index_path.exist?
        
        index = JSON.parse(File.read(index_path), symbolize_names: true)
        
        # Sort by estimated importance
        index.sort_by { |u| -(u[:estimated_tokens] || 0) }
             .first(limit)
      end
    end
  end
end
```

---

## Ranking & Relevance

After retrieval, candidates are re-ranked based on multiple signals.

### Ranking Signals

| Signal | Weight | Description |
|--------|--------|-------------|
| Semantic Score | 0.40 | Vector similarity from embedding search |
| Keyword Match | 0.20 | Exact matches on identifiers, methods, columns |
| Recency | 0.15 | Recent changes more relevant for "current state" queries |
| Importance | 0.10 | Complexity, centrality in dependency graph |
| Type Match | 0.10 | Query asked for model, result is model |
| Diversity | 0.05 | Penalize redundant results |

### Ranker Implementation

```ruby
module CodebaseIndex
  module Retrieval
    class Ranker
      WEIGHTS = {
        semantic: 0.40,
        keyword: 0.20,
        recency: 0.15,
        importance: 0.10,
        type_match: 0.10,
        diversity: 0.05
      }.freeze
      
      def initialize(metadata_store:)
        @metadata_store = metadata_store
      end
      
      def rank(candidates, classification:)
        # Score each candidate
        scored = candidates.map do |candidate|
          unit = @metadata_store.find(candidate.identifier)
          
          {
            candidate: candidate,
            scores: {
              semantic: candidate.score,
              keyword: keyword_score(candidate),
              recency: recency_score(unit),
              importance: importance_score(unit),
              type_match: type_match_score(unit, classification),
              diversity: 1.0  # Adjusted after sorting
            }
          }
        end
        
        # Calculate weighted scores
        scored.each do |item|
          item[:weighted_score] = WEIGHTS.sum do |signal, weight|
            item[:scores][signal] * weight
          end
        end
        
        # Sort by weighted score
        sorted = scored.sort_by { |item| -item[:weighted_score] }
        
        # Apply diversity penalty
        apply_diversity_penalty(sorted)
        
        # Return re-ranked candidates
        sorted.map { |item| item[:candidate] }
      end
      
      private
      
      def keyword_score(candidate)
        return 0.0 unless candidate.respond_to?(:matched_fields)
        return 0.0 if candidate.matched_fields.nil?
        
        # More matched fields = higher score
        [candidate.matched_fields.size * 0.25, 1.0].min
      end
      
      def recency_score(unit)
        return 0.5 unless unit  # Neutral if unknown
        
        change_frequency = unit.dig(:metadata, :git, :change_frequency)
        case change_frequency&.to_sym
        when :hot then 1.0
        when :active then 0.8
        when :stable then 0.5
        when :dormant then 0.3
        when :new then 0.7
        else 0.5
        end
      end
      
      def importance_score(unit)
        return 0.5 unless unit
        
        importance = unit.dig(:metadata, :importance)
        case importance&.to_s
        when "high" then 1.0
        when "medium" then 0.6
        when "low" then 0.3
        else 0.5
        end
      end
      
      def type_match_score(unit, classification)
        return 0.5 unless unit
        return 0.5 if classification[:target_type] == :unknown
        
        unit[:type]&.to_sym == classification[:target_type] ? 1.0 : 0.3
      end
      
      def apply_diversity_penalty(sorted)
        seen_namespaces = Hash.new(0)
        seen_types = Hash.new(0)
        
        sorted.each do |item|
          unit = @metadata_store.find(item[:candidate].identifier)
          next unless unit
          
          namespace = unit[:namespace] || "root"
          type = unit[:type] || "unknown"
          
          # Penalty for repeated namespace/type combinations
          repetition = seen_namespaces[namespace] + seen_types[type]
          penalty = [repetition * 0.1, 0.5].min
          
          item[:scores][:diversity] = 1.0 - penalty
          item[:weighted_score] -= penalty * WEIGHTS[:diversity]
          
          seen_namespaces[namespace] += 1
          seen_types[type] += 1
        end
        
        # Re-sort after diversity adjustment
        sorted.sort_by! { |item| -item[:weighted_score] }
      end
    end
  end
end
```

### Cross-Encoder Reranking (Optional)

After initial ranking, an optional cross-encoder reranking stage can refine the top-k candidates before context assembly. Cross-encoders jointly encode the query and each candidate, producing higher-precision relevance scores than bi-encoder similarity — at the cost of additional latency.

**When to use:** Enable for queries where precision matters more than latency (implementation tasks, debugging, impact analysis). Disable for latency-sensitive paths (editor autocomplete, real-time suggestions).

**Pipeline position:**

```
Initial Retrieval (vector + keyword + graph)
  → Lightweight Ranking (signal-weighted scoring)
  → Cross-Encoder Reranking (top-k refinement, optional)
  → Context Assembly (token budgeting)
```

**Reranker Interface:**

```ruby
module CodebaseIndex
  module Retrieval
    module Reranker
      module Interface
        # Rerank candidates against the original query.
        # @param query [String] The original query text
        # @param candidates [Array<Candidate>] Pre-ranked candidates (top-k from initial ranking)
        # @return [Array<Candidate>] Re-scored and re-ordered candidates
        def rerank(query, candidates)
          raise NotImplementedError
        end
      end
    end
  end
end
```

**Candidate providers:**

| Provider | Strengths | Considerations |
|----------|-----------|----------------|
| Cohere Rerank | Purpose-built reranking API, easy integration | API dependency, per-query cost |
| Voyage Reranker | Code-aware, pairs well with Voyage embeddings | API dependency |
| Local cross-encoder | No API dependency, data stays on-premise | Requires GPU for acceptable latency |

**Configuration:**

```ruby
CodebaseIndex.configure do |config|
  # Enable cross-encoder reranking (default: disabled)
  config.reranker = :cohere          # or :voyage, :local, :none
  config.reranker_api_key = ENV["COHERE_API_KEY"]
  config.reranker_top_k = 15        # Number of candidates to rerank
end
```

Cross-encoder reranking is backend-agnostic and optional, consistent with the system's design principles. When disabled, the pipeline falls through directly from initial ranking to context assembly with no behavior change.

---

## Interface Layer

Multiple interfaces for different consumption patterns.

### Ruby API

```ruby
module CodebaseIndex
  class Retriever
    def initialize(config:)
      @config = config
      @classifier = Retrieval::QueryClassifier.new
      @strategy_selector = Retrieval::StrategySelector.new(config)
      @ranker = Retrieval::Ranker.new(metadata_store: config.metadata_store)
      @assembler = Retrieval::ContextAssembler.new(
        unit_store: config.metadata_store,
        budget: config.token_budget
      )
      @structural_builder = Retrieval::StructuralContextBuilder.new(
        extracted_dir: config.extracted_dir
      )
    end
    
    # Main retrieval method
    def retrieve(query, options = {})
      # 1. Classify
      classification = @classifier.classify(query)
      
      # 2. Select and execute strategy
      strategy = @strategy_selector.select(classification)
      candidates = strategy.search(query, classification: classification)
      
      # 3. Rank
      ranked = @ranker.rank(candidates, classification: classification)
      
      # 4. Assemble context
      structural = options[:include_structural] != false ? @structural_builder.build : nil
      
      assembled = @assembler.assemble(
        candidates: ranked,
        classification: classification,
        structural_context: structural
      )
      
      # 5. Return result
      RetrievalResult.new(
        context: assembled.context,
        tokens_used: assembled.tokens_used,
        sources: assembled.sources,
        classification: classification,
        strategy: strategy.class.name,
        candidate_count: candidates.size
      )
    end
    
    # Convenience methods
    def retrieve_for_model(model_name)
      retrieve("How does the #{model_name} model work?")
    end
    
    def retrieve_for_feature(feature_description)
      retrieve("Explain the #{feature_description} feature")
    end
    
    def retrieve_dependencies(identifier)
      # Direct graph lookup, no semantic search
      deps = @config.graph_store.dependencies_of(identifier, depth: 2)
      # ... assemble context from deps
    end
  end
  
  RetrievalResult = Struct.new(
    :context,
    :tokens_used,
    :sources,
    :classification,
    :strategy,
    :candidate_count,
    keyword_init: true
  )
end
```

### CLI Interface

```ruby
# bin/codebase
#!/usr/bin/env ruby

require "bundler/setup"
require "codebase_index"
require "optparse"

options = {
  budget: 8000,
  format: :text,
  include_sources: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: codebase [options] <query>"
  
  opts.on("-b", "--budget TOKENS", Integer, "Token budget (default: 8000)") do |b|
    options[:budget] = b
  end
  
  opts.on("-f", "--format FORMAT", [:text, :json, :markdown], "Output format") do |f|
    options[:format] = f
  end
  
  opts.on("-s", "--sources", "Include source attribution") do
    options[:include_sources] = true
  end
  
  opts.on("-v", "--verbose", "Show retrieval trace") do
    options[:verbose] = true
  end
end.parse!

query = ARGV.join(" ")
abort "Usage: codebase <query>" if query.empty?

# Load configuration
config = CodebaseIndex.configuration

# Create retriever
retriever = CodebaseIndex::Retriever.new(config: config)

# Execute retrieval
result = retriever.retrieve(query)

# Output
case options[:format]
when :json
  puts JSON.pretty_generate(result.to_h)
when :markdown
  puts "# Query: #{query}"
  puts ""
  puts "**Tokens:** #{result.tokens_used}/#{options[:budget]}"
  puts "**Strategy:** #{result.strategy}"
  puts ""
  puts "---"
  puts ""
  puts result.context
  
  if options[:include_sources]
    puts ""
    puts "---"
    puts ""
    puts "## Sources"
    result.sources.each do |source|
      puts "- #{source[:identifier]} (#{source[:type]}, score: #{source[:score].round(2)})"
    end
  end
else
  puts result.context
end
```

### Rake Tasks

```ruby
# lib/tasks/codebase_retrieval.rake

namespace :codebase do
  desc "Retrieve context for a query"
  task :retrieve, [:query] => :environment do |t, args|
    require "codebase_index"
    
    retriever = CodebaseIndex::Retriever.new(config: CodebaseIndex.configuration)
    result = retriever.retrieve(args[:query])
    
    puts result.context
    puts ""
    puts "---"
    puts "Tokens: #{result.tokens_used}"
    puts "Sources: #{result.sources.size}"
  end
  
  desc "Index the codebase for retrieval"
  task index: :environment do
    require "codebase_index"
    
    pipeline = CodebaseIndex::Embedding::IndexingPipeline.new(
      extracted_dir: CodebaseIndex.configuration.output_dir,
      vector_store: CodebaseIndex.configuration.vector_store,
      metadata_store: CodebaseIndex.configuration.metadata_store,
      embedding_provider: CodebaseIndex.configuration.embedding_provider
    )
    
    puts "Indexing codebase..."
    pipeline.index_all
    puts "Done."
  end
  
  desc "Update index for changed files"
  task :index_incremental, [:identifiers] => :environment do |t, args|
    require "codebase_index"
    
    identifiers = args[:identifiers].split(",")
    
    pipeline = CodebaseIndex::Embedding::IndexingPipeline.new(
      extracted_dir: CodebaseIndex.configuration.output_dir,
      vector_store: CodebaseIndex.configuration.vector_store,
      metadata_store: CodebaseIndex.configuration.metadata_store,
      embedding_provider: CodebaseIndex.configuration.embedding_provider
    )
    
    puts "Updating index for #{identifiers.size} units..."
    pipeline.index_incremental(identifiers)
    puts "Done."
  end
end
```

---

## Configuration & Adaptability

The system is configured through a central configuration object with sensible defaults and environment-based overrides.

### Configuration Structure

```ruby
module CodebaseIndex
  class Configuration
    # Extraction settings
    attr_accessor :output_dir
    attr_accessor :extractors
    
    # Embedding settings
    attr_accessor :embedding_provider
    attr_accessor :embedding_model
    attr_accessor :embedding_api_key
    
    # Storage settings
    attr_accessor :vector_store
    attr_accessor :vector_store_url
    attr_accessor :vector_store_collection
    
    attr_accessor :metadata_store
    attr_accessor :metadata_store_connection
    
    attr_accessor :graph_store
    
    # Retrieval settings
    attr_accessor :token_budget
    attr_accessor :similarity_threshold
    attr_accessor :max_candidates
    
    # Framework indexing
    attr_accessor :include_framework_sources
    attr_accessor :gem_configs
    
    def initialize
      # Defaults
      @output_dir = default_output_dir
      @extractors = %i[models controllers services jobs mailers components graphql]
      
      @embedding_provider = :ollama
      @embedding_model = "nomic-embed-text"

      @vector_store = :sqlite_faiss
      @vector_store_url = ENV.fetch("QDRANT_URL", "http://localhost:6333")
      @vector_store_collection = "codebase_index"
      
      @metadata_store = :sqlite
      @metadata_store_connection = default_metadata_path
      
      @graph_store = :memory
      
      @token_budget = 8000
      @similarity_threshold = 0.7
      @max_candidates = 50
      
      @include_framework_sources = true
      @gem_configs = {}
    end
    
    # Build configured instances
    def build_vector_store
      case @vector_store
      when :qdrant
        Storage::VectorStore::Qdrant.new(
          url: @vector_store_url,
          collection: @vector_store_collection
        )
      when :pgvector
        Storage::VectorStore::Pgvector.new(
          connection_string: @vector_store_connection
        )
      when :sqlite_faiss
        Storage::VectorStore::SqliteFaiss.new(
          db_path: @metadata_store_connection,
          index_path: "#{@output_dir}/faiss.index"
        )
      else
        raise ConfigurationError, "Unknown vector store: #{@vector_store}"
      end
    end
    
    def build_embedding_provider
      case @embedding_provider
      when :openai
        Embedding::Provider::OpenAI.new(
          api_key: @embedding_api_key || ENV.fetch("OPENAI_API_KEY"),
          model: @embedding_model
        )
      when :voyage
        Embedding::Provider::Voyage.new(
          api_key: @embedding_api_key || ENV.fetch("VOYAGE_API_KEY"),
          model: @embedding_model
        )
      when :ollama
        Embedding::Provider::Ollama.new(
          url: ENV.fetch("OLLAMA_URL", "http://localhost:11434"),
          model: @embedding_model
        )
      else
        raise ConfigurationError, "Unknown embedding provider: #{@embedding_provider}"
      end
    end
    
    def build_metadata_store
      case @metadata_store
      when :sqlite
        Storage::MetadataStore::Sqlite.new(
          db_path: @metadata_store_connection
        )
      when :postgresql
        Storage::MetadataStore::Postgresql.new(
          connection_string: @metadata_store_connection
        )
      when :mysql
        Storage::MetadataStore::Mysql.new(
          connection_string: @metadata_store_connection
        )
      when :memory
        Storage::MetadataStore::Memory.new(
          extracted_dir: @output_dir
        )
      else
        raise ConfigurationError, "Unknown metadata store: #{@metadata_store}"
      end
    end
    
    def build_graph_store
      case @graph_store
      when :memory
        Storage::GraphStore::Memory.new(
          graph_path: "#{@output_dir}/dependency_graph.json"
        )
      when :postgresql
        Storage::GraphStore::Postgresql.new(
          connection_string: @metadata_store_connection
        )
      when :mysql
        Storage::GraphStore::Mysql.new(
          connection_string: @metadata_store_connection
        )
      else
        raise ConfigurationError, "Unknown graph store: #{@graph_store}"
      end
    end
    
    private
    
    def default_output_dir
      if defined?(Rails)
        Rails.root.join("tmp/codebase_index").to_s
      else
        "tmp/codebase_index"
      end
    end
    
    def default_metadata_path
      "#{@output_dir}/metadata.sqlite3"
    end
  end
end
```

### Environment-Based Configuration

```ruby
# config/initializers/codebase_index.rb

CodebaseIndex.configure do |config|
  # Base settings
  config.output_dir = Rails.root.join("tmp/codebase_index")
  
  # Environment-specific settings
  case Rails.env
  when "development"
    # Local development: SQLite + FAISS, no external dependencies
    config.vector_store = :sqlite_faiss
    config.metadata_store = :sqlite
    config.embedding_provider = :ollama
    config.embedding_model = "nomic-embed-text"
    
  when "test"
    # Testing: In-memory everything
    config.vector_store = :memory
    config.metadata_store = :memory
    config.graph_store = :memory
    config.embedding_provider = :mock
    
  when "production", "staging"
    # Production: Qdrant + your existing database
    config.vector_store = :qdrant
    config.vector_store_url = ENV.fetch("QDRANT_URL")
    config.vector_store_collection = "codebase_#{Rails.env}"
    
    # Use your existing database for metadata + graph storage:
    # MySQL 8.0+/Percona:
    config.metadata_store = :mysql
    config.graph_store = :mysql
    # PostgreSQL:
    # config.metadata_store = :postgresql
    # config.graph_store = :postgresql
    
    config.metadata_store_connection = ENV.fetch("CODEBASE_INDEX_DATABASE_URL")
    
    config.embedding_provider = :openai
    config.embedding_model = "text-embedding-3-small"
  end
  
  # Gem configurations
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
  config.add_gem "sidekiq", paths: ["lib/sidekiq/worker.rb"], priority: :high
  config.add_gem "phlex-rails", paths: ["lib/phlex"], priority: :high
end
```

### Preset Configurations

For common setups, provide presets:

```ruby
module CodebaseIndex
  module Presets
    # Minimal local development setup
    def self.local_development
      Configuration.new.tap do |c|
        c.vector_store = :sqlite_faiss
        c.metadata_store = :sqlite
        c.graph_store = :memory
        c.embedding_provider = :ollama
        c.embedding_model = "nomic-embed-text"
      end
    end
    
    # MySQL + Qdrant (classic Rails pattern: MySQL/Percona + Sidekiq + Docker)
    def self.mysql_qdrant
      Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.metadata_store = :mysql
        c.graph_store = :mysql   # MySQL 8.0+ recursive CTEs
        c.embedding_provider = :openai
        c.embedding_model = "text-embedding-3-small"
      end
    end
    
    # PostgreSQL + Qdrant
    def self.postgresql_qdrant
      Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.metadata_store = :postgresql
        c.graph_store = :postgresql
        c.embedding_provider = :openai
        c.embedding_model = "text-embedding-3-small"
      end
    end
    
    # PostgreSQL-only (using pgvector — no separate vector store)
    def self.postgresql_only
      Configuration.new.tap do |c|
        c.vector_store = :pgvector
        c.metadata_store = :postgresql
        c.graph_store = :postgresql
        c.embedding_provider = :openai
      end
    end
    
    # Fully self-hosted (no external APIs)
    # Works with either database — pass :mysql or :postgresql
    def self.self_hosted(database: :postgresql)
      Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.metadata_store = database
        c.graph_store = database  # Both MySQL 8.0+ and PostgreSQL support recursive CTEs
        c.embedding_provider = :ollama
        c.embedding_model = "nomic-embed-text"
      end
    end
  end
end
```

---

## Reference Implementation

### Target Environment: Large Rails Monolith

Based on a production Rails monolith analysis:

**Scale:**
- 993 models
- 90+ Sidekiq workers
- Multiple service patterns (services, managers, decorators)
- Phlex 2.0 + ViewComponent
- GraphQL API

**Infrastructure:**
- MySQL 8.0 (Percona cluster)
- Redis/Dragonfly
- Docker Compose for development
- Existing analytics (ClickHouse, Superset)

### Recommended Configuration

```ruby
CodebaseIndex.configure do |config|
  # Extraction
  config.output_dir = Rails.root.join("tmp/codebase_index")
  config.extractors = %i[models controllers services jobs mailers components graphql]
  config.include_framework_sources = true
  
  # Storage: Qdrant for vectors (add to docker-compose)
  config.vector_store = :qdrant
  config.vector_store_url = "http://bc_qdrant:6333"
  config.vector_store_collection = "admin_codebase"
  
  # Metadata: MySQL (existing infrastructure)
  config.metadata_store = :mysql
  config.metadata_store_connection = ENV["DATABASE_URL"]
  
  # Graph: In-memory (loaded from JSON)
  config.graph_store = :memory
  
  # Embeddings: OpenAI (existing external service pattern)
  config.embedding_provider = :openai
  config.embedding_model = "text-embedding-3-small"
  
  # Retrieval
  config.token_budget = 8000
  config.max_candidates = 50
  
  # Gem configurations (based on Gemfile)
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
  config.add_gem "sidekiq", paths: ["lib/sidekiq"], priority: :high
  config.add_gem "phlex-rails", paths: ["lib/phlex"], priority: :high
  config.add_gem "graphql", paths: ["lib/graphql"], priority: :medium
  config.add_gem "pundit", paths: ["lib/pundit"], priority: :high
end
```

### Docker Compose Addition

```yaml
# Add to docker-compose.yml
services:
  bc_qdrant:
    container_name: bc_qdrant
    image: qdrant/qdrant:v1.12.1
    ports:
      - "6333:6333"
      - "6334:6334"  # gRPC
    volumes:
      - qdrant-data:/qdrant/storage
    environment:
      - QDRANT__SERVICE__GRPC_PORT=6334

volumes:
  qdrant-data:
```

### CI Integration

```yaml
# .buildkite/pipeline.yml addition
steps:
  - label: "🔍 Update Codebase Index"
    command:
      - bundle exec rake codebase_index:incremental
    if: build.branch == "main"
    soft_fail: true  # Don't block deploys on index failures
```

---

## Future Considerations

### Phase 2: Enhanced Retrieval

- **Query expansion**: Automatically expand queries with synonyms, related terms
- **Conversation context**: Use prior conversation to inform retrieval
- **User personalization**: Learn from developer's retrieval patterns
- **Feedback loop**: Track which retrievals were useful

### Phase 3: Advanced Features

- **Multi-codebase**: Index multiple services, trace across boundaries
- **Runtime correlation**: Link code to runtime metrics (APM integration)
- **Test coverage mapping**: Know which tests cover which code
- **Documentation linking**: Connect code to external docs, ADRs

### Phase 4: Editor Integration

- **VS Code extension**: Inline context retrieval
- **Cursor/Copilot integration**: Feed context to AI assistants
- **Code review assistance**: Retrieve context for PR review

### Backend Expansion

- **Solid Queue support**: Extract job metadata from Solid Queue
- **PostgreSQL-native**: Full pgvector + pg_trgm solution
- **Kamal deployment**: Indexing hooks for Kamal deploys
- **Turbo Native**: Component extraction for mobile codebases

---

## Appendix: Data Structures

### Candidate

```ruby
Candidate = Struct.new(
  :identifier,    # String: unit identifier
  :score,         # Float: relevance score (0-1)
  :source,        # Symbol: :vector_search, :keyword_search, :graph_expansion, :direct_lookup
  :metadata,      # Hash: unit metadata
  :matched_fields,# Array: fields that matched (for keyword search)
  :expanded_from, # String: parent identifier (for graph expansion)
  keyword_init: true
)
```

### SearchResult

```ruby
SearchResult = Struct.new(
  :identifier,
  :similarity,
  :metadata,
  keyword_init: true
)
```

### RetrievalResult

```ruby
RetrievalResult = Struct.new(
  :context,         # String: assembled context
  :tokens_used,     # Integer: actual token count
  :sources,         # Array<Hash>: source attribution
  :classification,  # Hash: query classification
  :strategy,        # String: strategy used
  :candidate_count, # Integer: candidates before ranking
  :trace,           # Hash: full retrieval trace (optional)
  keyword_init: true
)
```

### AssembledContext

```ruby
AssembledContext = Struct.new(
  :context,
  :tokens_used,
  :budget,
  :sources,
  :sections,
  keyword_init: true
)
```
