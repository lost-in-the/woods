# CodebaseIndex

Ruby gem that extracts structured data from Rails applications for AI-assisted development. Uses runtime introspection (not static parsing) to produce version-accurate representations: inlined concerns, resolved callback chains, schema-aware associations, dependency graphs. The extraction layer is complete. Retrieval, embedding, and storage layers are in design — see `docs/` for planning.

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
├── codebase_index.rb              # Module interface, Configuration class, entry point
├── codebase_index/
│   ├── extractor.rb               # Orchestrator — coordinates all extractors, builds graph
│   ├── extracted_unit.rb          # Value object — single code unit (model/controller/service/etc)
│   ├── dependency_graph.rb        # Directed graph of unit relationships + PageRank scoring
│   ├── graph_analyzer.rb          # Structural analysis — orphans, dead ends, hubs, cycles, bridges
│   └── extractors/                # One extractor per Rails concept
│       ├── model_extractor.rb     # ActiveRecord models — inlines concerns, resolves schema
│       ├── controller_extractor.rb # Controllers — maps routes, resolves filter chains
│       ├── service_extractor.rb   # Service objects — scans conventional directories
│       ├── job_extractor.rb       # ActiveJob/Sidekiq workers
│       ├── mailer_extractor.rb    # ActionMailer classes
│       ├── phlex_extractor.rb     # Phlex view components
│       ├── graphql_extractor.rb   # GraphQL types, mutations, queries, subscriptions
│       └── rails_source_extractor.rb # Framework source from installed gems
├── tasks/
│   └── codebase_index.rake        # Rake task definitions
docs/                              # Planning & design documents (see docs/README.md)
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

## Planning Documents

The `docs/` directory contains the full design for unbuilt layers. Read `docs/README.md` for the index and reading order. These documents are the source of truth for architectural decisions, backend selection, and implementation sequencing. When implementing retrieval or storage features, read the relevant doc first — don't invent patterns that conflict with the established design.

Key references by topic:
- Backend selection → `docs/BACKEND_MATRIX.md`
- Retrieval pipeline → `docs/RETRIEVAL_ARCHITECTURE.md`
- Chunking and LLM context formatting → `docs/CONTEXT_AND_CHUNKING.md`
- Schema management, error handling, observability → `docs/OPERATIONS.md`
- Agent/MCP integration → `docs/AGENTIC_STRATEGY.md`
- Cost analysis → `docs/BACKEND_MATRIX.md` (bottom section)
- Optimization backlog → `docs/OPTIMIZATION_BACKLOG.md` — prioritized list of performance, correctness, and coverage improvements. Check resolved status before starting work on an item.

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
