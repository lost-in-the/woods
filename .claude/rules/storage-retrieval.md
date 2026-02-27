---
paths:
  - "lib/codebase_index/storage/**/*.rb"
  - "lib/codebase_index/retrieval/**/*.rb"
  - "lib/codebase_index/embedding/**/*.rb"
---
# Storage & Retrieval Layer Conventions

Rules:
- Every storage adapter (vector, metadata, graph) implements a common interface. See `docs/design/RETRIEVAL_ARCHITECTURE.md` for the interface contracts.
- MySQL and PostgreSQL adapters are first-class citizens with equal test coverage. SQLite is the local development default.
- Vector stores: MySQL has no native vector extension — MySQL stacks must pair with Qdrant, Pinecone, or FAISS. PostgreSQL can use pgvector as all-in-one.
- Graph traversal: Both MySQL 8.0+ and PostgreSQL support recursive CTEs. The graph store interface must abstract the syntax differences.
- All retrieval operations produce a `RetrievalTrace` object for observability. Never return bare results without trace metadata.
- Use circuit breakers for external services (Qdrant, OpenAI, Pinecone). See `docs/design/OPERATIONS.md` for the pattern.
- Embedding providers must handle rate limiting with exponential backoff. Never let a rate limit crash the indexing pipeline.
- Configuration uses the preset system: `:local`, `:mysql`, `:postgresql`, `:postgresql_qdrant`, `:self_hosted`. See `docs/CONFIGURATION_REFERENCE.md`.
