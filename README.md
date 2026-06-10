<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/woods-wordmark-white.svg">
    <img src="assets/woods-wordmark-black.svg" width="300" alt="woods">
  </picture>
</p>

# Woods

**Your AI coding assistant is guessing about your Rails app. Woods gives it the real answers.**

Rails hides enormous amounts of behavior behind conventions, concerns, and runtime magic. When you ask an AI assistant "what callbacks fire when a User saves?" or "what routes map to this controller?", it guesses from training data — and gets it wrong. Woods runs *inside* your Rails app, extracts what's actually happening at runtime, and serves that context directly to your AI tools via [MCP](https://modelcontextprotocol.io/).

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

**Woods fixes this by running inside Rails and extracting what's actually there.**

See [Why Woods?](docs/WHY_WOODS.md) for detailed before/after examples.

---

## Quick Start

Five steps from install to asking questions:

```bash
# 1. Add to your Rails app's Gemfile
gem 'woods', group: :development

# 2. Install and configure
bundle install
rails generate woods:install

# 3. Extract your codebase (requires Rails to be running)
bundle exec rake woods:extract
# Aliases: woods:scan

# 4. Verify it worked
bundle exec rake woods:stats
# Aliases: woods:look

# 5. Add the MCP server to your AI tool (see "Connect to Your AI Tool" below)
```

After extraction, your AI tool gets accurate, structured context about every model, controller, service, job, route, and more — including all the behavior that Rails hides.

> **Docker?** Run extraction inside the container: `docker compose exec app bundle exec rake woods:extract`. The MCP server runs on the host reading volume-mounted output. See [Docker Setup](docs/DOCKER_SETUP.md).

See [Getting Started](docs/GETTING_STARTED.md) for the full walkthrough including storage presets, CI setup, and common first-run issues.

---

## What Does It Actually Do?

Woods boots your Rails app, introspects everything using runtime APIs, and writes structured JSON that your AI tools can read. Here's what that means in practice:

### Concern Inlining

Your `User` model includes `Auditable`, `Searchable`, and `SoftDeletable`. An AI tool reading `app/models/user.rb` sees 40 lines. Woods inlines all three concerns directly into the extracted unit — the AI sees the full 200-line behavioral surface area in one block.

```ruby
# What your AI sees (app/models/user.rb) — 4 lines:
class User < ApplicationRecord
  include Auditable
  include Searchable
end

# What Woods produces — full source with schema + inlined concerns:
# == Schema Information
# email    :string           not null
# name     :string
#
# class User < ApplicationRecord
#   include Auditable
#   include Searchable
#   validates :email, presence: true, uniqueness: true
#   ...
# end
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Auditable                                            │
# └─────────────────────────────────────────────────────────────────────┘
#   def audit_trail ...
# ─────────────────────────── End Auditable ───────────────────────────
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Searchable                                           │
# └─────────────────────────────────────────────────────────────────────┘
#   scope :search, ->(q) { where("name ILIKE ?", "%#{q}%") }
# ─────────────────────────── End Searchable ───────────────────────────
```

The `metadata[:inlined_concerns]` array lists which concerns were resolved, so retrieval can filter by concern inclusion.

### Schema Prepending

Model source gets a header with actual column types, indexes, and foreign keys pulled from the live database. No more guessing whether `name` is a `string` or `text`, or whether there's an index on `email`.

### Route Binding

Controller source gets a route map prepended showing the real HTTP verb + path + constraints for every action. No more assuming standard REST when your app has custom routes and nested resources.

### Dependency Graph

34 extractors build a bidirectional graph: what each unit depends on, and what depends on it. Change a concern and trace every model it touches. Refactor a service and see every controller that calls it. PageRank scoring identifies the most important nodes in your codebase.

Navigation edges (`link_to`, `redirect_to`, `form_action`) trace UI user journeys through the graph — filter with the `via` parameter on `dependencies`/`dependents` tools to isolate navigation paths from code references.

### Callback Side-Effect Analysis

`CallbackAnalyzer` detects what actually happens inside callbacks — which columns get written, which jobs get enqueued, which services get called, which mailers fire. This is the #1 source of unexpected bugs in Rails, and the #1 thing AI tools get wrong.

---

## Examples

### Extracted Model with Schema and Associations

After extraction, each model is a self-contained JSON file with schema, associations, validations, and inlined concern source:

```json
{
  "type": "model",
  "identifier": "Order",
  "file_path": "app/models/order.rb",
  "source_code": "# == Schema Information\n# id         :bigint  not null, pk\n# user_id    :bigint  not null, fk\n# status     :string  default(\"pending\")\n# total_cents :integer\n#\nclass Order < ApplicationRecord\n  belongs_to :user\n  has_many :line_items\n  validates :status, inclusion: { in: %w[pending paid shipped] }\n  ...\nend\n\n# ┌───────────────────────────────────────────────────────────────────┐\n# │ Included from: Auditable                                          │\n# └───────────────────────────────────────────────────────────────────┘\n#   module Auditable\n#     ...\n#   end\n# ──────────────────────── End Auditable ────────────────────────────",
  "metadata": {
    "associations": [
      { "type": "belongs_to", "name": "user", "target": "User" },
      { "type": "has_many", "name": "line_items", "target": "LineItem" }
    ],
    "validations": [
      { "attribute": "status", "type": "inclusion", "options": { "in": ["pending", "paid", "shipped"] } }
    ],
    "enums": { "status": { "pending": 0, "active": 1, "shipped": 2 } },
    "scopes": [{ "name": "active", "source": "-> { where(status: :active) }" }],
    "inlined_concerns": ["Auditable"]
  },
  "dependencies": [
    { "type": "model", "target": "User", "via": "belongs_to" },
    { "type": "model", "target": "LineItem", "via": "has_many" }
  ]
}
```

### Callback Chain with Side-Effects

Woods resolves the full callback chain in execution order and detects side-effects — which columns get written, which jobs get enqueued, which mailers fire:

```json
"callbacks": [
  { "type": "before_validation", "filter": "normalize_email", "kind": "before", "conditions": {} },
  { "type": "before_save", "filter": "set_slug", "kind": "before", "conditions": {},
    "side_effects": { "columns_written": ["slug"], "jobs_enqueued": [], "services_called": [], "mailers_triggered": [], "database_reads": [], "operations": [] } },
  { "type": "after_commit", "filter": "send_welcome", "kind": "after", "conditions": {},
    "side_effects": { "columns_written": [], "jobs_enqueued": ["WelcomeEmailJob"], "services_called": [], "mailers_triggered": ["UserMailer"], "database_reads": [], "operations": [] } }
]
```

Side-effects are detected by `CallbackAnalyzer`, which scans callback method bodies for patterns like `self.col =` (column writes), `perform_later` (job enqueues), and `deliver_later` (mailer triggers). This is the #1 thing AI tools get wrong about Rails models.

### Route-to-Controller Lookup

Every route becomes its own `ExtractedUnit` with the controller and action bound from the live routing table:

```json
{
  "type": "route",
  "identifier": "POST /checkout",
  "metadata": {
    "controller": "orders",
    "action": "create",
    "route_name": "checkout"
  }
}
```

To find which controller handles a URL, use the MCP `search` tool:

```json
{ "tool": "search", "params": { "query": "/checkout", "types": ["route"] } }
```

This returns all matching route units with their controller and action — no guessing about custom routes, nested resources, or engine mount points.

### Looking Up a Model's Full Structure

Use the MCP `lookup` tool to get a model's complete JSON representation — schema, associations, validations, callbacks, and inlined concerns in one call:

```json
{ "tool": "lookup", "params": { "identifier": "Order", "include_source": true } }
```

Returns the full `ExtractedUnit` JSON shown in the example above, including `source_code` (with schema header and inlined concerns), `metadata` (associations, callbacks, validations, enums, scopes), `dependencies`, and `dependents`.

To get just the structured metadata without source code:

```json
{ "tool": "lookup", "params": { "identifier": "Order", "include_source": false, "sections": ["metadata"] } }
```

### Finding Jobs Enqueued by a Service

Use the MCP `dependencies` tool to trace what a service triggers:

```json
{ "tool": "dependencies", "params": { "identifier": "CheckoutService", "depth": 2, "types": ["job"] } }
```

Returns all job units reachable from `CheckoutService` within 2 hops — including jobs triggered indirectly via model callbacks (e.g., `CheckoutService` → `Order` → `OrderConfirmationJob`).

### Tracing UI Navigation

Use the MCP `dependents` tool with `via` filtering to find what links to a controller:

```json
{ "tool": "dependents", "params": { "identifier": "OrdersController", "depth": 1, "via": ["link_to", "form_action"] } }
```

Returns view templates that navigate to `OrdersController` via `link_to` helpers or form submissions — isolating UI navigation edges from code references and other relationship types.

### Runtime-Generated Method Detection

Because Woods runs inside the booted Rails process, it captures every method Rails generates dynamically — enum predicates, association builders, attribute accessors, and scope methods that static analysis tools cannot see:

```json
{
  "identifier": "Order",
  "metadata": {
    "enums": { "status": { "pending": 0, "active": 1, "shipped": 2 } },
    "scopes": [{ "name": "active", "source": "-> { where(status: :active) }" }],
    "associations": [{ "type": "has_many", "name": "line_items", "target": "LineItem" }]
  }
}
```

Static tools miss `status_active?`, `status_pending?`, `build_line_item`, `create_line_item!`, and dynamically registered scopes. Woods captures all of these because it queries the runtime class via `instance_methods(false)` after Rails has processed every DSL declaration.

---

## Connect to Your AI Tool

Woods ships two MCP servers. Most users only need the **Index Server**.

### Index Server — Reads Pre-Extracted Data (No Rails Required)

29 tools for code lookup, dependency traversal, semantic search, graph analysis, and more (14 always-on + 15 that register based on wiring: 5 operator / 4 feedback / 4 snapshot / 1 session-trace / 1 Notion). Reads static JSON from disk — fast, no Rails boot needed.

**Claude Code** — add to `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

> `woods-mcp-start` is a self-healing wrapper that validates the index, checks dependencies, and auto-restarts on failure. Recommended for Claude Code.

**Cursor / Windsurf** — add to your MCP config:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp",
      "args": ["/path/to/your-rails-app/tmp/woods"]
    }
  }
}
```

### Console Server — Live Rails Queries (Optional)

31 tools for querying real database records, monitoring job queues, running model diagnostics, and checking schema. Connects to a live Rails process. Every query runs in a rolled-back transaction with SQL validation — safe for development use.

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
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
| **Views & Components** | ERB templates, Phlex components, ViewComponents | Partial references, slot definitions, prop interfaces, navigation edges (link_to, form_action) |
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

The install generator creates a working configuration. The only required option is `output_dir`, which defaults to `tmp/woods`:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
end
```

### Storage Presets

For embedding and semantic search, use a preset to configure storage and embedding together:

```ruby
# Local development — no external services needed
Woods.configure_with_preset(:local)

# PostgreSQL — pgvector + OpenAI embeddings
Woods.configure_with_preset(:postgresql)

# Production scale — Qdrant + OpenAI embeddings
Woods.configure_with_preset(:production)
```

### Backend Compatibility

Woods is backend-agnostic. Your app database, vector store, embedding provider, and job system are all configurable independently:

| Component | Options |
|-----------|---------|
| **App Database** | MySQL, PostgreSQL, SQLite |
| **Vector Store** | In-memory, pgvector, Qdrant |
| **Embeddings** | OpenAI, Ollama (local, free) |
| **Job System** | Sidekiq, Solid Queue, GoodJob, inline |
| **View Layer** | ERB, Phlex, ViewComponent |

See [Backend Matrix](docs/BACKEND_MATRIX.md) for supported combinations and [Configuration Reference](docs/CONFIGURATION_REFERENCE.md) for every option with defaults.

### Environment-Specific Configuration

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')

  # CI: only extract models and controllers for faster builds
  config.extractors = %i[models controllers] if ENV['CI']

  # Environment-conditional embedding provider
  if ENV['OPENAI_API_KEY']
    config.embedding_provider = :openai
    config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
  else
    config.embedding_provider = :ollama
    config.embedding_options = { model: 'nomic-embed-text', host: 'http://localhost:11434' }
  end
end
```

---

## Keeping the Index Current

### Incremental Updates

After the initial extraction, update only changed files — typically 5-10x faster:

```bash
bundle exec rake woods:incremental
# Aliases: woods:tend
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
        run: bundle exec rake woods:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

### Other Tasks

```bash
rake woods:validate            # Check index integrity (alias: woods:vet)
rake woods:stats               # Show unit counts and graph stats (alias: woods:look)
rake woods:clean               # Remove index output (alias: woods:clear)
rake woods:embed               # Embed units for semantic search (alias: woods:nest)
rake woods:embed_incremental   # Embed changed units only (alias: woods:hone)
rake woods:notion_sync         # Sync models/columns to Notion (alias: woods:send)
```

---

## How It Works Under the Hood

```
Inside your Rails app (rake task):
  1. Boot Rails, eager-load all application classes
  2. 34 extractors introspect models, controllers, routes, etc.
  3. Dependency graph is built with forward + reverse edges
  4. Git metadata enriches each unit (last modified, contributors, churn)
  5. JSON output written to tmp/woods/

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
| `file_path` | Source file location relative to Rails root |
| `namespace` | Module namespace (`"Admin"`, `nil` for top-level) |
| `source_code` | Annotated source with inlined concerns and schema |
| `metadata` | Structured data — associations, callbacks, routes, fields |
| `dependencies` | What this unit depends on (forward edges) |
| `dependents` | What depends on this unit (reverse edges) |
| `chunks` | Semantic sub-sections for large units |
| `extracted_at` | ISO 8601 timestamp of extraction |
| `source_hash` | SHA-256 digest for change detection |

### Output Structure

```
tmp/woods/
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
│  │  OpenAI /  │    │ pgvector /  │    │  29 tools            │  │
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
| [Why Woods?](docs/WHY_WOODS.md) | Evaluation | Detailed before/after comparisons |

---

## Requirements

- Ruby >= 3.0
- Rails >= 6.1

Works with MySQL, PostgreSQL, and SQLite. No additional infrastructure required for basic extraction — embedding and vector search are optional add-ons.

## Development

```bash
bin/setup                  # Install dependencies
bundle exec rake spec      # Run tests (~3300 examples)
bundle exec rubocop        # Lint
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/lost-in-the/woods. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Available as open source under the [MIT License](LICENSE.txt).
