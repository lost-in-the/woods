---
paths:
  - "lib/woods/storage/**/*.rb"
  - "lib/woods/retrieval/**/*.rb"
  - "lib/woods/embedding/**/*.rb"
---
# Storage & Retrieval Layer Conventions

Rules:
- Every storage adapter (vector, metadata, graph) implements a common interface. See `docs/ARCHITECTURE.md` — "What Storage Backends Are Available?" for the interface contracts.
- Shipped backends: vector stores are in-memory, pgvector, and Qdrant; metadata stores are in-memory and SQLite; the graph store is in-memory. Anything else raises from `Builder`. Do not document or code against adapters that do not exist.
- The **host app's** database must stay agnostic (MySQL or PostgreSQL): any SQL the Console layer or extractors run against the host must work on both. Woods' own stores are the fixed set above.
- Durable stores (pgvector, Qdrant) implement `each_id`, not `each_entry`. Never detect either with `respond_to?` — the Interface defines both as raising stubs. Use ownership checks (`implements_own?` pattern, B-108).
- All retrieval operations produce a `RetrievalTrace` object for observability. Never return bare results without trace metadata.
- Use circuit breakers for external services (Qdrant, OpenAI). See `docs/RETRIEVAL_GUIDE.md` for the pattern (`Woods::Resilience::CircuitBreaker`).
- Embedding providers must handle rate limiting with exponential backoff. Never let a rate limit crash the indexing pipeline.
- Configuration uses the preset system: `:local`, `:shared_filesystem`, `:postgresql`, `:production` (see `Woods::Builder::PRESETS`). See `docs/CONFIGURATION_REFERENCE.md`.
