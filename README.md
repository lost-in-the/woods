# CodebaseIndex

**Your AI coding assistant is guessing about your Rails app. CodebaseIndex gives it the real answers.**

Rails hides enormous amounts of behavior behind conventions, concerns, and runtime magic. When you ask an AI assistant "what callbacks fire when a User saves?" or "what routes map to this controller?", it guesses from training data — and gets it wrong. CodebaseIndex runs *inside* your Rails app, extracts what's actually happening at runtime, and serves that context directly to your AI tools via [MCP](https://modelcontextprotocol.io/).

Works with **Claude Code**, **Cursor**, **Windsurf**, and any MCP-compatible tool.

---

## The Problem

Ask your AI assistant about your Rails app and watch it confidently hallucinate:

| You ask | What the AI says | What's actually true |
|---------|-----------------|---------------------|
| "What callbacks fire when User saves?" | `before_save :set_slug` | 11 callbacks across 4 files, including 3 from concerns |
| "What routes map to OrdersController?" | Standard REST routes | Custom `POST /checkout`, nested under `/shops/:shop_id` |
| "What does the checkout flow do?" | Describes `CheckoutService` | Misses that `order.save!` triggers 3 callbacks that enqueue 2 jobs |

The AI isn't bad — it just can't see what Rails is doing. Your 40-line model file has 10x that behavior when you factor in included concerns, schema context, callback chains, validations, and association reflections. Static analysis can't reach any of it.

**CodebaseIndex fixes this by running inside Rails and extracting what's actually there.**

See [Why CodebaseIndex?](docs/WHY_CODEBASE_INDEX.md) for detailed before/after examples.

---

## Quick Start

Five steps from install to asking questions:

```bash
# 1. Add to your Rails app's Gemfile
gem 'codebase_index', group: :development

# 2. Install and configure
bundle install
rails generate codebase_index:install

# 3. Extract your codebase (requires Rails to be running)
bundle exec rake codebase_index:extract

# 4. Verify it worked
bundle exec rake codebase_index:stats

# 5. Add the MCP server to your AI tool (see "Connect to Your AI Tool" below)
```

After extraction, your AI tool gets accurate, structured context about every model, controller, service, job, route, and more — including all the behavior that Rails hides.

> **Docker?** Run extraction inside the container: `docker compose exec app bundle exec rake codebase_index:extract`. The MCP server runs on the host reading volume-mounted output. See [Docker Setup](docs/DOCKER_SETUP.md).

See [Getting Started](docs/GETTING_STARTED.md) for the full walkthrough including storage presets, CI setup, and common first-run issues.

---

## What Does It Actually Do?

CodebaseIndex boots your Rails app, introspects everything using runtime APIs, and writes structured JSON that your AI tools can read. Here's what that means in practice:

### Concern Inlining

Your `User` model includes `Auditable`, `Searchable`, and `SoftDeletable`. An AI tool reading `app/models/user.rb` sees 40 lines. CodebaseIndex inlines all three concerns directly into the extracted unit — the AI sees the full 200-line behavioral surface area in one block.

### Schema Prepending

Model source gets a header with actual column types, indexes, and foreign keys pulled from the live database. No more guessing whether `name` is a `string` or `text`, or whether there's an index on `email`.

### Route Binding

Controller source gets a route map prepended showing the real HTTP verb + path + constraints for every action. No more assuming standard REST when your app has custom routes and nested resources.

### Dependency Graph

34 extractors build a bidirectional graph: what each unit depends on, and what depends on it. Change a concern and trace every model it touches. Refactor a service and see every controller that calls it. PageRank scoring identifies the most important nodes in your codebase.

### Callback Side-Effect Analysis

`CallbackAnalyzer` detects what actually happens inside callbacks — which columns get written, which jobs get enqueued, which services get called, which mailers fire. This is the #1 source of unexpected bugs in Rails, and the #1 thing AI tools get wrong.

---

## Connect to Your AI Tool

CodebaseIndex ships two MCP servers. Most users only need the **Index Server**.

### Index Server — Reads Pre-Extracted Data (No Rails Required)

27 tools for code lookup, dependency traversal, semantic search, graph analysis, and more. Reads static JSON from disk — fast, no Rails boot needed.

**Claude Code** — add to `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    }
  }
}
```

> `codebase-index-mcp-start` is a self-healing wrapper that validates the index, checks dependencies, and auto-restarts on failure. Recommended for Claude Code.

**Cursor / Windsurf** — add to your MCP config:

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp",
      "args": ["/path/to/your-rails-app/tmp/codebase_index"]
    }
  }
}
```

### Console Server — Live Rails Queries (Optional)

31 tools for querying real database records, monitoring job queues, running model diagnostics, and checking schema. Connects to a live Rails process. Every query runs in a rolled-back transaction with SQL validation — safe for development use.

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "bundle",
      "args": ["exec", "rake", "codebase_index:console"],
      "cwd": "/path/to/your-rails-app"
    }
  }
}
```

See [MCP Servers](docs/MCP_SERVERS.md) for the full tool catalog and [MCP Tool Cookbook](docs/MCP_TOOL_COOKBOOK.md) for scenario-based examples.

---

## What Gets Extracted

34 extractors cover every major Rails concept:

| Category | What's Extracted | Key Details |
|----------|-----------------|-------------|
| **Models** | Schema, associations, validations, scopes, callbacks, enums | Concerns inlined, callback side-effects analyzed |
| **Controllers** | Actions, filters, permitted params, response formats | Route map prepended, per-action filter chains |
| **Services & Jobs** | Entry points, dependencies, retry config, queue names | Includes services, interactors, operations, commands |
| **Views & Components** | ERB templates, Phlex components, ViewComponents | Partial references, slot definitions, prop interfaces |
| **Routes & Middleware** | Full route table, middleware stack order | Constraint resolution, engine mount points |
| **GraphQL** | Types, mutations, resolvers, fields | Relay connections, argument definitions |
| **Background Work** | Jobs, mailers, Action Cable channels, scheduled tasks | Queue configuration, retry policies |
| **Data Layer** | Migrations, database views, state machines, events | DDL metadata, reversibility, transition graphs |
| **Testing** | Factories, test-to-source mappings | FactoryBot definitions, spec file associations |
| **Framework Source** | Rails internals, gem source for exact installed versions | Pinned to your `Gemfile.lock` versions |

See [Extractor Reference](docs/EXTRACTOR_REFERENCE.md) for per-extractor documentation with configuration options and example output.

---

## Use Cases

### For AI-Assisted Development

- **Context-aware code generation** — your AI sees the full model (with concerns, schema, and callbacks) before writing new code
- **Feature planning** — query the dependency graph to understand blast radius before changing anything
- **PR context** — compute affected units from a diff and explain downstream impact
- **Code review** — surface hidden callback side-effects that a reviewer might miss
- **Onboarding** — new team members ask "how does checkout work?" and get the real execution flow

### For Architecture & Technical Debt

- **Dead code detection** — `GraphAnalyzer` finds orphaned units with no dependents
- **Hub identification** — find models with 50+ dependents that are bottlenecks
- **Cycle detection** — circular dependencies surfaced automatically
- **Migration risk** — DDL metadata shows which pending migrations touch large tables
- **API surface audit** — every endpoint, its method, path, filters, and permitted params
- **Callback chain auditing** — the #1 source of Rails bugs, now visible and traceable

---

## Configuration

### Zero-Config Start

The install generator creates a working configuration. The only required option is `output_dir`, which defaults to `tmp/codebase_index`:

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
end
```

### Storage Presets

For embedding and semantic search, use a preset to configure storage and embedding together:

```ruby
# Local development — no external services needed
CodebaseIndex.configure_with_preset(:local)

# PostgreSQL — pgvector + OpenAI embeddings
CodebaseIndex.configure_with_preset(:postgresql)

# Production scale — Qdrant + OpenAI embeddings
CodebaseIndex.configure_with_preset(:production)
```

### Backend Compatibility

CodebaseIndex is backend-agnostic. Your app database, vector store, embedding provider, and job system are all configurable independently:

| Component | Options |
|-----------|---------|
| **App Database** | MySQL, PostgreSQL, SQLite |
| **Vector Store** | In-memory, pgvector, Qdrant |
| **Embeddings** | OpenAI, Ollama (local, free) |
| **Job System** | Sidekiq, Solid Queue, GoodJob, inline |
| **View Layer** | ERB, Phlex, ViewComponent |

See [Backend Matrix](docs/BACKEND_MATRIX.md) for supported combinations and [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) for every option with defaults.

---

## Keeping the Index Current

### Incremental Updates

After the initial extraction, update only changed files — typically 5-10x faster:

```bash
bundle exec rake codebase_index:incremental
```

### CI Integration

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

### Other Tasks

```bash
rake codebase_index:validate            # Check index integrity
rake codebase_index:stats               # Show unit counts and graph stats
rake codebase_index:clean               # Remove index output
rake codebase_index:embed               # Embed units for semantic search
rake codebase_index:embed_incremental   # Embed changed units only
rake codebase_index:notion_sync         # Sync models/columns to Notion
```

---

## How It Works Under the Hood

```
Inside your Rails app (rake task):
  1. Boot Rails, eager-load all application classes
  2. 34 extractors introspect models, controllers, routes, etc.
  3. Dependency graph is built with forward + reverse edges
  4. Git metadata enriches each unit (last modified, contributors, churn)
  5. JSON output written to tmp/codebase_index/

On the host (no Rails needed):
  6. Embedding pipeline chunks and vectorizes units (optional)
  7. MCP Index Server reads JSON and answers AI tool queries
```

### The ExtractedUnit

Everything flows through `ExtractedUnit` — the universal data structure. Each unit carries:

| Field | What It Contains |
|-------|-----------------|
| `identifier` | Class name or descriptive key (`"User"`, `"POST /orders"`) |
| `type` | Category (`:model`, `:controller`, `:service`, `:job`, etc.) |
| `source_code` | Annotated source with inlined concerns and schema |
| `metadata` | Structured data — associations, callbacks, routes, fields |
| `dependencies` | What this unit depends on (forward edges) |
| `dependents` | What depends on this unit (reverse edges) |
| `chunks` | Semantic sub-sections for large units |
| `estimated_tokens` | Token count for LLM context budgeting |

### Output Structure

```
tmp/codebase_index/
├── manifest.json              # Git SHA, timestamps, checksums
├── dependency_graph.json      # Full graph with PageRank scores
├── SUMMARY.md                 # Human-readable overview
├── models/
│   ├── _index.json            # Quick lookup index
│   ├── User.json              # Full unit with inlined concerns
│   └── Order.json
├── controllers/
│   └── OrdersController.json  # With route map prepended
├── services/
│   └── CheckoutService.json
└── rails_source/
    └── ...                    # Framework source for installed versions
```

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                      Rails Application                           │
│                                                                  │
│  ┌────────────┐    ┌─────────────┐    ┌──────────────────────┐  │
│  │  Extract   │───>│   Resolve   │───>│   Write JSON         │  │
│  │ 34 types   │    │   graph +   │    │   per unit           │  │
│  │            │    │   git data  │    │                      │  │
│  └────────────┘    └─────────────┘    └──────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                                               │
                     ┌─────────────────────────┘
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│                   Host / CI Environment                           │
│                                                                  │
│  ┌────────────┐    ┌─────────────┐    ┌──────────────────────┐  │
│  │  Embed     │───>│ Vector Store│    │  MCP Index Server    │  │
│  │  OpenAI /  │    │ pgvector /  │    │  27 tools            │  │
│  │  Ollama    │    │ Qdrant      │    │  No Rails required   │  │
│  └────────────┘    └─────────────┘    └──────────────────────┘  │
│                                                                  │
│                              ┌────────────────────────────────┐  │
│                              │  Console MCP Server            │  │
│                              │  31 tools, bridges to Rails    │  │
│                              └────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

See [Architecture](docs/ARCHITECTURE.md) for the deep dive — extraction phases, graph internals, retrieval pipeline, and semantic chunking.

---

## Advanced Features

| Feature | What It Does | Guide |
|---------|-------------|-------|
| **Semantic Search** | Natural-language queries like "find email validation logic" | [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) |
| **Temporal Snapshots** | Compare extraction state across git SHAs | [FAQ](docs/FAQ.md#what-are-temporal-snapshots) |
| **Session Tracing** | Record which code paths fire during a browser session | [FAQ](docs/FAQ.md#what-does-the-session-tracer-do) |
| **Notion Export** | Sync model/column data to Notion for non-technical stakeholders | [Notion Integration](docs/NOTION_INTEGRATION.md) |
| **Graph Analysis** | Find orphans, hubs, cycles, bridges in your dependency graph | [Architecture](docs/ARCHITECTURE.md) |
| **Evaluation Harness** | Measure retrieval precision, recall, and MRR | [Architecture](docs/ARCHITECTURE.md) |
| **Flow Precomputation** | Per-action request flow maps (controller → model → jobs) | [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) |

---

## Documentation

| Guide | Who It's For | Description |
|-------|-------------|-------------|
| [Getting Started](docs/GETTING_STARTED.md) | Everyone | Install, configure, extract, inspect |
| [FAQ](docs/FAQ.md) | Everyone | Common questions about setup, extraction, MCP, Docker |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Everyone | Symptom → cause → fix |
| [MCP Servers](docs/MCP_SERVERS.md) | Setup | Full tool catalog for Claude Code, Cursor, Windsurf |
| [MCP Tool Cookbook](docs/MCP_TOOL_COOKBOOK.md) | Daily use | Scenario-based "how do I..." examples |
| [Docker Setup](docs/DOCKER_SETUP.md) | Docker users | Container extraction + host MCP server |
| [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) | Customization | Every option with defaults |
| [Extractor Reference](docs/EXTRACTOR_REFERENCE.md) | Deep dive | What each of the 34 extractors captures |
| [Architecture](docs/ARCHITECTURE.md) | Contributors | Pipeline stages, graph internals, retrieval |
| [Backend Matrix](docs/BACKEND_MATRIX.md) | Infrastructure | Supported database, vector, and embedding combos |
| [Why CodebaseIndex?](docs/WHY_CODEBASE_INDEX.md) | Evaluation | Detailed before/after comparisons |

---

## Requirements

- Ruby >= 3.0
- Rails >= 6.1

Works with MySQL, PostgreSQL, and SQLite. No additional infrastructure required for basic extraction — embedding and vector search are optional add-ons.

## Development

```bash
bin/setup                  # Install dependencies
bundle exec rake spec      # Run tests (~2500 examples)
bundle exec rubocop        # Lint
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/LeahArmstrong/codebase_index. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Available as open source under the [MIT License](LICENSE.txt).
