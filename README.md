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

See [Why CodebaseIndex?](docs/WHY_CODEBASE_INDEX.md) for concrete before/after examples.

## Quick Start

```bash
# Add to your Rails app's Gemfile, then:
bundle install
rails generate codebase_index:install
bundle exec rake codebase_index:extract
bundle exec rake codebase_index:stats
# Add the MCP server to .mcp.json (see below) and start asking questions
```

See [Getting Started](docs/GETTING_STARTED.md) for the full walkthrough including Docker, storage presets, and CI setup.

## Installation

Add to your Gemfile:

```ruby
gem 'codebase_index'
```

Then:

```bash
bundle install
rails generate codebase_index:install
rails db:migrate
```

Create a minimal configuration:

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
end
```

Or install the gem directly:

```bash
gem install codebase_index
```

> **Requires Rails.** Extraction runs inside a booted Rails application using runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, etc.). The gem cannot extract from source files alone. See [Getting Started](docs/GETTING_STARTED.md) for full setup details.

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

### Extractors (34)

34 extractors cover every major Rails concept: models (with inlined concerns and schema), controllers (with route context), services, jobs, mailers, GraphQL types/mutations/resolvers, serializers, view components (Phlex and ViewComponent), ERB templates, decorators, concerns, validators, policies, routes, middleware, engines, i18n, Action Cable, rake tasks, migrations, database views, state machines, events, caching patterns, factories, test mappings, and Rails framework source pinned to exact installed versions.

See [docs/EXTRACTOR_REFERENCE.md](docs/EXTRACTOR_REFERENCE.md) for per-extractor documentation with configuration, edge cases, and example output.

### Key Design Decisions

**Concern inlining** — included concerns are embedded directly in the model's source. **Route prepending** — controllers get a route header showing HTTP verb → path → action. **Semantic chunking** — models split by purpose (associations, callbacks, validations), controllers split per-action. **Dependency graph with BFS blast radius** — forward and reverse edges enable change-impact traversal.

## MCP Servers

CodebaseIndex ships two [MCP](https://modelcontextprotocol.io/) servers for integrating with AI development tools (Claude Code, Cursor, Windsurf, etc.).

**Index Server** (27 tools) — Reads pre-extracted data from disk. No Rails boot required. Provides code lookup, dependency traversal, graph analysis, semantic search, pipeline management, feedback collection, and temporal snapshots.

```bash
codebase-index-mcp /path/to/rails-app/tmp/codebase_index
```

**Console Server** (31 tools) — Bridges to a live Rails process for database queries, model diagnostics, job monitoring, and guarded operations. All queries run in rolled-back transactions with SQL validation and audit logging.

```bash
codebase-console-mcp
```

See [docs/MCP_SERVERS.md](docs/MCP_SERVERS.md) for the full tool catalog and setup instructions.

### Claude Code Setup

Add the servers to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp-start",
      "args": ["/path/to/rails-app/tmp/codebase_index"]
    },
    "codebase-console": {
      "command": "bundle",
      "args": ["exec", "rake", "codebase_index:console"],
      "cwd": "/path/to/rails-app"
    }
  }
}
```

> **Recommended**: Use `codebase-index-mcp-start` instead of `codebase-index-mcp` for Claude Code. It validates the index directory exists, checks for a manifest, ensures dependencies are installed, and restarts automatically on failure.

The **index server** reads from a pre-extracted directory — run `bundle exec rake codebase_index:extract` in your Rails app first.

The **console server** runs embedded inside your Rails app (no config file needed). For Docker setups, see [docs/DOCKER_SETUP.md](docs/DOCKER_SETUP.md).

## Subsystems

```
lib/codebase_index/
├── extractor.rb              # Orchestrator — coordinates all 34 extractors
├── extracted_unit.rb         # Core value object (the universal currency)
├── dependency_graph.rb       # Directed graph + PageRank scoring
├── graph_analyzer.rb         # Structural analysis (orphans, hubs, cycles, bridges)
├── retriever.rb              # Retrieval orchestrator with degradation tiers
├── extractors/               # 34 extractors (one per Rails concept)
├── ast/                      # Prism-based AST layer
├── ruby_analyzer/            # Static analysis (class, method, dataflow)
├── chunking/                 # Semantic chunking (type-aware splitting)
├── embedding/                # Embedding pipeline (OpenAI, Ollama)
├── storage/                  # Storage backends (pgvector, Qdrant, SQLite)
├── retrieval/                # Retrieval pipeline (classify, search, rank, assemble)
├── mcp/                      # MCP Index Server (27 tools)
├── console/                  # Console MCP Server (31 tools, 4 tiers)
├── coordination/             # Multi-agent pipeline locking
├── notion/                   # Notion export
├── session_tracer/           # Session tracing middleware
├── temporal/                 # Temporal snapshot system
└── evaluation/               # Retrieval evaluation harness

exe/
├── codebase-index-mcp        # Index Server executable (stdio)
├── codebase-index-mcp-start  # Self-healing MCP wrapper
├── codebase-index-mcp-http   # Index Server (HTTP/Rack)
└── codebase-console-mcp      # Console MCP Server executable
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full pipeline explanation — extraction phases, dependency graph, retrieval pipeline, storage backends, and semantic chunking.

## Usage

### Full Extraction

```bash
bundle exec rake codebase_index:extract
```

### Incremental (CI)

```bash
bundle exec rake codebase_index:incremental
```

Auto-detects GitHub Actions / GitLab CI environment. See [Getting Started](docs/GETTING_STARTED.md) for CI workflow YAML.

### Docker

Extraction runs inside the container; the Index Server runs on the host reading volume-mounted output. See [docs/DOCKER_SETUP.md](docs/DOCKER_SETUP.md) for Docker setup, MCP config, and troubleshooting.

```bash
docker compose exec app bundle exec rake codebase_index:extract
```

### Other Tasks

```bash
rake codebase_index:validate          # Check index integrity
rake codebase_index:stats             # Show unit counts, sizes, graph stats
rake codebase_index:clean             # Remove index
rake codebase_index:embed             # Embed all extracted units
rake codebase_index:embed_incremental # Embed changed units only
rake codebase_index:flow[EntryPoint]  # Generate execution flow for an entry point
rake codebase_index:console           # Start console MCP server
rake codebase_index:notion_sync       # Sync models/columns to Notion databases
```

See [docs/NOTION_INTEGRATION.md](docs/NOTION_INTEGRATION.md) for Notion export configuration.

### Ruby API

> **Requires a booted Rails environment.** These methods use runtime introspection and must be called from within a Rails process (console, rake task, initializer).

```ruby
# Full extraction (output_dir from configuration)
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

## Documentation

| Guide | Purpose |
|-------|---------|
| [Getting Started](docs/GETTING_STARTED.md) | Install, configure, extract, inspect |
| [FAQ](docs/FAQ.md) | Common questions about setup, extraction, MCP, Docker |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Symptom → cause → fix for common problems |
| [Architecture](docs/ARCHITECTURE.md) | Pipeline stages, dependency graph, retrieval, storage |
| [Extractor Reference](docs/EXTRACTOR_REFERENCE.md) | What each of the 34 extractors captures |
| [MCP Servers](docs/MCP_SERVERS.md) | Full tool catalog and setup for Claude Code, Cursor, Windsurf |
| [MCP Tool Cookbook](docs/MCP_TOOL_COOKBOOK.md) | Scenario-based examples for common tasks |
| [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) | All options with defaults |
| [Backend Matrix](docs/BACKEND_MATRIX.md) | Supported infrastructure combinations |

## Development

```bash
bin/setup          # Install dependencies
bundle exec rake spec      # Run tests
bundle exec rubocop        # Lint
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/LeahArmstrong/codebase_index. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
