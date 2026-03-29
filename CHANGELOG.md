# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Svelte Flow visualization** — interactive graph visualization of dependencies, domain clusters, and request execution flows
  - `Woods::SvelteFlow::Transformer` — orchestrates conversion of graph data to Svelte Flow node/edge format
  - `Woods::SvelteFlow::Layout` — server-side DAG layout using Kahn's algorithm with PageRank tiebreaking
  - `Woods::SvelteFlow::NodeBuilder` — maps graph nodes to Svelte Flow nodes with type coloring, hub/bridge/orphan badges
  - `Woods::SvelteFlow::EdgeBuilder` — maps graph edges with cycle marking, boundary animations, and flow step connections
  - `Woods::SvelteFlow::Exporter` — reads extraction output and writes Svelte Flow JSON files
  - `Woods::SvelteFlow::RackMiddleware` — serves interactive visualization page and JSON API endpoints
  - Pre-built canvas-based frontend with three views: Dependencies, Flows, Clusters
  - New rake tasks: `woods:svelte_flow_export` (alias: `woods:map`)
  - New config: `svelte_flow_enabled`, `svelte_flow_path`
  - Integration guide: `docs/SVELTE_FLOW_VISUALIZATION.md`

## [1.2.0] - 2026-03-27

### Added

- **Unblocked Documents API exporter** — sync extraction data to an Unblocked collection for code review and Q&A context
  - `Woods::Unblocked::Client` — REST client with retry and daily budget rate limiting
  - `Woods::Unblocked::DocumentBuilder` — type-specific Markdown formatters optimized for review context (blast radius, entry points, associations, side effects)
  - `Woods::Unblocked::Exporter` — full/partial sync orchestrator with priority ordering
  - `Woods::Unblocked::RateLimiter` — daily budget tracking (1000 calls/day)
  - New rake tasks: `woods:unblocked_sync` (alias: `woods:relay`)
  - New config: `unblocked_api_token`, `unblocked_collection_id`, `unblocked_repo_url`
  - Integration guide: `docs/UNBLOCKED_INTEGRATION.md`
- **Domain cluster detection** in `GraphAnalyzer` — groups code units into semantic domains using namespace prefixes and graph connectivity
  - `GraphAnalyzer#domain_clusters` — hybrid namespace + graph clustering with hub identification, entry point detection, and boundary edge mapping
  - New MCP tool: `domain_clusters` with `min_size` and `types` filters
  - New renderer: `render_domain_clusters` in MarkdownRenderer

## [0.3.1] - 2026-03-04

### Fixed

- **Gemspec version** now reads from `version.rb` instead of being hardcoded — prevents version mismatch during gem builds
- **Release workflow** replaced `rake release` (fails on tag-triggered detached HEAD) with `gem build` + `gem push`

## [0.3.0] - 2026-03-04

### Added

- **Redis/SolidCache caching layer** for retrieval pipeline with TTL, namespace isolation, and nil-caching
- **Engine classification** — engines tagged as `:framework` or `:application` based on install path (handles Docker vendor paths)
- **Graph analysis staleness tracking** — `generated_at` timestamp and `graph_sha` for detecting stale analysis
- **Docker setup guide** (`docs/DOCKER_SETUP.md`) — split architecture, volume mounts, bridge mode, troubleshooting
- **Context7 documentation suite** — 10 new user-facing docs optimized for AI retrieval: FAQ, Troubleshooting, Architecture, Extractor Reference, WHY Woods, MCP Tool Cookbook, and 3 Context7 skills
- **`context7.json`** configuration for controlling Context7 indexing scope

### Fixed

- **Vendor path leak** in source file resolution across 9 extractors — framework gems under `vendor/bundle` no longer produce empty source
- **Prism cross-version compatibility** — handle API differences between Prism versions
- **`schema_sha`** now supports `db/structure.sql` fallback (not just `db/schema.rb`)
- **ViewComponent extractor** skips framework-internal components with no resolvable source file
- **HTTP connection reuse** and retry handling in embedding providers
- **DependencyGraph `to_h`** returns a dup to prevent cache pollution
- **MCP tool counts** corrected across all documentation (27 index / 31 console)
- **TROUBLESHOOTING.md** corrected: `config.extractors` controls retrieval scope, not which extractors run

### Changed

- **README streamlined** from 620 to 325 lines — added Quick Start, Documentation table; removed verbose sections in favor of links to dedicated docs
- **Internal rake tasks** (`retrieve`, `self_analyze`) hidden from `rails -T`
- **Estimated tokens memoization** removed to prevent stale values after source changes
- **Simplification sweep** — dead code removal, shared helper extraction, bug fixes across caching and retrieval layers

### Performance

- Critical hotspots fixed across extraction, storage, and retrieval pipelines
- `fetch_key` optimization for falsy value handling in cache layer

## [0.2.1] - 2026-02-19

### Changed

- Switch release workflow to RubyGems trusted publishing

## [0.2.0] - 2026-02-19

### Added

- **Embedded console MCP server** for zero-config Rails querying (no bridge process needed)
- **Console MCP setup guide** (`docs/CONSOLE_MCP_SETUP.md`) — stdio, Docker, HTTP/Rack, SSH bridge options
- **CODEOWNERS** and issue template configuration

### Fixed

- MCP gem compatibility and symbol key handling in embedded executor
- Duplicate URI warning in gemspec

## [0.1.0] - 2026-02-18

### Added

- **Extraction layer** with 13 extractors: Model, Controller, Service, Job, Mailer, Phlex, ViewComponent, GraphQL, Serializer, Manager, Policy, Validator, RailsSource
- **Dependency graph** with PageRank scoring and GraphAnalyzer (orphans, hubs, cycles, bridges)
- **Storage interfaces** with InMemory, SQLite, Pgvector, and Qdrant adapters
- **Embedding pipeline** with OpenAI and Ollama providers, TextPreparer, resumable Indexer
- **Semantic chunking** with type-aware splitting (model sections, controller per-action)
- **Context formatting** adapters for Claude, GPT, generic LLMs, and humans
- **Retrieval pipeline** with QueryClassifier, SearchExecutor, RRF Ranker, ContextAssembler
- **Retriever orchestrator** with degradation tiers and RetrievalTrace
- **Schema management** with versioned migrations and Rails generators
- **Observability** with ActiveSupport::Notifications instrumentation, structured logging, health checks
- **Resilience** with CircuitBreaker, RetryableProvider, IndexValidator
- **MCP Index Server** (21 tools) for AI agent codebase retrieval
- **Console MCP Server** (31 tools across 4 tiers) for live Rails data access
- **AST layer** with Prism adapter for method extraction and call site analysis
- **RubyAnalyzer** for class, method, and data flow analysis
- **Flow extraction** with FlowAssembler, OperationExtractor, FlowDocument
- **Evaluation harness** with Precision@k, Recall, MRR metrics and baseline comparisons
- **Rake tasks** for extraction, incremental indexing, framework source, validation, stats, evaluation
