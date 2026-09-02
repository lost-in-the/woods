# Woods

Ruby gem that extracts structured data from Rails applications for AI-assisted development. Uses runtime introspection (not static parsing) to produce version-accurate representations: inlined concerns, resolved callback chains, schema-aware associations, dependency graphs. All major layers are complete: extraction (34 extractors + 7 helpers), retrieval (query classification, hybrid search, RRF ranking), storage (pgvector, Qdrant, SQLite adapters), embedding (OpenAI, Ollama), two MCP servers (29-tool index server, 14 always-on + 15 wiring-conditional; 31-tool console server), AST analysis, flow extraction, temporal snapshots, Notion + Obsidian export, and evaluation harness.

## Commands

```bash
# Development
# Prefer the checked-in binstubs (bin/rake, bin/rspec, bin/rubocop). Under
# Bundler 4 `bundle exec rake` / `bundle exec rspec` fail with "command not
# found". Bundler 4 no longer exposes gem binstubs. The binstubs work on both.
bundle install
bin/rake spec                                    # Full test suite
bin/rake spec SPEC=spec/extractors/model_extractor_spec.rb  # Single file
bin/rubocop -a                                   # Lint + autofix
bin/rubocop --auto-gen-config                    # Update .rubocop_todo.yml

# Opt-in spec tags (excluded from the default suite)
WOODS_RUN_HTTP_SERVER=1 bin/rspec spec/mcp/http_server_e2e_spec.rb   # boots exe/woods-mcp-http
WOODS_RUN_BOOTED_APP=1  bin/rspec spec/integration/booted_extraction_spec.rb
WOODS_RUN_PERF_SPECS=1  bin/rspec --tag perf

# In a host Rails app (extraction requires Rails boot)
bundle exec rake woods:extract           # Full extraction
bundle exec rake woods:incremental       # Changed files only
bundle exec rake "woods:refresh[routes]" # Re-run named extractors wholesale
bundle exec rake woods:watch             # Resident daemon: keep the index current (alias: woods:guard)
bundle exec rake woods:watch_status      # Is a daemon alive? (exit 0 = yes; for worktree hooks)
bundle exec rake woods:extract_framework # Rails/gem sources
bundle exec rake woods:validate          # Index integrity check
bundle exec rake woods:stats             # Show extraction stats
bundle exec rake woods:clean             # Remove index output
bundle exec rake woods:embed             # Embed all extracted units
bundle exec rake woods:embed_incremental # Embed changed units only
bundle exec rake "woods:retrieve[query]" # Ad-hoc retrieval against the index
bundle exec rake woods:evaluate          # Score retrieval against a ground-truth query set
bundle exec rake "woods:evaluate:baseline[grep]" # Score a naive baseline for comparison
bundle exec rake "woods:flow[entry]"     # Execution flow document for an entry point
bundle exec rake woods:console           # Embedded Console MCP server (stdio)
bundle exec rake woods:notion_sync       # Sync models/columns to Notion
bundle exec rake woods:unblocked_sync    # Sync to an Unblocked collection
bundle exec rake woods:obsidian          # Export to an Obsidian vault (alias: woods:vault)
bundle exec rake woods:generate_token    # Random bearer token for woods-mcp-http
# Woods-themed aliases: woods:scan (extract), woods:tend (incremental), woods:look (stats),
# woods:vet (validate), woods:clear (clean), woods:nest (embed), woods:hone (embed_incremental),
# woods:send (notion_sync), woods:relay (unblocked_sync)
```

### Source-checkout orientation: static Woods self-map

For an initial audit, debugging a cross-cutting change, or estimating its blast
radius within this gem, create a disposable static map before editing:

```bash
output_dir="$(mktemp -d)"
bin/rake "woods:self_map[$output_dir]"
bundle exec woods-mcp-start "$output_dir"
```

This is an internal Woods-only developer tool, not a host-app task. It publishes
the standard atomic index generation and works with the packaged Index MCP
server without Rails, a database, or embeddings. Query `woods_status`,
`structure`, `search`, `lookup`, `dependencies`, and `dependents` to find
source ownership, inspect constants and excerpts, and follow conservative
static call/dependency relationships. Use a temporary or ignored output
directory; do not scan or commit generated map output.

The self-map is deliberately static. It cannot prove Rails runtime behavior,
resolved callbacks, routes, Active Record reflections, eager-load outcomes, or
Zeitwerk behavior. When those facts matter, use a booted host Rails app and the
ordinary runtime extractor; never substitute the self-map for that validation.

> **Docker:** Extraction runs inside the container (`docker compose exec app bundle exec rake ...`). The Index Server runs on the host reading volume-mounted output. See `docs/DOCKER_SETUP.md` for the full Docker guide.

## Host app for integration testing: `woods-testbed`

Extraction and the Console MCP server both require a booted Rails environment to validate. We maintain a companion repo, [`lost-in-the/woods-testbed`](https://github.com/lost-in-the/woods-testbed), with one Rails app per supported Rails version. Clone it alongside this gem and `docker compose up` the variant you need.

**Variants** (add more by contributing a new `apps/rails-X.Y/` directory):

| Variant | Rails | Port | Container |
|---|---|---|---|
| `apps/rails-8.0` | 8.0.x | 3010 | `woods-testbed-rails-8.0` |
| `apps/rails-7.2` | ~> 7.2.0 | 3011 | `woods-testbed-rails-7.2` |
| `apps/rails-6.0` | ~> 6.0.0 | 3012 | `woods-testbed-rails-6.0` |

**Typical setup** (sibling-repo layout, the testbed's compose file defaults to `../woods` for the gem mount):

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

**Extraction output** lands under `apps/rails-<version>/tmp/woods/` inside the testbed checkout, bind-mounted read-write, so the host can read `_index.json`, `dependency_graph.json`, etc. directly.

**Adding coverage.** Smoke scripts go in the testbed's `scripts/` directory so they run unchanged against every variant. Each variant's `config/initializers/woods_console.rb` can be tweaked independently when a test needs version-specific configuration.

**The testbed is a playground.** Agents working on the gem have permission to modify anything under the testbed's `apps/`, add models, migrations, controllers, initializers, smoke scripts, seeds. Reshape it to fit the scenario. Only gem changes under `lib/woods/` go through the normal review gate.

**When to use each host:**
- **`woods-testbed` `rails-8.0`**: default. Day-to-day Rails 8 validation. Fast, small, self-contained.
- **`woods-testbed` `rails-7.2`**: when a change could plausibly behave differently on Rails 7 (Zeitwerk load paths, callback-chain internals, `eager_load!` error paths).
- **`woods-testbed` `rails-6.0`**: the supported floor (`railties >= 6.0`, #135). Use when a change touches 6.0/6.1-era APIs (e.g. `connection_db_config`, `has_many_inversing` guards) or to validate the lowest end of the matrix. Boots on Ruby 3.0.
- **`~/work/test_app`** (local-only host), when a change needs a committed integration spec, or maps cleanly to `spec/integration/` fixtures. No Docker, runs on Rails 8.1.
- **A production-shaped MySQL host app** (local-only, see `.claude/rules/integration-testing.md`), only when a problem demands a large real codebase: namespace collisions, large callback chains, non-standard service directories, many-model PageRank behaviour.

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
│   ├── extractor.rb                     # Orchestrator, coordinates all extractors
│   ├── change_set.rb                    # Normalized "what changed" (shared by every entry point)
│   ├── path_dispatcher.rb               # Changed path → extractor (file rules + whole-app triggers)
│   ├── reload_policy.rb                 # Changed path → reload/restart/reextract/ignore
│   ├── generation.rb                    # Monotonic "which version of the index is on disk"
│   ├── extracted_unit.rb                # Core value object
│   ├── dependency_graph.rb              # Directed graph + PageRank scoring
│   ├── graph_analyzer.rb               # Structural analysis (orphans, hubs, cycles, bridges)
│   ├── model_name_cache.rb             # Precomputed regex for dependency scanning
│   ├── retriever.rb                     # Retriever orchestrator (strategy dispatch + type-rank reporting)
│   ├── flow_precomputer.rb             # Pre-computed per-action request flow maps
│   ├── flow_assembler.rb               # Per-query runtime flow aggregation
│   ├── flow_document.rb                # Serialization envelope for flow output
│   ├── filename_utils.rb               # Safe filename generation
│   ├── index_artifact.rb               # Dump promotion + safe path handling
│   ├── atomic_file.rb                   # Crash-safe temp+fsync+rename file writes (shared)
│   ├── resolved_config.rb              # Frozen configuration snapshot
│   ├── token_utils.rb                  # Token count estimation helpers
│   ├── extractors/                      # 34 extractors + 7 helpers (shared_utility_methods, shared_dependency_scanner, callback_analyzer, behavioral_profile, route_helper_resolver, ast_source_extraction, source_nesting)
│   ├── ast/                             # Prism-based AST layer
│   ├── ruby_analyzer/                   # Static analysis (class, method, dataflow)
│   ├── flow_analysis/                   # Execution flow tracing
│   ├── chunking/                        # Semantic chunking (Chunk, SemanticChunker)
│   ├── embedding/                       # Embedding pipeline (OpenAI, Ollama, Indexer)
│   ├── storage/                         # Storage backends (VectorStore, MetadataStore, GraphStore, Pgvector, Qdrant)
│   ├── retrieval/                       # Retrieval pipeline (QueryClassifier, SearchExecutor, Ranker, ContextAssembler)
│   ├── formatting/                      # Human-readable context formatting (HumanAdapter)
│   ├── export/                          # Shared export fact extraction (UnitFacts) over unit metadata
│   ├── notion/                          # Notion export (Client, Exporter, RateLimiter, Mappers)
│   ├── obsidian/                        # Obsidian vault export (VaultExporter, NoteBuilder, NameMapper, VaultAssets)
│   ├── mcp/                             # MCP Index Server (29 tools, 14 always-on + 15 wiring-conditional: 5 operator / 4 feedback / 4 snapshot / 1 session_trace / 1 notion; 2 resources, 2 templates)
│   ├── console/                         # Console MCP Server (31 tool schemas across 4 tiers: 9 read-only / 9 domain-aware / 10 analytics / 3 guarded; only Tier 1 plus the two read tools register)
│   ├── coordination/                    # Multi-agent pipeline locking
│   ├── feedback/                        # Agent self-service (FeedbackStore, GapDetector)
│   ├── operator/                        # Pipeline management (StatusReporter, ErrorEscalator, PipelineGuard)
│   ├── observability/                   # StructuredLogger
│   ├── resilience/                      # CircuitBreaker, RetryableProvider, IndexValidator
│   ├── cache/                           # Response caching (CacheMiddleware, CacheStore, Redis, SolidCache)
│   ├── cost_model/                      # Cost estimation (EmbeddingCost, Estimator, ProviderPricing, StorageCost)
│   ├── session_tracer/                  # Session tracing middleware + flow assembly (FileStore, RedisStore, SolidCacheStore)
│   ├── watch/                           # Resident index daemon (Daemon, Status, polling + listen watchers)
│   ├── temporal/                        # Temporal snapshot system (SnapshotStore, diff, history)
│   ├── db/                              # Schema management (migrations, Migrator, SchemaVersion)
│   ├── evaluation/                      # Retrieval evaluation (Metrics, Evaluator, BaselineRunner)
│   └── unblocked/                       # Unblocked exporter (Client, DocumentBuilder, Exporter, RateLimiter, SyncManifest)
├── generators/woods/                    # Rails generators (install, pgvector)
├── tasks/
│   └── woods.rake                       # Rake task definitions
exe/
├── woods-mcp                            # MCP Index Server executable (stdio)
├── woods-mcp-start                      # Preflight wrapper: validates, then execs woods-mcp (no restart loop)
├── woods-mcp-http                       # MCP Index Server executable (HTTP/Rack)
└── woods-console-mcp                    # Console MCP Server executable
```

## Key Design Decisions

- **Runtime introspection over static parsing.** Extractors require a booted Rails environment. This is intentional, `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs give us data that no parser can.
- **Backend agnostic.** The gem must work equally well with MySQL or PostgreSQL, Qdrant or pgvector, Sidekiq or Solid Queue, OpenAI or Ollama. Never hardcode or default to a single backend. See `docs/BACKEND_MATRIX.md`.
- **ExtractedUnit is the universal currency.** Everything flows through `ExtractedUnit`, extractors produce them, the dependency graph connects them, the indexing pipeline consumes them. Don't bypass this abstraction.
- **Concerns get inlined.** When extracting a model, all `include`d concerns are resolved and their source is inlined into the unit's source_code. This is the key differentiator from file-level tools.
- **Dependency graph is bidirectional.** First pass: each extractor records forward dependencies. Second pass: the graph resolves reverse edges (dependents). Both directions matter for retrieval.
- **PageRank for importance scoring.** `DependencyGraph` computes PageRank over the unit graph to surface high-importance nodes for retrieval ranking. `GraphAnalyzer` provides structural analysis, orphans, dead ends, hubs, cycles, and bridges, for codebase health insights.
- **Behavioral depth over structural metadata.** Extraction output answers "what happens when X runs?" not just "what exists." Callback side-effects (columns written, jobs enqueued, services called) are detected via `CallbackAnalyzer`. `BehavioralProfile` introspects resolved `Rails.application.config` values. `FlowPrecomputer` generates per-action request flow maps (opt-in via `precompute_flows` config flag, default false).
- **Navigation edges trace route helper references.** Dependency edges carry a `:via` label that distinguishes relationship types (`:belongs_to`, `:code_reference`, `:render`, `:link_to`, `:redirect_to`, `:form_action`). Navigation edges (`link_to`, `redirect_to`, `form_action`) are resolved from `_path`/`_url` route helpers via `RouteHelperResolver`. These edges mean "this unit references a route helper pointing at that controller", the scanner matches all `_path`/`_url` usages, not just those inside `link_to` calls. `IGNORED_HELPER_PREFIXES` filters known false positives (`file_path`, `root_path`, etc.).

## Code Conventions

- `frozen_string_literal: true` on every file
- YARD documentation on every public method and class
- Extractors follow a consistent interface: `initialize`, `extract_all`, `extract_<type>_file(path)`
- All extractors return `Array<ExtractedUnit>`
- Use `Rails.root.join()` for paths, never string concatenation
- JSON output uses string keys, snake_case
- Token estimation: `(string.length / 4.0).ceil` for the OpenAI path. Benchmarked against tiktoken (cl100k_base) on 19 Ruby source files. Actual mean is 4.41 chars/token. Uses 4.0 as a conservative floor (~10.6% overestimate). See docs/TOKEN_BENCHMARK.md. The Ollama path uses 1.5 chars/token (BERT WordPiece), see `Builder#chars_per_token_for` and `docs/EMBEDDING_MODELS.md`.
- Error handling: raise `Woods::ExtractionError` for recoverable extraction failures, let unexpected errors propagate. Always `rescue StandardError`, never bare `rescue`.

## Testing

**Two test suites**: the gem has unit specs with mocks, and a separate Rails app has integration specs that run real extractions.

- **Gem unit specs** (`spec/`): RSpec (`rubocop-rspec` is installed but not loaded as a RuboCop plugin, enabling it repo-wide is an open backlog item). Tests core value objects, graph analysis, ModelNameCache, json_serialize, and extractor orchestration using mocks/stubs. No Rails boot required.
- **Booted-app spec** (`spec/integration/booted_extraction_spec.rb`, tagged `:booted_app`): boots the minimal `spec/dummy` Rails app **in-process** and runs a real end-to-end extraction, asserting a non-zero unit count + the expected models/associations. Excluded from the default `rake spec` (needs full Rails); the CI `rails-matrix` job opts in with `WOODS_RUN_BOOTED_APP=1` under the per-version gemfiles in `gemfiles/`. The gem supports `railties >= 6.0`; the Rails pins live in `Appraisals` (gemfiles are hand-maintained. Appraisal can't generate from the conditional base Gemfile). Run one row: `WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rspec spec/integration/booted_extraction_spec.rb`.
- **Integration specs** (in a separate Rails app): A minimal Rails 8.1 app with Post, Comment models, controllers, jobs, and a mailer. Tests run real extractions and verify output structure, dependencies, incremental extraction, git metadata, and configuration behavior. Set up a host Rails app per the Getting Started guide, then run `bundle exec rspec spec/integration/`.
- Every extractor needs tests for: happy path extraction, edge cases (empty files, namespaced classes, STI), concern inlining, dependency detection
- Test `ExtractedUnit#to_h` serialization round-trips
- Test `DependencyGraph` for cycle detection, bidirectional edge resolution, and PageRank computation
- Test `GraphAnalyzer` for structural detection: orphans, dead ends, hubs, cycles, bridges

## Testing Workflow

The approach depends on the task:

- **New extractors/features:** Strict TDD, write a failing spec in `spec/` first, implement to pass, refactor. No implementation without a failing test.
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
- Incremental extraction contract + dispatch inventory + differential harness → `docs/INCREMENTAL_EXTRACTION.md`
- Backend selection + cost modeling → `docs/BACKEND_MATRIX.md`
- Historical design documents (from the build phase) live in git history, see `docs/design/README.md`

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
> (see `.gitignore`), they're session-local and host-local notes, not
> shared conventions. If either file is missing in a fresh clone, create
> it (templates live in `.claude/skills/backlog-workflow/SKILL.md`'s
> references and this section). `.claude/skills/backlog-workflow/SKILL.md`
> is tracked, the workflow itself is shared.

## Gotchas

Grouped by layer. Each bullet is one claim; the linked file is the source of truth.

### Extraction

- Extraction **must** run inside a Rails app. There is no standalone mode; every extractor assumes `Rails` and `ActiveRecord::Base` exist.
- `rails_source_extractor.rb` reads from installed gem paths (`Gem.loaded_specs`). Read-only and path-sensitive; never assume install locations.
- Service discovery scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. Other directories are not found.
- Class names come from `SourceNesting#qualified_first_class_name` (position-aware, #174). `SharedUtilityMethods#extract_class_name` and every per-extractor copy go through it. Do not reintroduce a first-`class`-token regex.
- The dependency graph can have cycles. Traversal must handle them; see `DependencyGraph#visited`.
- MySQL and PostgreSQL differ in JSON querying, indexing, and CTE syntax. Any host-database SQL must work on both.
- `eager_load!` runs once per extraction mode in the orchestrator (`Extractor#extract_all`, `#extract_changed`). Do not add it to extractors.
- `eager_load!` aborts on a single `NameError` (for example `app/graphql/` referencing an uninstalled gem). Zeitwerk loads directories alphabetically, so `graphql/` failing blocks `models/`. The gem falls back to per-directory loading via `EXTRACTION_DIRECTORIES`.
- Git commands use `Open3.capture2`, never backticks (shell injection).
- `callback.options` does not exist on modern Rails (removed in 4.2). Use the `@if`/`@unless` ivars and ActionFilter duck-typing (`@actions` as a `Set`) for `:only`/`:except`.
- `CallbackChain#size` does not exist on any supported Rails. Use `#count`.
- `git_available?` is memoized; git becoming available mid-extraction is not detected. Accepted.
- Manifest `git_branch`/`git_sha` come from `Woods::GitProvenance` (`lib/woods/git_provenance.rb`), which is worktree-aware and cwd-independent (`git -C <root>`).
  - A present `.git` whose ref cannot be resolved (an unmounted worktree git dir in a container) yields `"unknown"`, never a stale env value.
  - `GIT_BRANCH`/`GIT_SHA` env vars count only when there is **no** `.git` at the root, or git is unavailable.
  - `capture_snapshot` treats `"unknown"` as no-sha (#137). The per-file `batch_git_data`/`run_git` path is separate and cwd-based.
- Model name scanning uses a precomputed regex via `ModelNameCache`, invalidated per run. Three passes: whole-word fully-qualified names; string literals passed to `constantize`/`const_get`; unambiguous bare short names via `ModelNameCache.resolve_short_name`. Ambiguous short names are skipped.
- `extract_dependencies` in every extractor must include `:via`. See `model_extractor` for reference values.
- `CallbackAnalyzer` is regex-based, not AST. Proc and lambda callbacks are skipped.
- `BehavioralProfile` guards every config read with `respond_to?`/`defined?`; a missing section yields `nil`.
- `FlowPrecomputer` is gated by `precompute_flows` (default false). Per-action errors are **not** rescued: both the full path and the incremental delta assemble fail closed, and any flow-family failure aborts the run before the generation publish.

### Incremental extraction

- Incremental is held to **equivalence with a full extraction** (#164). `Extractor#extract_changed` runs in a fixed order:
  1. Blast radius from the pre-change graph.
  2. Dispatch the changed paths (`PathDispatcher`, which reaches never-seen files).
  3. Re-extract the rest of the blast radius.
  4. Reconcile class-based types against runtime discovery.
  5. Re-run whole-app extractors whose triggers fired.
  6. Prune vanished units.
  7. Reconcile class-based types **again** (pruning can un-know a class the first pass skipped).
  8. Refresh `dependents`, `metadata.git`, PageRank, `graph_analysis.json`.
- The oracle is `spec/integration/incremental_equivalence_spec.rb` (`:booted_app`). Run it before and after touching the incremental path.
- `Extractor::WHOLE_APP_EXTRACTORS` (route, middleware, engine, scheduled_job, state_machine, factory, event, database_view) re-run **wholesale** when a `PathDispatcher.whole_app_rules` trigger changes. A routes re-run also replaces `ROUTE_CONSUMER_EXTRACTORS` (controllers, mailers, components, view components, view templates).
- Wholesale replacement prunes by `(identifier, type)`, never by bare identifier (#225). Two units sharing an identifier across types are distinct graph nodes.
- `Extractor#refresh(*keys)` (`woods:refresh`) is the by-name counterpart to the by-trigger path. Both must call `prepare_incremental_run` first or they inherit `@dependents_dirty`/`@incremental_written`.
- Every Woods-written JSON artifact is read through `AtomicFile.read`. A bare `File.read` tags content with the process default external encoding (US-ASCII under `LANG=C`) and raises on multibyte bytes.

### MCP servers

- Tool dispatch uses a `Mutex`. Do not call tool handlers from multiple threads outside the server's dispatch.
- The Index Server boots in **pattern-only mode** when no `woods.json` is present and no provider is configured (#138). `codebase_retrieve` activates only with a provider. `WOODS_REQUIRE_INDEX=1` restores fail-closed boot. `WOODS_ALLOW_AUTODETECT` is a back-compat no-op. See `ConfigResolver.resolve_without_artifact`.
- Every payload reader resolves through `Generation#payload_dir`. A flat (pre-2.0) index resolves to the root; never read `manifest.json` from the root directly.
- Both servers are `MCP::Server` instances from the `mcp` gem (`>= 1.2, < 2.0`). Woods writes no protocol code.
- **Never pin `MCP_PROTOCOL_VERSION`.** The SDK server is dual-era; pinning collapses it to one. The env var is an escape hatch only.
- mcp 1.2.0 provides `server/discover`, stateless HTTP, request-envelope validation, header checks, cache hints, and `resultType`. It does not implement the Tasks extension or `subscriptions/listen`; Woods supplies durable `tasks/*` locally and generation-driven push stays blocked upstream.
- `woods-mcp-http` is **stateless by default** (`WOODS_MCP_HTTP_STATELESS=0` restores sessions for one deprecation window). Stateless has no notification channel; `IndexReader#ensure_fresh!` is the correctness path for freshness.
- `Woods::MCP::ProtocolPolicy` owns two decisions:
  - `cache_scope` is pinned to `'private'` and must stay non-configurable. The SDK falls back to `'public'` when only `ttl_ms` is set, which would let a shared proxy re-serve one user's source to another.
  - `sort_tools!` runs after every conditional registration so tool order is stable across hosts (prompt cache, offset-based `tools/list` pagination).
- `Woods::MCP::Tasks` (protocol extension) is distinct from `Woods::Tasks` (rake helpers).
  - `Store` writes one file per task under `<index_dir>/tasks/` and deliberately does **not** take `PipelineLock` (taking it would deadlock `pipeline_extract`).
  - Orphan detection marks a `working` record whose producer is gone as `failed`. A pid table can only judge a producer that shares the reader's boot identity and pid namespace; a foreign one is believed on age alone, up to `Store::FOREIGN_PRODUCER_GRACE_SECONDS` (24h from `updated_at`), then resolved to `failed` so a rebooted host stops answering `working` forever.
  - A task handle is returned only to a client that declared `io.modelcontextprotocol/tasks`. The opt-in is captured per request into a thread-local cleared in an `ensure`.

### Console server

- The console needs a booted Rails environment; it validates models against `ActiveRecord::Base.descendants` at startup.
- `SafeContext` wraps every request in a rolled-back transaction. Writes are silently discarded. On MySQL the statement timeout is session-scoped and is restored in `ensure`.
- `SqlValidator` rejects DML/DDL at the string level. Do not bypass it.
- `SqlNoiseStripper` must know every comment form the host database executes (`--`, `#`, `/* */`, and MySQL `/*! */`, which is live SQL). Table gating runs on the stripped text, so a stripping gap is a gate bypass.
- Redacted columns are refused as aggregate, scope, find, and order inputs, not only masked on output. A comparison oracle over a secret is still a leak.
- `EmbeddedExecutor` blocks `console_sql`/`console_query` by default. Enable with `embedded_read_tools:` on `RackMiddleware` or `config.console_embedded_read_tools` for the stdio server.

### Storage, embedding, retrieval

- `CircuitBreaker` state is per instance. Never share a breaker across unrelated components.
- Never `respond_to?` against an Interface module (B-108): the stubs answer true and raise `NotImplementedError`, which `rescue StandardError` does not catch. Use ownership checks (`implements_own?`).
- Embedding dimensions must match between provider and store. `Woods::MCP::DimensionMismatch` is raised from two places:
  - `Tasks.verify_store_dimensions!` at the start of `woods:embed` for durable stores, via the adapter's `stored_dimensions`.
  - `Storage::Snapshotter::Vector.load` at MCP boot when the WVF1 header disagrees with `resolved_config.dimension`. An empty dump carries no dimension and is not checked.
- Qdrant point IDs are **UUIDv5**, not identifiers (#147). The identifier travels in the payload under `woods_identifier`. **Never change `POINT_ID_NAMESPACE`**: a new namespace orphans every existing vector.
- `checkpoint.json` never advances over a unit whose vector is not durably stored (B-059 / #148). On `:local`/`:shared_filesystem` the dump is the only durable copy, so the checkpoint is written after `persist_snapshot` and interval saves are suppressed. `checkpoint_satisfied?` requires the hydrated artifact to hold the vector, so a checkpoint that ran ahead self-heals into a re-embed.
- `PipelineGuard` enforces a 5-minute cooldown on full runs. Incremental runs are not rate-limited.

### Watch daemon

- `woods:watch` (`lib/woods/watch/`) is dev-only and adds no network listener. Every collaborator is injected; `Daemon#process` is the supported embedding point. Config is via `WOODS_WATCH_*` env vars. See `docs/WATCH_DAEMON.md`.
- Rescue `ScriptError` as well as `StandardError` wherever a reload can happen. A `SyntaxError` must degrade the daemon, not kill it.
- The watcher starts **before** catch-up so a save during catch-up is captured. Catch-up reconciles against the `generation.json` mtime; a missing file means one full extraction. Deletions are found by checking registered paths, then one cycle runs with an **empty** change set so the extractor's bounded sweep reaches the ghosts.
- `Status#alive?` disbelieves records older than `STALE_AFTER` (15 min) and compares host identity before pid liveness (a dead container pid usually exists on the host). The daemon heartbeats at `HEARTBEAT_INTERVAL`, republishing the last state.
- Debounce coalesces only because the watcher callback enqueues and returns; the drain loop does the work. Do not move the work back into the callback.
