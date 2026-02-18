# CodebaseIndex

Ruby gem that extracts structured data from Rails applications for AI-assisted development. Uses runtime introspection (not static parsing) to produce version-accurate representations: inlined concerns, resolved callback chains, schema-aware associations, dependency graphs. All major layers are complete: extraction (13 extractors), retrieval (query classification, hybrid search, RRF ranking), storage (pgvector, Qdrant, SQLite adapters), embedding (OpenAI, Ollama), two MCP servers (21-tool index server + 31-tool console server), AST analysis, flow extraction, and evaluation harness.

## Commands

```bash
# Development
bundle install
bundle exec rake spec                            # Full test suite
bundle exec rake spec SPEC=spec/extractors/model_extractor_spec.rb  # Single file
bundle exec rubocop -a                            # Lint + autofix
bundle exec rubocop --auto-gen-config             # Update .rubocop_todo.yml

# In a host Rails app (extraction requires Rails boot)
bundle exec rake codebase_index:extract           # Full extraction
bundle exec rake codebase_index:incremental       # Changed files only
bundle exec rake codebase_index:extract_framework # Rails/gem sources
bundle exec rake codebase_index:validate          # Index integrity check
bundle exec rake codebase_index:stats             # Show extraction stats
bundle exec rake codebase_index:clean             # Remove index output
```

## Architecture

```
lib/
├── codebase_index.rb                    # Module interface, Configuration, entry point
├── codebase_index/
│   ├── extractor.rb                     # Orchestrator — coordinates all extractors
│   ├── extracted_unit.rb                # Core value object
│   ├── dependency_graph.rb              # Directed graph + PageRank scoring
│   ├── graph_analyzer.rb               # Structural analysis (orphans, hubs, cycles, bridges)
│   ├── model_name_cache.rb             # Precomputed regex for dependency scanning
│   ├── retriever.rb                     # Retriever orchestrator with degradation tiers
│   ├── extractors/                      # 13 extractors (one per Rails concept)
│   ├── ast/                             # Prism-based AST layer
│   ├── ruby_analyzer/                   # Static analysis (class, method, dataflow)
│   ├── flow_analysis/                   # Execution flow tracing
│   ├── chunking/                        # Semantic chunking (Chunk, SemanticChunker)
│   ├── embedding/                       # Embedding pipeline (OpenAI, Ollama, Indexer)
│   ├── storage/                         # Storage backends (VectorStore, MetadataStore, GraphStore, Pgvector, Qdrant)
│   ├── retrieval/                       # Retrieval pipeline (QueryClassifier, SearchExecutor, Ranker, ContextAssembler)
│   ├── formatting/                      # LLM context formatting (Claude, GPT, Generic, Human)
│   ├── mcp/                             # MCP Index Server (21 tools, 2 resources, 2 templates)
│   ├── console/                         # Console MCP Server (31 tools, 4 tiers, job/cache adapters)
│   ├── coordination/                    # Multi-agent pipeline locking
│   ├── feedback/                        # Agent self-service (FeedbackStore, GapDetector)
│   ├── operator/                        # Pipeline management (StatusReporter, ErrorEscalator, PipelineGuard)
│   ├── observability/                   # Instrumentation, StructuredLogger, HealthCheck
│   ├── resilience/                      # CircuitBreaker, RetryableProvider, IndexValidator
│   ├── db/                              # Schema management (migrations, Migrator, SchemaVersion)
│   └── evaluation/                      # Retrieval evaluation (Metrics, Evaluator, BaselineRunner)
├── generators/codebase_index/           # Rails generators (install, pgvector)
├── tasks/
│   └── codebase_index.rake              # Rake task definitions
exe/
├── codebase-index-mcp                   # MCP Index Server executable
└── codebase-console-mcp                 # Console MCP Server executable
```

## Key Design Decisions

- **Runtime introspection over static parsing.** Extractors require a booted Rails environment. This is intentional — `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs give us data that no parser can.
- **Backend agnostic.** The gem must work equally well with MySQL or PostgreSQL, Qdrant or pgvector, Sidekiq or Solid Queue, OpenAI or Ollama. Never hardcode or default to a single backend. See `docs/BACKEND_MATRIX.md`.
- **ExtractedUnit is the universal currency.** Everything flows through `ExtractedUnit` — extractors produce them, the dependency graph connects them, the indexing pipeline consumes them. Don't bypass this abstraction.
- **Concerns get inlined.** When extracting a model, all `include`d concerns are resolved and their source is inlined into the unit's source_code. This is the key differentiator from file-level tools.
- **Dependency graph is bidirectional.** First pass: each extractor records forward dependencies. Second pass: the graph resolves reverse edges (dependents). Both directions matter for retrieval.
- **PageRank for importance scoring.** `DependencyGraph` computes PageRank over the unit graph to surface high-importance nodes for retrieval ranking. `GraphAnalyzer` provides structural analysis — orphans, dead ends, hubs, cycles, and bridges — for codebase health insights.

## Code Conventions

- `frozen_string_literal: true` on every file
- YARD documentation on every public method and class
- Extractors follow a consistent interface: `initialize`, `extract_all`, `extract_<type>_file(path)`
- All extractors return `Array<ExtractedUnit>`
- Use `Rails.root.join()` for paths, never string concatenation
- JSON output uses string keys, snake_case
- Token estimation: `(string.length / 3.5).ceil` — Ruby code averages ~3.2-3.5 chars/token (symbols, do/end, underscored_names). Uses 3.5 as a compromise.
- Error handling: raise `CodebaseIndex::ExtractionError` for recoverable extraction failures, let unexpected errors propagate. Always `rescue StandardError`, never bare `rescue`.

## Testing

**Two test suites** — the gem has unit specs with mocks, and a separate Rails app has integration specs that run real extractions.

- **Gem unit specs** (`spec/`): RSpec with `rubocop-rspec` enforcement. Tests core value objects, graph analysis, ModelNameCache, json_serialize, and extractor orchestration using mocks/stubs. No Rails boot required.
- **Integration specs** (`~/work/host-app/spec/integration/`): A minimal Rails 8.1 app with Post, Comment models, controllers, jobs, and a mailer. Tests run real extractions and verify output structure, dependencies, incremental extraction, git metadata, and configuration behavior. Requires `cd ~/work/host-app && bundle exec rspec`.
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

## Planning Documents

The `docs/` directory contains design documents for all major layers — all now complete. Read `docs/README.md` for the index, reading order, and status table. These documents remain the source of truth for architectural decisions and backend selection. When modifying existing subsystems, read the relevant doc first — don't introduce patterns that conflict with the established design.

Key references by topic:
- Backend selection → `docs/BACKEND_MATRIX.md`
- Retrieval pipeline → `docs/RETRIEVAL_ARCHITECTURE.md`
- Chunking and LLM context formatting → `docs/CONTEXT_AND_CHUNKING.md`
- Schema management, error handling, observability → `docs/OPERATIONS.md`
- Agent/MCP integration → `docs/AGENTIC_STRATEGY.md`
- Cost analysis → `docs/BACKEND_MATRIX.md` (bottom section)
- Optimization backlog → `docs/OPTIMIZATION_BACKLOG.md` — prioritized list of performance, correctness, and coverage improvements. Check resolved status before starting work on an item.

## Backlog Workflow

See `.claude/skills/backlog-workflow/SKILL.md` for the full workflow: picking items, implementing with TDD, marking resolved, and adding new work.

## Session Continuity

At the end of a session, update `.claude/context/session-state.md` with breadcrumbs:

- Which backlog items were touched (resolved or in-progress)
- Which files were modified
- Any gotchas discovered during the session

At the start of a session, read `.claude/context/session-state.md` for context from the previous session.

## Gotchas

- Extraction **must** run inside a Rails app — the gem has no standalone extraction mode. All extractors assume `Rails`, `ActiveRecord::Base`, etc. are defined.
- `rails_source_extractor.rb` reads source from installed gem paths (`Gem.loaded_specs`). This is read-only and path-sensitive — don't assume gem install locations.
- Service discovery scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. If a host app uses a non-standard directory, it won't be found without configuration.
- The dependency graph can have cycles (A depends on B depends on A). Graph traversal must handle this — see `DependencyGraph#visited` tracking.
- MySQL and PostgreSQL have different JSON querying, indexing, and CTE syntax. Any database-touching code must handle both. Never write PostgreSQL-only SQL and assume it works.
- `eager_load!` is called once in the orchestrator (`Extractor`), not in individual extractors. Don't add `Rails.application.eager_load!` calls to extractors.
- Git commands use `Open3.capture2` (not backticks) to prevent shell injection. Never use backtick-style command execution for external processes.
- `callback.options` doesn't exist on modern Rails (removed in 4.2) — use `@if`/`@unless` ivars + ActionFilter duck-typing (check for `@actions` ivar as a `Set`) to extract `:only`/`:except` action lists from callbacks.
- `eager_load!` aborts completely on a single `NameError` (e.g., `app/graphql/` referencing an uninstalled gem). Zeitwerk processes dirs alphabetically, so a failure in `graphql/` prevents `models/` from loading. The gem falls back to per-directory loading via `EXTRACTION_DIRECTORIES` when this happens.
- `CallbackChain#size` does not exist on any Rails version (7.0–8.1) — `CallbackChain` includes `Enumerable` but never defines `#size`. Use `#count` instead.
- `git_available?` is memoized — won't detect git becoming available mid-extraction (acceptable tradeoff).
- Model name scanning uses a precomputed regex via `ModelNameCache` — invalidated per extraction run, not per unit.
- `extract_dependencies` in all extractors must include `:via` key — see model_extractor for reference values.
- MCP server tool dispatch uses `Mutex` for thread safety — don't call tool handlers from multiple threads without going through the server's dispatch.
- Console bridge requires a booted Rails environment on the other end — it validates models against `ActiveRecord::Base.descendants` at startup.
- Console `SafeContext` wraps every request in a rolled-back transaction. Writes are silently discarded. This is intentional defense-in-depth, not a bug.
- `SqlValidator` rejects DML/DDL at the string level before any database interaction. Don't bypass it for "convenience."
- `CircuitBreaker` state is per-instance, not global. Each provider/store gets its own breaker. Don't share breaker instances across unrelated components.
- Embedding dimensions must match between provider and vector store. A mismatch (e.g., switching models) requires full re-index — `IndexValidator` detects this.
- `PipelineGuard` enforces a 5-minute cooldown on full extraction/embedding runs. Incremental runs are not rate-limited.
