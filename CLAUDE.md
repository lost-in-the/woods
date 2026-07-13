# Woods

Ruby gem that extracts structured data from Rails applications for AI-assisted development. Uses runtime introspection (not static parsing) to produce version-accurate representations: inlined concerns, resolved callback chains, schema-aware associations, dependency graphs. All major layers are complete: extraction (34 extractors + 6 helpers), retrieval (query classification, hybrid search, RRF ranking), storage (pgvector, Qdrant, SQLite adapters), embedding (OpenAI, Ollama), two MCP servers (29-tool index server — 14 always-on + 15 wiring-conditional; 31-tool console server), AST analysis, flow extraction, temporal snapshots, Notion + Obsidian export, and evaluation harness.

## Commands

```bash
# Development
bundle install
bundle exec rake spec                            # Full test suite
bundle exec rake spec SPEC=spec/extractors/model_extractor_spec.rb  # Single file
bundle exec rubocop -a                            # Lint + autofix
bundle exec rubocop --auto-gen-config             # Update .rubocop_todo.yml

# In a host Rails app (extraction requires Rails boot)
bundle exec rake woods:extract           # Full extraction
bundle exec rake woods:incremental       # Changed files only
bundle exec rake woods:extract_framework # Rails/gem sources
bundle exec rake woods:validate          # Index integrity check
bundle exec rake woods:stats             # Show extraction stats
bundle exec rake woods:clean             # Remove index output
bundle exec rake woods:embed             # Embed all extracted units
bundle exec rake woods:embed_incremental # Embed changed units only
bundle exec rake "woods:retrieve[query]" # Ad-hoc retrieval against the index
bundle exec rake "woods:flow[entry]"     # Execution flow document for an entry point
bundle exec rake woods:console           # Embedded Console MCP server (stdio)
bundle exec rake woods:notion_sync       # Sync models/columns to Notion
bundle exec rake woods:unblocked_sync    # Sync to an Unblocked collection
bundle exec rake woods:obsidian          # Export to an Obsidian vault (alias: woods:vault)
bundle exec rake woods:explore           # Self-contained HTML data explorer (alias: woods:wander)
bundle exec rake woods:generate_token    # Random bearer token for woods-mcp-http
# Woods-themed aliases: woods:scan (extract), woods:tend (incremental), woods:look (stats),
# woods:vet (validate), woods:clear (clean), woods:nest (embed), woods:hone (embed_incremental),
# woods:send (notion_sync), woods:relay (unblocked_sync)
```

> **Docker:** Extraction runs inside the container (`docker compose exec app bundle exec rake ...`). The Index Server runs on the host reading volume-mounted output. See `docs/DOCKER_SETUP.md` for the full Docker guide.

## Host app for integration testing: `woods-testbed`

Extraction, the Console MCP server, and the ERD middleware all require a booted Rails environment to validate. We maintain a companion repo — [`lost-in-the/woods-testbed`](https://github.com/lost-in-the/woods-testbed) — with one Rails app per supported Rails version. Clone it alongside this gem and `docker compose up` the variant you need.

**Variants** (add more by contributing a new `apps/rails-X.Y/` directory):

| Variant | Rails | Port | Container |
|---|---|---|---|
| `apps/rails-8.0` | 8.0.x | 3010 | `woods-testbed-rails-8.0` |
| `apps/rails-7.2` | ~> 7.2.0 | 3011 | `woods-testbed-rails-7.2` |
| `apps/rails-6.0` | ~> 6.0.0 | 3012 | `woods-testbed-rails-6.0` |

**Typical setup** (sibling-repo layout — the testbed's compose file defaults to `../woods` for the gem mount):

```bash
# Once:
cd ~/where-you-keep-code
git clone https://github.com/lost-in-the/woods.git
git clone https://github.com/lost-in-the/woods-testbed.git

# Bring a variant up (from inside woods-testbed/):
cd woods-testbed
docker compose up -d rails-8.0   # or rails-7.2

# Override the gem path for a worktree or a different checkout:
WOODS_GEM_PATH=/absolute/path/to/woods-worktree docker compose up -d rails-8.0
```

**Invoking woods tasks inside a variant:**

```bash
docker exec woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails woods:extract'
docker exec woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails woods:stats'

# Shared smoke scripts live at scripts/ in the testbed repo and are mounted
# read-only at /app/script/shared inside every variant:
docker exec woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails runner script/shared/woods_smoke.rb'
docker exec woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails runner script/shared/woods_credentials_smoke.rb'

# Interactive console:
docker exec -it woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails console'
```

**Extraction output** lands under `apps/rails-<version>/tmp/woods/` inside the testbed checkout — bind-mounted read-write, so the host can read `_index.json`, `dependency_graph.json`, etc. directly.

**Adding coverage.** Smoke scripts go in the testbed's `scripts/` directory so they run unchanged against every variant. Each variant's `config/initializers/woods_console.rb` can be tweaked independently when a test needs version-specific configuration.

**The testbed is a playground.** Agents working on the gem have permission to modify anything under the testbed's `apps/` — add models, migrations, controllers, initializers, smoke scripts, seeds. Reshape it to fit the scenario. Only gem changes under `lib/woods/` go through the normal review gate.

**When to use each host:**
- **`woods-testbed` `rails-8.0`** — default. Day-to-day Rails 8 validation. Fast, small, self-contained.
- **`woods-testbed` `rails-7.2`** — when a change could plausibly behave differently on Rails 7 (Zeitwerk load paths, callback-chain internals, `eager_load!` error paths).
- **`woods-testbed` `rails-6.0`** — the supported floor (`railties >= 6.0`, #135). Use when a change touches 6.0/6.1-era APIs (e.g. `connection_db_config`, `has_many_inversing` guards) or to validate the lowest end of the matrix. Boots on Ruby 3.0.
- **`~/work/test_app`** (local-only host) — when a change needs a committed integration spec, or maps cleanly to `spec/integration/` fixtures. No Docker, runs on Rails 8.1.
- **A production-shaped MySQL host app** (local-only, see `.claude/rules/integration-testing.md`) — only when a problem demands a large real codebase: namespace collisions, large callback chains, non-standard service directories, many-model PageRank behaviour.

**Gotchas:**
- `WOODS_GEM_PATH` is resolved at `docker compose up` time, not `exec` time. Restart the variant after changing it.
- Bundler installs are cached in per-variant named volumes (`woods-testbed-bundle-rails-8`, `woods-testbed-bundle-rails-7-2`, `woods-testbed-bundle-rails-6-0`). Nuke the matching volume if a lockfile change triggers an install loop.
- If a boot-time change doesn't take effect, clear `tmp/cache/bootsnap/` inside the container.

See `.claude/rules/integration-testing.md` for the full host-app reference (it is local-only and gitignored; it names the local hosts).

## Architecture

```
lib/
├── woods.rb                             # Module interface, Configuration, entry point
├── woods/
│   ├── extractor.rb                     # Orchestrator — coordinates all extractors
│   ├── extracted_unit.rb                # Core value object
│   ├── dependency_graph.rb              # Directed graph + PageRank scoring
│   ├── graph_analyzer.rb               # Structural analysis (orphans, hubs, cycles, bridges)
│   ├── model_name_cache.rb             # Precomputed regex for dependency scanning
│   ├── retriever.rb                     # Retriever orchestrator with degradation tiers
│   ├── flow_precomputer.rb             # Pre-computed per-action request flow maps
│   ├── flow_assembler.rb               # Per-query runtime flow aggregation
│   ├── flow_document.rb                # Serialization envelope for flow output
│   ├── filename_utils.rb               # Safe filename generation
│   ├── index_artifact.rb               # Dump promotion + safe path handling
│   ├── atomic_file.rb                   # Crash-safe temp+fsync+rename file writes (shared)
│   ├── resolved_config.rb              # Frozen configuration snapshot
│   ├── token_utils.rb                  # Token count estimation helpers
│   ├── extractors/                      # 34 extractors + 6 helpers (shared_utility_methods, shared_dependency_scanner, callback_analyzer, behavioral_profile, route_helper_resolver, ast_source_extraction)
│   ├── ast/                             # Prism-based AST layer
│   ├── ruby_analyzer/                   # Static analysis (class, method, dataflow)
│   ├── flow_analysis/                   # Execution flow tracing
│   ├── chunking/                        # Semantic chunking (Chunk, SemanticChunker)
│   ├── embedding/                       # Embedding pipeline (OpenAI, Ollama, Indexer)
│   ├── storage/                         # Storage backends (VectorStore, MetadataStore, GraphStore, Pgvector, Qdrant)
│   ├── retrieval/                       # Retrieval pipeline (QueryClassifier, SearchExecutor, Ranker, ContextAssembler)
│   ├── formatting/                      # LLM context formatting (Claude, GPT, Generic, Human)
│   ├── export/                          # Shared export fact extraction (UnitFacts) over unit metadata
│   ├── notion/                          # Notion export (Client, Exporter, RateLimiter, Mappers)
│   ├── obsidian/                        # Obsidian vault export (VaultExporter, NoteBuilder, NameMapper, VaultAssets)
│   ├── explorer/                        # Interactive HTML data explorer (SiteBuilder, DataBuilder, UnitSummarizer, TypeGroups, assets/)
│   ├── mcp/                             # MCP Index Server (29 tools — 14 always-on + 15 wiring-conditional: 5 operator / 4 feedback / 4 snapshot / 1 session_trace / 1 notion; 2 resources, 2 templates)
│   ├── console/                         # Console MCP Server (31 tools across 4 tiers: 9 read-only / 9 domain-aware / 10 analytics / 3 guarded; job/cache adapters)
│   ├── coordination/                    # Multi-agent pipeline locking
│   ├── feedback/                        # Agent self-service (FeedbackStore, GapDetector)
│   ├── operator/                        # Pipeline management (StatusReporter, ErrorEscalator, PipelineGuard)
│   ├── observability/                   # Instrumentation, StructuredLogger, HealthCheck
│   ├── resilience/                      # CircuitBreaker, RetryableProvider, IndexValidator
│   ├── cache/                           # Response caching (CacheMiddleware, CacheStore, Redis, SolidCache)
│   ├── cost_model/                      # Cost estimation (EmbeddingCost, Estimator, ProviderPricing, StorageCost)
│   ├── session_tracer/                  # Session tracing middleware + flow assembly (FileStore, RedisStore, SolidCacheStore)
│   ├── temporal/                        # Temporal snapshot system (SnapshotStore, diff, history)
│   ├── db/                              # Schema management (migrations, Migrator, SchemaVersion)
│   ├── evaluation/                      # Retrieval evaluation (Metrics, Evaluator, BaselineRunner)
│   └── unblocked/                       # Unblocked exporter (Client, DocumentBuilder, Exporter, RateLimiter, SyncManifest)
├── generators/woods/                    # Rails generators (install, pgvector)
├── tasks/
│   └── woods.rake                       # Rake task definitions
exe/
├── woods-mcp                            # MCP Index Server executable (stdio)
├── woods-mcp-start                      # Self-healing MCP wrapper
├── woods-mcp-http                       # MCP Index Server executable (HTTP/Rack)
└── woods-console-mcp                    # Console MCP Server executable
```

## Key Design Decisions

- **Runtime introspection over static parsing.** Extractors require a booted Rails environment. This is intentional — `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs give us data that no parser can.
- **Backend agnostic.** The gem must work equally well with MySQL or PostgreSQL, Qdrant or pgvector, Sidekiq or Solid Queue, OpenAI or Ollama. Never hardcode or default to a single backend. See `docs/BACKEND_MATRIX.md`.
- **ExtractedUnit is the universal currency.** Everything flows through `ExtractedUnit` — extractors produce them, the dependency graph connects them, the indexing pipeline consumes them. Don't bypass this abstraction.
- **Concerns get inlined.** When extracting a model, all `include`d concerns are resolved and their source is inlined into the unit's source_code. This is the key differentiator from file-level tools.
- **Dependency graph is bidirectional.** First pass: each extractor records forward dependencies. Second pass: the graph resolves reverse edges (dependents). Both directions matter for retrieval.
- **PageRank for importance scoring.** `DependencyGraph` computes PageRank over the unit graph to surface high-importance nodes for retrieval ranking. `GraphAnalyzer` provides structural analysis — orphans, dead ends, hubs, cycles, and bridges — for codebase health insights.
- **Behavioral depth over structural metadata.** Extraction output answers "what happens when X runs?" not just "what exists." Callback side-effects (columns written, jobs enqueued, services called) are detected via `CallbackAnalyzer`. `BehavioralProfile` introspects resolved `Rails.application.config` values. `FlowPrecomputer` generates per-action request flow maps (opt-in via `precompute_flows` config flag, default false).
- **Navigation edges trace route helper references.** Dependency edges carry a `:via` label that distinguishes relationship types (`:belongs_to`, `:code_reference`, `:render`, `:link_to`, `:redirect_to`, `:form_action`). Navigation edges (`link_to`, `redirect_to`, `form_action`) are resolved from `_path`/`_url` route helpers via `RouteHelperResolver`. These edges mean "this unit references a route helper pointing at that controller" — the scanner matches all `_path`/`_url` usages, not just those inside `link_to` calls. `IGNORED_HELPER_PREFIXES` filters known false positives (`file_path`, `root_path`, etc.).

## Code Conventions

- `frozen_string_literal: true` on every file
- YARD documentation on every public method and class
- Extractors follow a consistent interface: `initialize`, `extract_all`, `extract_<type>_file(path)`
- All extractors return `Array<ExtractedUnit>`
- Use `Rails.root.join()` for paths, never string concatenation
- JSON output uses string keys, snake_case
- Token estimation: `(string.length / 4.0).ceil` for the OpenAI path — Benchmarked against tiktoken (cl100k_base) on 19 Ruby source files. Actual mean is 4.41 chars/token. Uses 4.0 as a conservative floor (~10.6% overestimate). See docs/TOKEN_BENCHMARK.md. The Ollama path uses 1.5 chars/token (BERT WordPiece) — see `Builder#chars_per_token_for` and `docs/EMBEDDING_MODELS.md`.
- Error handling: raise `Woods::ExtractionError` for recoverable extraction failures, let unexpected errors propagate. Always `rescue StandardError`, never bare `rescue`.

## Testing

**Two test suites** — the gem has unit specs with mocks, and a separate Rails app has integration specs that run real extractions.

- **Gem unit specs** (`spec/`): RSpec with `rubocop-rspec` enforcement. Tests core value objects, graph analysis, ModelNameCache, json_serialize, and extractor orchestration using mocks/stubs. No Rails boot required.
- **Booted-app spec** (`spec/integration/booted_extraction_spec.rb`, tagged `:booted_app`): boots the minimal `spec/dummy` Rails app **in-process** and runs a real end-to-end extraction, asserting a non-zero unit count + the expected models/associations. Excluded from the default `rake spec` (needs full Rails); the CI `rails-matrix` job opts in with `WOODS_RUN_BOOTED_APP=1` under the per-version gemfiles in `gemfiles/`. The gem supports `railties >= 6.0`; the Rails pins live in `Appraisals` (gemfiles are hand-maintained — Appraisal can't generate from the conditional base Gemfile). Run one row: `WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rspec spec/integration/booted_extraction_spec.rb`.
- **Integration specs** (in a separate Rails app): A minimal Rails 8.1 app with Post, Comment models, controllers, jobs, and a mailer. Tests run real extractions and verify output structure, dependencies, incremental extraction, git metadata, and configuration behavior. Set up a host Rails app per the Getting Started guide, then run `bundle exec rspec spec/integration/`.
- Every extractor needs tests for: happy path extraction, edge cases (empty files, namespaced classes, STI), concern inlining, dependency detection
- Test `ExtractedUnit#to_h` serialization round-trips
- Test `DependencyGraph` for cycle detection, bidirectional edge resolution, and PageRank computation
- Test `GraphAnalyzer` for structural detection: orphans, dead ends, hubs, cycles, bridges

## Testing Workflow

The approach depends on the task:

- **New extractors/features:** Strict TDD — write a failing spec in `spec/` first, implement to pass, refactor. No implementation without a failing test.
- **Bug fixes:** Fix first, then add a regression test that would have caught it.
- **Refactors:** Lean on existing specs. Run the full suite before and after. If coverage gaps exist, add specs before refactoring, not after.

```bash
# Gem unit specs (run from gem root)
bundle exec rake spec                                              # Full suite
bundle exec rake spec SPEC=spec/extractors/model_extractor_spec.rb # Single file

# Lint
bundle exec rubocop -a
```

After gem-level specs pass, validate in a host app if the change affects extraction output. See `.claude/rules/integration-testing.md` for host app validation workflow.

## Documentation

See `docs/README.md` for the documentation index and roadmap.

Key references:
- Backend selection + cost modeling → `docs/BACKEND_MATRIX.md`
- Coverage gaps + future extractor work → `docs/COVERAGE_GAP_ANALYSIS.md`
- Historical design documents (from the build phase) → `_project-resources/docs/`

## Backlog Workflow

See `.claude/skills/backlog-workflow/SKILL.md` for the full workflow: picking items, implementing with TDD, marking resolved, and adding new work.

## Session Continuity

At the end of a session, update `.claude/context/session-state.md` with breadcrumbs:

- Which backlog items were touched (resolved or in-progress)
- Which files were modified
- Any gotchas discovered during the session

At the start of a session, read `.claude/context/session-state.md` for context from the previous session.

> **Local-only files.** `.claude/context/session-state.md` and
> `.claude/rules/integration-testing.md` are intentionally gitignored
> (see `.gitignore`) — they're session-local and host-local notes, not
> shared conventions. If either file is missing in a fresh clone, create
> it (templates live in `.claude/skills/backlog-workflow/SKILL.md`'s
> references and this section). `.claude/skills/backlog-workflow/SKILL.md`
> is tracked — the workflow itself is shared.

## Gotchas

- Extraction **must** run inside a Rails app — the gem has no standalone extraction mode. All extractors assume `Rails`, `ActiveRecord::Base`, etc. are defined.
- `rails_source_extractor.rb` reads source from installed gem paths (`Gem.loaded_specs`). This is read-only and path-sensitive — don't assume gem install locations.
- Service discovery scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. If a host app uses a non-standard directory, it won't be found without configuration.
- The dependency graph can have cycles (A depends on B depends on A). Graph traversal must handle this — see `DependencyGraph#visited` tracking.
- MySQL and PostgreSQL have different JSON querying, indexing, and CTE syntax. Any database-touching code must handle both. Never write PostgreSQL-only SQL and assume it works.
- `eager_load!` is called once per extraction mode in the orchestrator (`Extractor#extract_all` and `Extractor#extract_changed`), not in individual extractors. Don't add `Rails.application.eager_load!` calls to extractors.
- Git commands use `Open3.capture2` (not backticks) to prevent shell injection. Never use backtick-style command execution for external processes.
- `callback.options` doesn't exist on modern Rails (removed in 4.2) — use `@if`/`@unless` ivars + ActionFilter duck-typing (check for `@actions` ivar as a `Set`) to extract `:only`/`:except` action lists from callbacks.
- `eager_load!` aborts completely on a single `NameError` (e.g., `app/graphql/` referencing an uninstalled gem). Zeitwerk processes dirs alphabetically, so a failure in `graphql/` prevents `models/` from loading. The gem falls back to per-directory loading via `EXTRACTION_DIRECTORIES` when this happens.
- `CallbackChain#size` does not exist on any Rails version (7.0–8.1) — `CallbackChain` includes `Enumerable` but never defines `#size`. Use `#count` instead.
- `git_available?` is memoized — won't detect git becoming available mid-extraction (acceptable tradeoff).
- Manifest `git_branch`/`git_sha` come from `Woods::GitProvenance` (`lib/woods/git_provenance.rb`), not `run_git` directly — it's worktree-aware (`.git` can be a *file* with a `gitdir:` pointer) and runs `git -C <root>` so it's cwd-independent. When a `.git` is present but git can't resolve the ref (e.g. an unmounted worktree git dir in a container) it returns `"unknown"` rather than a stale `GIT_BRANCH`/`GIT_SHA` env value; the env vars are honored only when there's **no** `.git` at the root (a non-repo checkout — `GitProvenance#git_working_tree?`) or git is unavailable. `capture_snapshot` treats `"unknown"` as no-sha (#137). The per-file `batch_git_data`/`run_git` enrichment path is separate and still cwd-based.
- Model name scanning uses a precomputed regex via `ModelNameCache` — invalidated per extraction run, not per unit. Three passes resolve references: (1) fully-qualified names via the whole-word regex; (2) string literals passed to `.constantize` / `const_get(...)` when the literal matches a known model; (3) bare short names (e.g., `Book` inside `module Library` for a `Library::Book` model) via `ModelNameCache.resolve_short_name` when unambiguous. Ambiguous short names (same inner class across multiple namespaces) are skipped to avoid false positives.
- `extract_dependencies` in all extractors must include `:via` key — see model_extractor for reference values.
- MCP server tool dispatch uses `Mutex` for thread safety — don't call tool handlers from multiple threads without going through the server's dispatch.
- The Index Server (`woods-mcp`) boots in **pattern-only mode by default** when no `woods.json` is present and no embedding provider is configured (#138) — extract-only hosts get every always-on tool with no env var. `codebase_retrieve` (semantic search) activates only when a provider is configured. `WOODS_REQUIRE_INDEX=1` restores fail-closed boot (raises `MissingArtifact`); `WOODS_ALLOW_AUTODETECT` is now a back-compat no-op. The strict-vs-default decision lives in `ConfigResolver.resolve_without_artifact`.
- Console bridge requires a booted Rails environment on the other end — it validates models against `ActiveRecord::Base.descendants` at startup.
- Console `SafeContext` wraps every request in a rolled-back transaction. Writes are silently discarded. This is intentional defense-in-depth, not a bug.
- `SqlValidator` rejects DML/DDL at the string level before any database interaction. Don't bypass it for "convenience."
- `EmbeddedExecutor` blocks sql/query tools by default. Set `read_tools_enabled: true` (via `embedded_read_tools:` on `RackMiddleware` or `Server.build_embedded`) to enable them. Even when enabled, SqlValidator + SafeContext rollback provide defense-in-depth.
- `CircuitBreaker` state is per-instance, not global. Each provider/store gets its own breaker. Don't share breaker instances across unrelated components.
- Embedding dimensions must match between provider and vector store. A mismatch (e.g., switching models) requires full re-index — `IndexValidator` detects this.
- `PipelineGuard` enforces a 5-minute cooldown on full extraction/embedding runs. Incremental runs are not rate-limited.
- `CallbackAnalyzer` parses source via regex, not AST — it scans for patterns like `self.col =`, `perform_later`, etc. Proc/lambda callbacks are skipped gracefully.
- `BehavioralProfile` guards every config introspection with `respond_to?`/`defined?` — a missing config section produces `nil`, not an error.
- `FlowPrecomputer` is gated by `precompute_flows` config (default: false). Per-action errors are rescued so one failing action doesn't block others.
- Incremental re-extraction skips unit types that don't map to individual files: `route`, `middleware`, `engine`, `scheduled_job`. These types require full extraction to update. This is acceptable — their source files rarely change independently.
- Session tracer requires explicit store configuration (`session_store`) — no default store is provided. Set `session_tracer_enabled = true` and assign a store (FileStore, RedisStore, or SolidCacheStore) in the configure block.
- Session tracer middleware position matters — it must be inserted after the session middleware but before the router. The railtie handles this via `app.middleware.use`.
- `RedisStore` raises `SessionTracerError` if the `redis` gem is not available at initialization time.
- `RakeTaskExtractor` reads `.rake` files statically (no Rails boot required for parsing). It uses `block_opener?` for depth tracking — `if`/`unless` only match at line start to avoid counting trailing modifiers as blocks.
- Temporal snapshots are gated by `enable_snapshots` config (default: false). `SnapshotStore` requires migrations 004 + 005 to be run first.
- `StateMachineExtractor` and `FactoryExtractor` return arrays from their file methods (like `ScheduledJobExtractor`) — can't be registered in FILE_BASED dispatch map. Incremental re-extraction skips these types.
- `EventExtractor` uses a two-pass approach (collect publishes, then subscribes, then merge) — no single-file extraction method exists. Like routes, it requires full extraction to update.
- `DatabaseViewExtractor` only extracts the latest version of each Scenic view (highest `_vNN` suffix). Older versions are skipped.
- `DecoratorExtractor` scans `app/decorators/`, `app/presenters/`, and `app/form_objects/` — these directories are also added to `EXTRACTION_DIRECTORIES` for eager loading.
- `CachingExtractor` scans controllers, models, and view templates (`.erb`) — the `file_type` parameter on `extract_caching_file` defaults to nil (auto-detected from path).
- `TestMappingExtractor` scans `spec/` and `test/` directories — these are outside `app/` so they don't need eager loading. Test files are read statically.
- Notion export requires `notion_api_token` and `notion_database_ids` to be configured. If only one database ID is set, the other sync (columns or data_models) is skipped gracefully. Environment variable `NOTION_API_TOKEN` overrides config. The Notion API enforces 3 req/sec — `RateLimiter` handles this automatically.
- Obsidian export (`woods:obsidian`, `lib/woods/obsidian/`) writes a local vault — no API/token/Configuration accessors (path + flags are constructor kwargs, exposed via `WOODS_OBSIDIAN_*` env). It reads `raw_graph_data` (string keys + **persisted** pagerank — never `reader.dependency_graph`, which drops pagerank and symbolizes types). All edges derive from the graph's `edges`/`reverse`; per-unit JSON is read only for note bodies. Frontmatter is **flat-scalars-only** (Obsidian's Properties UI corrupts nested objects) emitted via Psych; structured edges live in the `_woods/` sidecar. The stale-note sweep and `.obsidian/` config writes are both gated behind a `.woods-vault` ownership sentinel + a 30% purge guard (mirrors Unblocked). `include_framework` covers `rails_source` only (`gem_source` is unreachable via `IndexReader::TYPE_DIRS`). See `docs/OBSIDIAN_INTEGRATION.md`.
- Explorer export (`woods:explore`, `lib/woods/explorer/`) follows the Obsidian pattern: no Configuration accessors (kwargs + `WOODS_EXPLORER_*` env), reads `raw_graph_data` for persisted pagerank, writes via `AtomicFile`, `.woods-explorer` sentinel guards overwrites of foreign non-empty dirs. Output is byte-identical for an unchanged extraction — never stamp build-time timestamps into it. The frontend is dependency-free vanilla JS in `assets/{template.html,style.css,app.js}`; the embedded JSON escapes `</` (`<\/`) plus `<!--`/`<script` (`<`, guarding the tokenizer's double-escaped states) so payload content can't terminate the script tag; all data-driven DOM text goes through `textContent`. Family color slots in `app.js` PALETTES are CVD-validated per theme — don't reorder or eyeball-edit them (see docs/EXPLORER.md).
- Model callback chains are per-EVENT (`_save_callbacks`), never per kind+event — `_before_save_callbacks` does not exist on any Rails version. `extract_callbacks` derives the public name as `kind_event` and filters framework-owned callbacks via `Method#owner` (`FRAMEWORK_CALLBACK_OWNER`), not name blocklists. Proc/lambda filters are skipped (no stable name; `to_s` embeds object addresses and breaks idempotency).
- Navigation edge extraction (`link_to`, `redirect_to`, `form_action`) is gated by `extract_navigation_edges` config (default: true). Extractors that scan for navigation edges must include both `SharedDependencyScanner` and `RouteHelperResolver`, and call `build_route_helper_map` in their initializer.
- `RouteHelperResolver` uses `IGNORED_HELPER_PREFIXES` to filter false positives from non-route `_path`/`_url` suffixes (e.g., `file_path`, `base_url`, `log_path`). Add new prefixes there when false positives are discovered in host apps.
- `DependencyGraph` edges are stored as `[{ target:, via: }]` hashes (symbol keys). `IndexReader` normalizes from JSON to `[{ 'target' => ..., 'via' => ... }]` (string keys). The two normalizers (`DependencyGraph.normalize_edges` vs `IndexReader.normalize_all_edges`) are intentionally separate — do not merge them.
- `DependencyGraph.from_h` handles both old-format (bare string) and new-format (hash) edges via `normalize_edges`. Old serialized graphs load without migration.
- `dependencies_of` and `dependents_of` accept an optional `via:` filter (Symbol or Array<Symbol>). The MCP `dependencies`/`dependents` tools expose this as a `via` array parameter.
