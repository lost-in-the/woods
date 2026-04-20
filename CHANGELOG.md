# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Console MCP disabled pending security review.** The Woods Console MCP server (stdio, bridge, and Rack-mounted HTTP) is disabled at its entry points in this release while credential-redaction coverage is reviewed end-to-end. The two entries immediately below (`console_redacted_columns` shape-aware redaction and `console_redacted_key_values` for EAV credential tables) landed as part of that review and ship in this release so the underlying primitive is hardened — but the feature itself is intentionally gated off until the review concludes. Concretely:
  - `exe/woods-console-mcp` and `exe/woods-console` print a notice to stderr and exit 1. MCP clients (Claude Desktop, stdio transports) will see the process fail to start.
  - `Woods::Console::RackMiddleware#call` returns `410 Gone` at the mounted path with a JSON body pointing at this changelog entry. Other requests pass through untouched.
  - Library code under `lib/woods/console/` is unchanged. `Woods::Console::Server.build`, `Woods::Console::Server.build_embedded`, `SafeContext`, `SqlValidator`, `ModelValidator`, the tool-tier modules, and every spec continue to work — so the fix work remains reviewable in-tree and re-enabling the entry points is a one-line revert when the review is complete.
  - The Index MCP server (`woods-mcp`, `woods-mcp-http`) and every extraction workflow are unaffected.
  - Operators whose Rails apps `use Woods::Console::RackMiddleware`: you'll get `410 Gone` responses on the mount after upgrading. Remove the middleware from `config/application.rb` (or the relevant initializer) until the feature is re-enabled. No data leaked by the prior release — this gate is precautionary, and the EAV redaction primitive below ensures the leak described in the audit cannot recur once the feature is turned back on.

- **`console_redacted_columns` now covers every tool that returns row data.** Redaction previously only walked top-level hash keys, so `console_sample`, `console_recent`, `console_find`, `console_pluck`, `console_sql`, and `console_query` returned configured credential columns in the clear — records were nested under `records` / `record`, and rows were positional arrays under `rows` / `values`. The server-level redaction pass is now shape-aware: it descends into `record` / `records` hashes and uses the `columns` header to redact positional rows. `console_pluck` now also includes a `columns` field in its response so positional redaction can key off of it. Affects every transport (stdio, Rack, bridge).
- **`console_redacted_key_values` for EAV (key-value) credential storage.** Column-name redaction cannot protect tables that store sensitive values in a generically named column (e.g. a Stripe Connect `authorizations` row of `{key: "stripe_access_token", value: "sk_live_..."}`): adding `value` to `console_redacted_columns` over-redacts every unrelated row. The new `console_redacted_key_values` config accepts one or more `{key_column:, value_column:, sensitive_keys: []}` patterns — when a row's `key_column` cell matches one of `sensitive_keys`, the same row's `value_column` cell is replaced with `[REDACTED]`. Applies across every response shape (`record`, `records`, positional `rows` / `values`) and every transport. Empty by default — configure it in `Woods.configure` to cover the EAV credential tables specific to your app.

### Fixed

- **Console renderer no longer collapses row data to `"N items"`.** `ConsoleResponseRenderer#render_hash` was summarizing every Array-valued key to a count, which silently elided the actual data from `console_sql`, `console_query`, `console_pluck`, `console_sample`, `console_recent`, and `console_find` responses — the MCP payload carried the rows, but the rendered text agents see only named the shape. Array values now recurse through `render_array` (Array<Hash> → Markdown table, scalar array → bullet list). When `rows` or `values` appears alongside a sibling `columns` array, the renderer emits a positional Markdown table using the columns as headers so sql / query / pluck output is scannable. Metadata-shaped responses (`count`, `aggregate`, `schema`, etc.) are unchanged.
- **MCP `search` tool no longer destroys regex patterns.** `index_reader` was wrapping queries in `Regexp.escape`, turning `User|Account` into a literal-only match. Now compiles raw with `IGNORECASE` and falls back to the escaped form only on `RegexpError`.
- **Auto-detect Ollama probe reliability.** The bootstrapper now probes `GET /api/tags` (the documented list-models endpoint) instead of `HEAD /`, which returned 404 on some Ollama versions. Any non-5xx response now marks Ollama as reachable.
- **`WOODS_SEARCH_MAX_SCAN=""` no longer disables phase-2 search.** Empty and whitespace-only values fall back to the default cap of 500 instead of coercing to 0.
- **Self-describing error for unsupported tools in embedded mode.** `console_sql` / `console_query` rejections now point at `embedded_read_tools: true` and the setup doc. Other Tier 2–4 rejections still point at the bridge architecture. Replaces the generic "Not yet implemented in embedded mode" message.
- **`console_embedded_read_tools` configuration flag.** Flows through `Woods.configure` to both the Rack middleware (Option C) and the stdio transports (Options A and B) — previously only the Rack mount accepted `embedded_read_tools:` directly, so stdio deployments had no way to unlock `console_sql` / `console_query` without patching the executable.

### Added

- **Ollama auto-detection in the MCP bootstrapper.** When no embedding provider is configured and no `OPENAI_API_KEY` is present, the bootstrapper probes `OLLAMA_BASE_URL` (default `http://localhost:11434`) and auto-enables semantic search if reachable. A one-line STDERR banner at startup reports the active provider.
- **`WOODS_SEARCH_MAX_SCAN` env var.** Caps phase-2 scan volume during `search`. Default 500.
- **Ransack-style scope predicates** for console data tools — `scope` hashes in `console_count`, `console_sample`, `console_pluck`, `console_aggregate`, `console_association_count`, and `console_recent` now accept suffixed keys (`_eq`, `_not_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`). Column names are validated before Arel predicates are built — no string interpolation, no SQL injection surface.
- **`count` function in `console_aggregate`** — the `column` argument is optional when `function: "count"`, making it easy to count rows matching a scope in a single tool call.
- **`embedded_read_tools` flag** on `Woods::Console::RackMiddleware` — opts `console_sql` and `console_query` into the embedded executor, with `SqlValidator` + `SafeContext` rollback + per-request connection pooling enforcing read-only safety.
- **MCP worktree setup guide** (`docs/MCP_WORKTREE_SETUP.md`) — multi-worktree MCP configuration for simultaneous Claude Code sessions across branches.
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

### Changed

- **MCP `search` response shape.** `search` now returns `{ results: [...], note?: String, partial?: Boolean }` instead of a bare `Array`. `note` flags broad patterns (>50% of a directory matched). `partial: true` indicates the phase-2 scan cap was reached — set `WOODS_SEARCH_MAX_SCAN` to raise it.
- **MCP `search` and `codebase_retrieve` descriptions** rewritten in Figma-MCP style (purpose → example → returns → when to use alternatives → gotchas). Fallback message for `codebase_retrieve` now includes exact fix commands.
- **Scope tool descriptions** updated to reference the supported predicate suffixes, so agents discover the richer filtering surface without reading the cookbook.
- **Tool descriptions for `console_sql` and `console_query`** rewritten in Figma-MCP-style (purpose → safety → requirement → alternatives) so agents understand when to reach for each and how to enable them.
- **Docs:** `docs/CONSOLE_MCP_SETUP.md` now covers `embedded_read_tools: true` as an alternative to switching to the bridge architecture, and the Troubleshooting entry for Tier 2–4 tools distinguishes the two read tools from everything else.

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
