# CodebaseIndex

A Rails codebase extraction and indexing system designed to provide accurate, version-specific context for AI-assisted development tooling.

## The Problem

LLMs working with Rails codebases face a fundamental accuracy gap. Training data contains documentation and examples from many Rails versions, but a production app runs on *one* version. When a developer asks "what options does `has_many` support?" or "what callbacks fire when a record is saved?", the answer depends on their exact Rails version — and generic LLM responses often get it wrong.

Beyond version accuracy, Rails conventions hide enormous amounts of implementation behind "magic." A model file might be 50 lines, but with concerns inlined, schema context, callbacks, validations, and association behavior, the *actual* surface area is 10x that. AI tools that only see the source file miss most of what matters.

CodebaseIndex solves this by:

- **Running inside Rails** to leverage runtime introspection (not just static parsing)
- **Inlining concerns** directly into model source so the full picture is visible
- **Prepending schema comments** with column types, indexes, and foreign keys
- **Mapping routes to controllers** so HTTP → action flow is explicit
- **Indexing the exact Rails/gem source** for the versions in `Gemfile.lock`
- **Tracking dependencies** bidirectionally so you can trace impact across the codebase
- **Enriching with git data** so you know what's actively changing vs. dormant

## Installation

Add to your Gemfile:

```ruby
gem 'codebase_index'
```

Then:

```bash
bundle install
```

Or install directly:

```bash
gem install codebase_index
```

## Target Environment

Designed for Rails applications of any scale, with particular strength in large monoliths:

- Any database (MySQL, PostgreSQL, SQLite)
- Any background job system (Sidekiq, Solid Queue, GoodJob, inline)
- Any view layer (ERB, Phlex, ViewComponent)
- Docker or bare metal, CI or manual
- Continuous or one-shot indexing

See [docs/BACKEND_MATRIX.md](docs/BACKEND_MATRIX.md) for supported infrastructure combinations.

## Use Cases

**1. Coding & Debugging** — Primary context for AI coding assistants. Answer "how does our checkout flow work?" with the actual service, model callbacks, controller actions, and framework behavior for the running version.

**2. Performance Analysis** — Correlate code structure with runtime behavior. Identify models with high write volume and complex callback chains, find N+1-prone association patterns, surface hot code paths.

**3. Deeper Analytics** — Query frequency by scope, error rates by action, background job characteristics. Bridge the gap between code structure and operational data.

**4. Support & Marketing Tooling** — Domain-concept retrieval for non-developers. Map business terms to code paths, surface feature flags, document user-facing behavior.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CodebaseIndex                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Extraction    │───▶│     Storage     │◀───│    Retrieval    │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘ │
│          │                      │                      │           │
│          ▼                      ▼                      ▼           │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Extractors    │    │  JSON per unit  │    │ Query Classifier│ │
│  │  · Model        │    │  Vector Index   │    │ Context Assembly│ │
│  │  · Controller   │    │  Metadata Index │    │ Result Ranking  │ │
│  │  · Service      │    │  Dep Graph      │    │                 │ │
│  │  · Component    │    │                 │    │                 │ │
│  │  · Rails Source │    │                 │    │                 │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Extraction Pipeline

Extraction runs inside the Rails application (via rake task) to access runtime introspection — `ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs, etc. This is fundamentally more accurate than static parsing.

**Four phases:**

1. **Extract** — Each extractor produces `ExtractedUnit` objects with source, metadata, and dependencies
2. **Resolve dependents** — Build reverse dependency edges (who calls what)
3. **Enrich with git** — Last modified, contributors, change frequency, recent commits
4. **Write output** — JSON per unit, dependency graph, manifest, structural summary

### Extractors

| Extractor | What it captures |
|-----------|-----------------|
| **ModelExtractor** | Schema (columns, indexes, FKs), associations with options, validations, callbacks (all 13 types), scopes, enums, inlined concerns. Chunks large models into summary/associations/callbacks/validations. |
| **ControllerExtractor** | Route mapping (verb → path → action), filter chain resolution per action, response formats, permitted params. Creates per-action chunks with applicable filters and route context. |
| **ServiceExtractor** | Scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. Extracts entry points (call/perform/execute), dependency injection patterns, custom errors, return type inference. |
| **JobExtractor** | ActiveJob and Sidekiq workers from `app/jobs` and `app/workers`. Queue configuration, retry/concurrency options, perform arguments, callbacks. Critical for understanding async behavior. |
| **MailerExtractor** | ActionMailer classes with default settings, per-action templates, callbacks, helper usage. Creates per-action chunks with template associations. |
| **PhlexExtractor** | Phlex component slots, initialize params, rendered sub-components, model dependencies, Stimulus controller references, route helpers. |
| **ViewComponentExtractor** | ViewComponent slots, template paths, preview classes, collection support. |
| **GraphQLExtractor** | Object types, input types, enums, unions, interfaces, mutations, resolvers, field metadata, authorization patterns. |
| **SerializerExtractor** | ActiveModelSerializers, Blueprinter, Alba, and Draper. Auto-detects loaded gems and extracts accordingly. |
| **ManagerExtractor** | SimpleDelegator subclasses in `app/managers/`. Wrapped model, public methods, delegation chain. |
| **PolicyExtractor** | Domain policy classes in `app/policies/`. Policy names, evaluated models, decision methods. |
| **ValidatorExtractor** | Custom validator classes in `app/validators/`. Validator names, operated models, validation rules. |
| **RailsSourceExtractor** | High-value Rails framework paths (associations, callbacks, validations, relations) and gem source (Devise, Pundit, Sidekiq, etc.) pinned to exact installed versions. Rates importance for retrieval ranking. |

### Key Design Decisions

**Concern inlining.** When extracting a model, included concerns are read from disk and embedded as formatted comments directly in the model's source. This means the full behavioral picture is in one unit — no separate lookups needed during retrieval.

**Route prepending.** Controller source gets a header block showing the HTTP routes that map to it, so the relationship between URLs and actions is immediately visible.

**Semantic chunking.** Large models are split into purpose-specific chunks (summary, associations, callbacks, validations) rather than arbitrary size-based splits. Controllers chunk per-action with the relevant filters and route attached.

**Dependency graph with BFS blast radius.** The graph tracks both forward dependencies (what this unit uses) and reverse dependencies (what uses this unit). Changed-file impact is computed via breadth-first traversal — if a concern changes, every model including it gets re-indexed.

## Subsystems

```
lib/
├── codebase_index.rb                          # Module interface, Configuration, entry point
├── codebase_index/
│   ├── extracted_unit.rb                       # Core value object
│   ├── extractor.rb                            # Orchestrator — coordinates all extractors
│   ├── dependency_graph.rb                     # Directed graph + PageRank scoring
│   ├── graph_analyzer.rb                       # Structural analysis (orphans, hubs, cycles, bridges)
│   ├── model_name_cache.rb                     # Precomputed regex for dependency scanning
│   ├── retriever.rb                            # Retriever orchestrator with degradation tiers
│   ├── builder.rb                              # DSL builder for configuration
│   ├── version.rb                              # Gem version
│   ├── railtie.rb                              # Rails integration
│   │
│   ├── extractors/                             # 13 extractors (one per Rails concept)
│   │   ├── model_extractor.rb                  # ActiveRecord models
│   │   ├── controller_extractor.rb             # ActionController
│   │   ├── service_extractor.rb                # Service objects
│   │   ├── job_extractor.rb                    # ActiveJob/Sidekiq workers
│   │   ├── mailer_extractor.rb                 # ActionMailer
│   │   ├── phlex_extractor.rb                  # Phlex components
│   │   ├── view_component_extractor.rb         # ViewComponent
│   │   ├── graphql_extractor.rb                # GraphQL types, mutations, queries
│   │   ├── serializer_extractor.rb             # Serializers/decorators
│   │   ├── manager_extractor.rb                # SimpleDelegator managers
│   │   ├── policy_extractor.rb                 # Policy classes
│   │   ├── validator_extractor.rb              # Standalone validators
│   │   ├── rails_source_extractor.rb           # Framework/gem source
│   │   ├── shared_dependency_scanner.rb        # Shared dependency detection
│   │   ├── shared_utility_methods.rb           # Shared extractor utilities
│   │   └── ast_source_extraction.rb            # AST-based source extraction
│   │
│   ├── ast/                                    # Prism-based AST layer
│   │   ├── parser.rb                           # Source parsing adapter
│   │   ├── node.rb                             # Normalized AST node
│   │   ├── method_extractor.rb                 # Method boundary detection
│   │   └── call_site_extractor.rb              # Call site analysis
│   │
│   ├── ruby_analyzer/                          # Static analysis
│   │   ├── class_analyzer.rb                   # Class structure analysis
│   │   ├── method_analyzer.rb                  # Method complexity/dependencies
│   │   ├── dataflow_analyzer.rb                # Data flow tracing
│   │   ├── trace_enricher.rb                   # Enriches flow traces
│   │   ├── fqn_builder.rb                      # Fully-qualified name resolution
│   │   └── mermaid_renderer.rb                 # Diagram generation
│   │
│   ├── flow_analysis/                          # Execution flow tracing
│   │   ├── operation_extractor.rb              # Extract operations from AST
│   │   └── response_code_mapper.rb             # HTTP response mapping
│   ├── flow_assembler.rb                       # Assembles execution flows
│   ├── flow_document.rb                        # Flow documentation format
│   │
│   ├── chunking/                               # Semantic chunking
│   │   ├── chunk.rb                            # Chunk value object
│   │   └── semantic_chunker.rb                 # Type-aware splitting
│   │
│   ├── embedding/                              # Embedding pipeline
│   │   ├── provider.rb                         # Provider interface
│   │   ├── openai.rb                           # OpenAI adapter
│   │   ├── text_preparer.rb                    # Text preparation for embedding
│   │   └── indexer.rb                          # Batch indexing with resumability
│   │
│   ├── storage/                                # Storage backends
│   │   ├── vector_store.rb                     # Vector store interface + InMemory
│   │   ├── metadata_store.rb                   # Metadata store interface + InMemory/SQLite
│   │   ├── graph_store.rb                      # Graph store interface + InMemory
│   │   ├── pgvector.rb                         # PostgreSQL pgvector adapter
│   │   └── qdrant.rb                           # Qdrant adapter
│   │
│   ├── retrieval/                              # Retrieval pipeline
│   │   ├── query_classifier.rb                 # Intent/scope/type classification
│   │   ├── search_executor.rb                  # Multi-strategy search
│   │   ├── ranker.rb                           # RRF-based ranking
│   │   └── context_assembler.rb                # Token-budgeted context assembly
│   │
│   ├── formatting/                             # LLM context formatting
│   │   ├── base.rb                             # Base formatter
│   │   ├── claude_adapter.rb                   # Claude-optimized output
│   │   ├── gpt_adapter.rb                      # GPT-optimized output
│   │   ├── generic_adapter.rb                  # Generic LLM output
│   │   └── human_adapter.rb                    # Human-readable output
│   │
│   ├── mcp/                                    # MCP Index Server (21 tools)
│   │   ├── server.rb                           # Tool definitions + dispatch
│   │   └── index_reader.rb                     # JSON index reader
│   │
│   ├── console/                                # Console MCP Server (31 tools)
│   │   ├── server.rb                           # Console server + tool registration
│   │   ├── bridge.rb                           # JSON-lines protocol bridge
│   │   ├── safe_context.rb                     # Transaction rollback + timeout
│   │   ├── connection_manager.rb               # Docker/direct/SSH modes
│   │   ├── model_validator.rb                  # AR schema validation
│   │   ├── sql_validator.rb                    # SQL statement validation
│   │   ├── audit_logger.rb                     # JSONL audit logging
│   │   ├── confirmation.rb                     # Human-in-the-loop confirmation
│   │   ├── tools/
│   │   │   ├── tier1.rb                        # 9 safe read-only tools
│   │   │   ├── tier2.rb                        # 9 domain-aware tools
│   │   │   ├── tier3.rb                        # 10 analytics tools
│   │   │   └── tier4.rb                        # 3 guarded tools
│   │   └── adapters/
│   │       ├── sidekiq_adapter.rb              # Sidekiq job backend
│   │       ├── solid_queue_adapter.rb          # Solid Queue job backend
│   │       ├── good_job_adapter.rb             # GoodJob job backend
│   │       └── cache_adapter.rb                # Cache backend adapters
│   │
│   ├── coordination/                           # Multi-agent coordination
│   │   └── pipeline_lock.rb                    # File-based pipeline locking
│   │
│   ├── feedback/                               # Agent self-service
│   │   ├── store.rb                            # JSONL feedback storage
│   │   └── gap_detector.rb                     # Feedback-driven gap detection
│   │
│   ├── operator/                               # Pipeline management
│   │   ├── status_reporter.rb                  # Pipeline status
│   │   ├── error_escalator.rb                  # Error classification
│   │   └── pipeline_guard.rb                   # Rate limiting
│   │
│   ├── observability/                          # Instrumentation
│   │   ├── instrumentation.rb                  # ActiveSupport::Notifications
│   │   ├── structured_logger.rb                # JSON structured logging
│   │   └── health_check.rb                     # Component health checks
│   │
│   ├── resilience/                             # Fault tolerance
│   │   ├── circuit_breaker.rb                  # Circuit breaker pattern
│   │   ├── retryable_provider.rb               # Retry with backoff
│   │   └── index_validator.rb                  # Index integrity validation
│   │
│   ├── db/                                     # Schema management
│   │   ├── schema_version.rb                   # Version tracking
│   │   ├── migrator.rb                         # Standalone migration runner
│   │   └── migrations/
│   │       ├── 001_create_units.rb
│   │       ├── 002_create_edges.rb
│   │       └── 003_create_embeddings.rb
│   │
│   └── evaluation/                             # Retrieval evaluation
│       ├── query_set.rb                        # Evaluation query loading
│       ├── metrics.rb                          # Precision@k, Recall, MRR
│       ├── evaluator.rb                        # Query evaluation
│       ├── baseline_runner.rb                  # Grep/random/file baselines
│       └── report_generator.rb                 # JSON report generation
│
├── generators/codebase_index/                  # Rails generators
│   ├── install_generator.rb                    # Initial setup
│   └── pgvector_generator.rb                   # pgvector migration
│
├── tasks/
│   └── codebase_index.rake                     # Rake task definitions
│
exe/
├── codebase-index-mcp                          # MCP Index Server executable
└── codebase-console-mcp                        # Console MCP Server executable
```

## Context Assembly

When serving context to an LLM, token budget is allocated in layers:

```
Budget Allocation:
├── 10%  Structural overview (always included)
├── 50%  Primary relevant units
├── 25%  Supporting context (dependencies)
└── 15%  Framework reference (when needed)
```

Queries are classified to determine whether framework source context is needed. "What options does has_many support?" routes to Rails source; "how do we handle checkout?" routes to application code.

## Usage

### Full Extraction

```bash
bundle exec rake codebase_index:extract
```

### Incremental (CI)

```bash
# Auto-detects GitHub Actions / GitLab CI environment
bundle exec rake codebase_index:incremental
```

```yaml
# .github/workflows/index.yml
jobs:
  index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - name: Update index
        run: bundle exec rake codebase_index:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

### Framework-Only (on dependency changes)

```bash
bundle exec rake codebase_index:extract_framework
```

### Other Tasks

```bash
rake codebase_index:validate  # Check index integrity
rake codebase_index:stats     # Show unit counts, sizes, graph stats
rake codebase_index:clean     # Remove index
```

### Ruby API

```ruby
# Full extraction
CodebaseIndex.extract!

# Incremental
CodebaseIndex.extract_changed!(["app/models/user.rb", "app/services/checkout.rb"])

# Configuration
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join("tmp/codebase_index")
  config.max_context_tokens = 8000
  config.include_framework_sources = true
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
end
```

## Output Structure

```
tmp/codebase_index/
├── manifest.json              # Extraction metadata, git SHA, checksums
├── dependency_graph.json      # Full graph with forward/reverse edges
├── SUMMARY.md                 # Human-readable structural overview
├── models/
│   ├── _index.json            # Quick lookup index
│   ├── User.json              # Full extracted unit
│   └── Order.json
├── controllers/
│   ├── _index.json
│   └── OrdersController.json
├── services/
│   ├── _index.json
│   └── CheckoutService.json
├── components/
│   └── ...
└── rails_source/
    └── ...
```

Each unit JSON contains: `identifier`, `type`, `file_path`, `source_code` (annotated), `metadata` (rich structured data), `dependencies`, `dependents`, `chunks` (if applicable), and `estimated_tokens`.

## Development

After checking out the repo:

```bash
bin/setup          # Install dependencies
bin/console        # Interactive prompt
bundle exec rake spec      # Run tests
bundle exec rubocop        # Lint
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/LeahArmstrong/codebase_index. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
