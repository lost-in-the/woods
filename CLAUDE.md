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
│   ├── change_set.rb                    # Normalized "what changed" (shared by every entry point)
│   ├── path_dispatcher.rb               # Changed path → extractor (file rules + whole-app triggers)
│   ├── reload_policy.rb                 # Changed path → reload/restart/reextract/ignore
│   ├── generation.rb                    # Monotonic "which version of the index is on disk"
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
- Incremental extraction contract + dispatch inventory + differential harness → `docs/INCREMENTAL_EXTRACTION.md`
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
- Qdrant point IDs are **UUIDv5, not Woods identifiers** (#147). Qdrant accepts only a uint or a UUID as a point id, so the adapter derives one from the identifier via `Util::UUID5` over the pinned `Qdrant::POINT_ID_NAMESPACE` and carries the identifier in the payload under `woods_identifier` (`IDENTIFIER_KEY`) — deliberately not `identifier`, which the Indexer already uses for the unit's *base* id while the point id derives from the chunk-suffixed embed id. `#search` reverse-maps so it returns identifiers like pgvector does; `#delete` routes through the same `.point_id`, because a delete that computes a different id is silent data retention rather than a visible error. Keep the translation inside the adapter — pgvector and the in-memory store use identifiers as ids directly, and the Indexer is backend-agnostic. **Never change `POINT_ID_NAMESPACE`**: a stable v5 id is what makes a re-embed of an unchanged unit replace its point instead of duplicating it, so a new namespace orphans every existing vector. `Util::UUID5` hashes UTF-8 *bytes* and transcodes non-UTF-8 names, so a point id doesn't move with the process's `LANG`. The adapter's coverage is against a mocked `Net::HTTP` — no live-Qdrant validation exists in CI.
- `checkpoint.json` must never advance over a unit whose vector was not durably stored (B-059 / #148). On the `:local` / `:shared_filesystem` presets the in-memory vector store's *only* durable copy is the dump, so `Indexer#process_units` writes the checkpoint **after** `persist_snapshot` has promoted the dump, and suppresses the `checkpoint_interval` saves entirely on that path — a dump is a whole-store snapshot, so there is no partial durability for an interval save to record, and recording it anyway is the #148 loss in miniature. Durable backends keep the interval saves because each `store_batch` *is* the durable write. The other half is `checkpoint_satisfied?`: a matching `source_hash` is honoured only when the hydrated artifact actually holds a vector for that identifier, so a checkpoint that ran ahead of its dump self-heals into a re-embed (and warns) instead of stranding the unit forever. An incremental run hydrates the store from `dumps/latest` first — lossless, because WVF1 persists id + floats only, and woods-mcp back-fills per-vector metadata from `metadata.msgpack` at boot. Every run dumps now, so `persist_snapshot` walks the dump-directory timestamp forward on collision rather than letting `IndexArtifact#new_dump_dir` raise `EEXIST` over work already paid for. Still stale after an incremental embed: vectors for units deleted from the index entirely — a full `woods:embed` compacts those (chunk ids a re-embedded unit no longer produces *are* pruned).
- `PipelineGuard` enforces a 5-minute cooldown on full extraction/embedding runs. Incremental runs are not rate-limited.
- `CallbackAnalyzer` parses source via regex, not AST — it scans for patterns like `self.col =`, `perform_later`, etc. Proc/lambda callbacks are skipped gracefully.
- `BehavioralProfile` guards every config introspection with `respond_to?`/`defined?` — a missing config section produces `nil`, not an error.
- `FlowPrecomputer` is gated by `precompute_flows` config (default: false). Per-action errors are rescued so one failing action doesn't block others.
- Incremental extraction is held to *equivalence with a full extraction* (#164). `Extractor#extract_changed` runs in a fixed order — compute the blast radius from the pre-change graph, dispatch the changed paths themselves (`PathDispatcher`, which is what reaches files the index has never seen), re-extract whatever of the blast radius that did not already cover, reconcile class-based types against their runtime discovery sets, re-run whole-app extractors whose triggers fired, prune vanished units, then reconcile class-based types **once more** (pruning can un-know a class the first pass skipped — a class-based file moved between autoload dirs with its constant unchanged) — and then refreshes `dependents`, `metadata.git`, PageRank and `graph_analysis.json`. The oracle is `spec/integration/incremental_equivalence_spec.rb` (`:booted_app`): randomized create/modify/delete/rename sequences compared against a cold full extraction at every step. Run it before and after touching anything on the incremental path.
- Unit types with no per-file entry point (`route`, `middleware`, `engine`, `scheduled_job`, `state_machine`, `factory`, `event`, `database_view`) are listed in `Extractor::WHOLE_APP_EXTRACTORS` and re-run **wholesale** when a `PathDispatcher.whole_app_rules` trigger path changes. A routes re-run also replaces `ROUTE_CONSUMER_EXTRACTORS` (controllers, mailers, components, view components, view templates) — those embed the route table, and the graph can't express that dependency because a route unit depends *on* its controller, not the other way round.
- `Extractor#refresh(*keys)` (and `woods:refresh`) re-runs named extractors wholesale against a booted app — the by-name counterpart to the by-trigger-path path in `extract_changed`. It shares `replace_type_wholesale`, so a routes refresh cascades to `ROUTE_CONSUMER_EXTRACTORS` there too. Both entry points must call `prepare_incremental_run` first or they inherit the previous run's `@dependents_dirty`/`@incremental_written`.
- The watch daemon (`woods:watch`, `lib/woods/watch/`) is dev-only and adds no network listener. Every collaborator is injected, so `Daemon#process` runs one whole cycle for a batch and is the supported embedding point — it drains carried-forward paths itself, so an embedded caller gets the same retry behaviour `#run` does. The unit specs drive it with a stubbed extractor and no Rails at all. Config is via `WOODS_WATCH_*` env vars, not `Configuration` (same precedent as the Obsidian exporter). Rescue `ScriptError` as well as `StandardError` anywhere a reload can happen: `SyntaxError` is not a `StandardError`, and a half-typed file must degrade the daemon, not kill it. See `docs/WATCH_DAEMON.md`.
- A daemon that only reacts to events it witnessed is stale from birth, and callers stand down for a live daemon — so "alive" has to mean "covered". `Daemon#run` reconciles against the index's own watermark (the `generation.json` mtime, written last on every successful run) before waiting for its first event; `catch_up: false` opts out. A missing generation file means no index, so every file is uncovered and the storm threshold correctly turns that into one full extraction. Deletions leave no mtime to scan, so catch-up separately checks the graph's registered paths for files gone from disk and, if any, runs one cycle with an **empty** change set — the extractor's bounded sweep reaches the ghosts; naming the paths would make the deletions authoritative and remove units with nominal paths (Rails < 7.1 `SchemaMigration`).
- `Status#alive?` disbelieves a record older than `STALE_AFTER` (15 min), and cycle boundaries are the only other thing that writes one — so the daemon runs a heartbeat (`HEARTBEAT_INTERVAL`, a third of the window) re-stamping the *last published* record. It republishes the last state rather than `running`: a degraded daemon is still degraded between events. Without it a healthy but quiet daemon — the most common state for a worktree nobody is typing in — reads as dead and every caller stops standing down.
- Debounce only coalesces because the watcher callback merges into `@pending` and returns (`enqueue`) instead of processing inline; the drain loop then sleeps and `#process` picks up everything that landed. Sleeping alone just delays the first of three cycles. Don't move the work back into the callback.
- `PollingWatcher` snapshots `[mtime.to_f, size]`, never `mtime.to_i`. Whole-second truncation loses a second write inside the same second *permanently* — no later event mentions the file again — and save-then-formatter at a 1s interval is ordinary. Size is the tiebreaker for filesystems that genuinely only offer whole seconds. Both watchers set their stop flag in the constructor, not at the top of their loop, or a `stop` racing startup is silently overwritten.
- `IndexReader` self-refreshes when the published generation moves (`ensure_fresh!` at the top of every public read; one `File.stat`, parsed only when the signature moved). The signature is `[mtime, size, ino]` — the inode is load-bearing, not paranoia: two same-second bumps with equal payload size are the daemon's *steady state* (reason `"incremental"` every cycle), and on a coarse-mtime filesystem such as a Docker volume mount `[mtime, size]` alone would serve a stale index indefinitely. `AtomicFile` renames a fresh tempfile per publish, so the inode always moves. The MCP `reload` tool is therefore an optimization, not a correctness requirement. `with_pinned_generation` suppresses invalidation across a multi-read sequence but does **not** snapshot — a never-read artifact still loads from disk as it stands. Pins are **refcounted** and the check-and-reload runs under a per-reader mutex: `woods-mcp-http` executes tool handlers on its Rack server's request threads, and a boolean pin let the first of two overlapping pins unpin the reader for both. Pass `auto_refresh: false` in specs that assert caching.
- Writers against one index serialize on `PipelineLock` (`Watch::Daemon::LOCK_NAME`) — all four of them: `woods:extract`, `woods:incremental`, `woods:refresh`, and the daemon. A refresh rewrites the whole dependency graph, so an unlocked one silently discards a concurrent writer's work and then bumps the generation over it; atomic writes don't help, because each write is individually intact and the *set* is not. The daemon yields when contended and carries its paths into the next cycle — a skipped cycle must never lose paths, since no later event will mention them again, and the same carry-forward covers a failed reload and a raising extraction. Manual rake runs wait 30s then proceed with a warning (hanging CI is worse than an overlap the index survives). `woods:incremental` stands down for a `:running` daemon but **not** a `:degraded` one — degraded means alive-but-not-updating, and standing down would exit 0 over work nothing is doing. `WOODS_IGNORE_WATCH=1` overrides. Worktrees themselves never contend — separate `Rails.root`, separate output dir, and that disjointness is deliberate: no shared index, no multiplexing.
- Read Woods' own JSON artifacts with `AtomicFile.read`, never a bare `File.read`. `.write` is binmode so bytes land verbatim, but `File.read` tags the result with the process's **default external** encoding — US-ASCII under `LANG=C`, the default in a plain Docker image and exactly where the daemon runs. The daemon writes status reasons containing em dashes, so one lock contention used to raise `Encoding::InvalidByteSequenceError` out of `Status#read` and take `woods:watch_status`, the hook sync's deference check and `woods_status` with it. The gem's own suite runs under US-ASCII, so it is a live canary — don't paper over a failure there with `encoding:` in a spec helper.
- Two daemons on one index is prevented at startup, not just serialized: `Daemon#run` returns `:already_running` when `Status#alive?` reports a *different* live pid. `PipelineLock` stopped them interleaving writes but not both existing — they would alternate the lock, double the extraction work, and both publish to one status file, so `alive?` answered for whichever wrote last and `woods:watch_status` could not tell you there were two. A crashed predecessor doesn't trip it (`alive?` requires the recorded pid to exist); `WOODS_IGNORE_WATCH=1` overrides, same as for `woods:incremental`.
- The daemon adds its own output directory to the ignore list when it sits inside the watched tree (`Daemon#ignored_directories`). Every cycle writes `generation.json` and `status.json`, so watching it means each cycle manufactures the events that trigger the next — a daemon that never idles and an index that rewrites itself forever. The default `tmp/woods` is covered by `tmp` already, which is why this never bit; a `WOODS_OUTPUT` anywhere else under the root (`.woods/`, `woods_index/`) had nothing protecting it.
- `TreeScan` follows symlinked directories, with a `visited` set keyed on the **resolved** path. `Find` stats with `lstat`, so a symlinked dir was neither descended nor reported — the entry vanished — while a full extraction's `Dir.glob` *does* follow it. The set is what makes following terminate (a link to its own ancestor is an infinite tree) and what stops two links onto one target yielding every file twice, which would read as two changes to `PollingWatcher`'s walk diff. `Find.find` lstats even the root it is handed, so `descend_symlink` walks the *resolved* directory and rewrites results back under the link — callers compare these paths against change sets and the graph, so they must read as the tree looks, not as it resolves.
- `Status#recent?` compares against the **injected** clock, not `Time.now`. The clock is injected so a spec can drive staleness without sleeping for a quarter of an hour; taking the left-hand side from the wall clock regardless made that injection a no-op for the one thing it exists to test.
- `ViewComponentExtractor#discoverable_classes` filters previews and anonymous classes, not just `extract_component`. That set is also the incremental path's class-reconciliation input, so a class the extractor always rejects made every run recompute the same "addition", extract it, get `nil`, and dirty the dependents pass for nothing.
- `register_and_write` skips the file write when the bytes on disk are already exactly what would be written — but only the *write*. Graph registration, the dependents marking and `@incremental_written` still happen for every unit, because those are what equivalence and the git-enrichment pass depend on. Motivation is the wholesale replacement path: a routes change replaces every `ROUTE_CONSUMER_EXTRACTORS` type, ~1,707 units / ~24% of the index on a production-shaped host, almost all re-serializing to identical bytes; the avoided cost is `AtomicFile.write`'s fsync, and the comparison read is cheaper than the write it replaces. Compared as **bytes** (`.b`), since the encoding a read comes back tagged with depends on the process's default external encoding. The benefit is not measurable on any host in CI — see woods-testbed#2.
- `PipelineLock#touch` verifies the **token**, not just `locked?`. `locked?` is `@held && File.exist?`, which stays true after a contender has retired you and put its own lock at the same path — so a retired holder refreshed the *successor's* mtime, and if that successor crashed its lock never aged out while the retired process lived, blocking every writer until it exited. Being retired mid-run is precisely the state a heartbeat lands in when it fails, so this is the one caller that had to get it right. `touch` clears `@held` on mismatch: continuing to believe you hold it would let `release` act on someone else's lock. Ownership is **three-state** (`lock_ownership` → `:ours`/`:foreign`/`:unknown`), not boolean, and the distinction is load-bearing: `:unknown` (a torn write) refuses the refresh but must **not** disown, because `release` opens with `return unless @held` — so clearing it strands an unreadable-but-ours lock on disk and blocks every writer for the full stale window. Only a *proven* mismatch justifies disowning. Collapsing the two is how the first version of this fix introduced a leak while removing a different one.
- The rake writers keep their lock fresh via `Coordination::LockHeartbeat`, not an inline loop. The daemon refreshes at cycle boundaries; `woods:extract`/`incremental`/`refresh` have no boundary (one opaque block), so they need a thread. It paces off `lock.stale_timeout` rather than `Daemon::LOCK_STALE_TIMEOUT` — those agree today only because `woods_with_extraction_lock` builds the lock with that constant, and a lock built with any other timeout would get a silently mis-paced heartbeat. Timing is `CLOCK_MONOTONIC`, not a count of wakeups: across a laptop suspend a counter still believes it has time left while the lock ages past the window. The thread swallows its own errors — `join` re-raises, and that `join` is in an `ensure`, so a raising heartbeat would otherwise replace the caller's real error exactly when it matters most.
- A dump is a whole-store snapshot, so `Indexer#process_units` skips `persist_snapshot` when an **incremental** run processed nothing (`snapshot_worth_writing?`). Writing one anyway fsyncs every vector for byte-identical content *and* rotates the retention window — three no-op `woods:embed_incremental` runs evicted every genuinely older dump in favour of copies of the same state. Safe because `prune_superseded_vectors` is reachable only from `store_vectors`, so no store mutation happens with zero processed, and a checkpoint self-heal counts as processed. **Known cost (B-069 / #171):** it also suppresses the *metadata* dump, and `persist_unit_metadata` covers every unit — so a deleted unit's `metadata.msgpack` entry survives a no-op run and its stale vector goes from inert to retrievable by `codebase_retrieve`. Full runs always dump: there "nothing processed" means the store is genuinely empty and the dump must say so rather than leave a stale one promoted.
- `Generation` is bumped **last** and **only on success** — a reader that sees generation N knows N's files are on disk, and a failed run leaves the number where it was. Never bump before writing, and never bump on a no-op run.
- `ReloadPolicy` classifies a changed path as `:ignore`/`:reextract`/`:reload`/`:restart` for a resident process. `Watch::Daemon` consumes it every cycle — `classify_all` decides the cycle and `paths_requiring(:restart)` names the triggers in the restart message. Keep it in agreement with `PathDispatcher`: `spec/reload_policy_spec.rb` synthesizes a sample path from every `file_rules`/`whole_app_rules` entry and fails if any is classified `:ignore`, so a new dispatch rule is covered without editing the spec.
- Adding a file-based extractor means adding a `PathDispatcher` rule, or new files of that type will never enter the index incrementally. `spec/path_dispatcher_spec.rb` fails if a `FILE_BASED` type has no rule. Rules reference each extractor's own `*_DIRECTORIES` constant, so a new directory flows through without a second edit.
- Class-based types reconcile in **both** directions. Additions come from `discoverable_classes` minus the graph; removals from the graph minus `discoverable_classes`, gated on `@eager_load_complete`. The gate is the whole safety argument: on the NameError fallback the discovery sets are known-partial, so the difference would be most of the app. Removal is needed because file-based pruning cannot see a class deleted from a file that still exists — and class-based units register a *convention* path from the constant name, so a second model in one `.rb` was never attributed to that file to begin with. The booted harness can't catch this (Zeitwerk unloads only a file's expected constant, so the side-effect class survives the reload and the in-process full extraction emits it too) — the coverage is `spec/extractor_spec.rb`.
- Deletion is driven by the source file being gone. Paths named in the change set are authoritative for any unit type; the safety-net sweep over registered paths is bounded twice — to paths a file rule claims (some units name a *nominal* path: `BehavioralProfile` names `config/application.rb`), and away from class-based units entirely (they fall back to a convention path that need not exist — on Rails < 7.1 `ActiveRecord::SchemaMigration` is a real AR descendant whose `app/models/active_record/schema_migration.rb` the PORO rule *does* claim). Sweeping either would delete units a full extraction still produces.
- Token estimates must measure `JSON.generate`, not `Hash#to_json`. With ActiveSupport loaded the latter HTML-escapes `>` to `\u003e`, and the unit file is written with `JSON.generate` — so estimating with `to_json` describes a document that was never written. `ExtractedUnit#estimated_tokens` and `Extractor#estimated_tokens_from` must stay on the same serializer or full and incremental runs disagree on `_index.json`.
- Session tracer requires explicit store configuration (`session_store`) — no default store is provided. Set `session_tracer_enabled = true` and assign a store (FileStore, RedisStore, or SolidCacheStore) in the configure block.
- Session tracer middleware position matters — it must be inserted after the session middleware but before the router. The railtie handles this via `app.middleware.use`.
- `RedisStore` raises `SessionTracerError` if the `redis` gem is not available at initialization time.
- `RakeTaskExtractor` reads `.rake` files statically (no Rails boot required for parsing). It uses `block_opener?` for depth tracking — `if`/`unless` only match at line start to avoid counting trailing modifiers as blocks.
- Temporal snapshots are gated by `enable_snapshots` config (default: false). `SnapshotStore` requires migrations 004 + 005 to be run first.
- `StateMachineExtractor` and `FactoryExtractor` return arrays from their file methods (like `ScheduledJobExtractor`) — can't be registered in the FILE_BASED dispatch map. They are refreshed wholesale instead (see `WHOLE_APP_EXTRACTORS`).
- `EventExtractor` uses a two-pass approach (collect publishes, then subscribes, then merge) — no single-file extraction method exists. Like routes, it is refreshed by a wholesale re-run, triggered by any `.rb` change under `app/`.
- `DatabaseViewExtractor` only extracts the latest version of each Scenic view (highest `_vNN` suffix). Older versions are skipped — which is why it is dispatched **wholesale**, not per file: pointing the per-file method at `db/views/foo_v01.sql` would index a version a full extraction drops.
- `DecoratorExtractor` scans `app/decorators/`, `app/presenters/`, and `app/form_objects/` — these directories are also added to `EXTRACTION_DIRECTORIES` for eager loading.
- `CachingExtractor` scans controllers, models, and view templates (`.erb`) — the `file_type` parameter on `extract_caching_file` defaults to nil (auto-detected from path).
- `TestMappingExtractor` scans `spec/` and `test/` directories — these are outside `app/` so they don't need eager loading. Test files are read statically.
- Notion export requires `notion_api_token` and `notion_database_ids` to be configured. If only one database ID is set, the other sync (columns or data_models) is skipped gracefully. Environment variable `NOTION_API_TOKEN` overrides config. The Notion API enforces 3 req/sec — `RateLimiter` handles this automatically.
- Obsidian export (`woods:obsidian`, `lib/woods/obsidian/`) writes a local vault — no API/token/Configuration accessors (path + flags are constructor kwargs, exposed via `WOODS_OBSIDIAN_*` env). It reads `raw_graph_data` (string keys + **persisted** pagerank — never `reader.dependency_graph`, which drops pagerank and symbolizes types). All edges derive from the graph's `edges`/`reverse`; per-unit JSON is read only for note bodies. Frontmatter is **flat-scalars-only** (Obsidian's Properties UI corrupts nested objects) emitted via Psych; structured edges live in the `_woods/` sidecar. The stale-note sweep and `.obsidian/` config writes are both gated behind a `.woods-vault` ownership sentinel + a 30% purge guard (mirrors Unblocked). `include_framework` covers `rails_source` only (`gem_source` is unreachable via `IndexReader::TYPE_DIRS`). See `docs/OBSIDIAN_INTEGRATION.md`.
- Navigation edge extraction (`link_to`, `redirect_to`, `form_action`) is gated by `extract_navigation_edges` config (default: true). Extractors that scan for navigation edges must include both `SharedDependencyScanner` and `RouteHelperResolver`, and call `build_route_helper_map` in their initializer.
- `RouteHelperResolver` uses `IGNORED_HELPER_PREFIXES` to filter false positives from non-route `_path`/`_url` suffixes (e.g., `file_path`, `base_url`, `log_path`). Add new prefixes there when false positives are discovered in host apps.
- `DependencyGraph` edges are stored as `[{ target:, via: }]` hashes (symbol keys). `IndexReader` normalizes from JSON to `[{ 'target' => ..., 'via' => ... }]` (string keys). The two normalizers (`DependencyGraph.normalize_edges` vs `IndexReader.normalize_all_edges`) are intentionally separate — do not merge them.
- `DependencyGraph.from_h` handles both old-format (bare string) and new-format (hash) edges via `normalize_edges`. Old serialized graphs load without migration.
- `dependencies_of` and `dependents_of` accept an optional `via:` filter (Symbol or Array<Symbol>). The MCP `dependencies`/`dependents` tools expose this as a `via` array parameter.
- `DependencyGraph`'s `file_map` is `path => Set<identifier>` — one file can define several units. Graphs persisted before this stored a bare string and load through `normalize_file_map` without conversion. `#unregister` strips a registration's side effects so the identifier can be re-registered; `#remove` is the deletion path and drops the node and its edges too. `#node` exists so callers don't rebuild the memoized `to_h` inside a loop.
- `GraphAnalyzer` output is a pure function of graph content: `orphans`/`dead_ends` sort, `hubs` tie-breaks on identifier and sorts its `dependents`, `cycles` starts its DFS from a sorted node list, `bridges` samples from one. Don't reintroduce insertion-order dependence — two extractions of the same tree must publish the same analysis. The guard is `spec/graph_analyzer_spec.rb`'s registration-order rotation, **not** the differential harness: the harness's oracle used to `deep_sort` `graph_analysis.json` before comparing, which made the only test that could see order dependence blind to it. It now compares exactly.
- `GraphQLExtractor` file discovery is **not** gated on graphql-ruby being loaded (`graphql_source_present?`, not the old `graphql_available?`). The `PathDispatcher` rule for `app/graphql/**` reaches `extract_graphql_file`, which is a regex plus a `safe_constantize` allowed to fail — so gating the full pass on the gem meant an app whose gem was not loaded at extraction time got its types indexed incrementally and dropped by a full run. Runtime introspection is additive: it enriches units when the gem is present, it does not decide whether they exist. graphql-ruby is deliberately absent from the gemspec *and* the version gemfiles; the harness templates (types/mutations/resolvers) need no gem. The runtime pass can emit units no file pass reproduces (dynamically defined types, schema-builder types), so GraphQL is registered in `CLASS_BASED_DISCOVERY` with `reconcile_removals: false` — the only entry that opts out (#167). It opts out because its unit type is the **union** of two independent discovery mechanisms, runtime introspection and the static file pass, so "in the graph but not in `discoverable_classes`" does not mean deleted: without the gem the runtime set is empty and removal would wipe every GraphQL unit, and with it loaded a file-defined type not attached to the schema is legitimately absent from the type map. Additions are safe in both worlds and are exactly the runtime-only types no changed path can reach. Two mechanisms originally undid the whole thing and both are now guarded: the discovery entry must name **every** type the extractor emits (`types: GRAPHQL_TYPES` — `classify_runtime_type` returns four, and the schema's query root is always `:graphql_query`), or the unnamed ones are permanently "new", get re-added every run, and leave `touched` non-empty on a no-op so the generation bumps each cycle; and the prune sweep skips GraphQL via `convention_path_unit?` — which keys on unit *type* while the property is per-unit, so file-defined GraphQL units left the unnamed-path sweep too (B-070 / #171; the daemon's empty-change-set catch-up is the exposed caller), because `source_file_for_class` falls back to an `app/graphql/...` path a runtime-defined type does not have, so the sweep deleted those units in the same run that added them. Two consequences worth knowing: a runtime-only type that *disappears* is never removed by an incremental run (it survives until a full extraction rebuilds the type — a stale unit is recoverable, whereas removal would delete units a full extraction still emits), and graphql-ruby's own builtins can never enter the graph, so reconciliation re-attempts them every run as silent nils. **The `method:` named in `CLASS_BASED_DISCOVERY` must be public** — `add_discovered_classes` uses `public_send`, and a private method raises `NoMethodError` that the surrounding `rescue StandardError` turns into a warn and a dropped nil, so the entry silently contributes nothing. #167 shipped inert that way. `spec/extractor_spec.rb` now checks visibility statically for every entry; the symbol-matching spec and the double-injecting reconcile specs both miss it, since a double answers `public_send` regardless of the real class's visibility.
- `DependencyGraph` holds **absolute** paths in memory and persists **relative** ones (#166). In-memory absolute is load-bearing: `re_extract_unit` and `incremental_git_data` gate on `File.exist?`, and `ChangeSet` hands `affected_by`/`identifiers_for_path` absolute paths. Persisting absolute made the artifact non-portable — extraction in a container writes `/app/...` while a host reading the volume mount sees a different prefix, so a host-run `woods:incremental` computed an empty blast radius and silently re-extracted nothing. `to_h` relativizes, `from_h` absolutizes against `Rails.root`; outside a Rails process (a host-side reader) the root is unknown and paths pass through, which is harmless because **nothing on the read side reads a graph node's `file_path`** — MCP, Obsidian, Unblocked and the formatters all read the per-unit JSON, which was always relative. Absolutizing is idempotent, so a pre-#166 graph loads without a re-index; it is *not* re-pointable at a different root though (there is no way to know which prefix was the old machine's root) and becomes portable only when a full extraction rewrites it. Do **not** add a `root:` kwarg to `from_h`: callers pass a bare hash literal, which Ruby binds as keywords the moment the method accepts any, so `data` arrives empty. The one consumer of the persisted `file_map` — `Watch::Daemon#persisted_registered_paths` — absolutizes explicitly, because its `start_with?(root_prefix)` guard would otherwise exclude every relative entry and silently disable deletion reconciliation.
- **Known, pre-existing:** the graph keys nodes on the bare identifier, so two units of *different types* sharing an identifier (a Scenic view `reports` and a factory `reports`) collapse onto one node, last registration winning. `deduplicate_results` only dedupes within a type. Surfaced by the #164 harness; not fixed there.
