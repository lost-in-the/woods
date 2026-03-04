# Why CodebaseIndex?

AI coding assistants are only as good as the context they receive. For Rails applications,
that context is almost always wrong — not because the AI is bad, but because Rails hides
most of its behavior behind conventions, concerns, and runtime magic that no static tool
can see. CodebaseIndex fixes this.

---

## The Problem: LLMs Get Rails Wrong

Rails is a framework built on convention over configuration. That's great for developers,
but it means the "real" code — the callbacks, the scopes, the route bindings, the concern
behavior — isn't visible in source files. An LLM reading your files sees the skeleton.
CodebaseIndex shows the whole body.

**Three concrete examples:**

### "What callbacks fire when User saves?"

Without CodebaseIndex, an LLM reads your 40-line `User` model and guesses:

```
User has: before_validation :normalize_email, before_save :set_slug
```

But `User` includes `Auditable`, `Searchable`, and `SoftDeletable` — each with their own
callback chains. The real answer is a chain of 11 callbacks across 4 files, including
`after_commit :reindex_search` and `after_destroy :purge_avatar`.

With CodebaseIndex, the model unit has all concerns inlined and the full resolved callback
chain in structured metadata. The LLM sees exactly what Rails sees at runtime.

### "What routes map to OrdersController?"

Without CodebaseIndex, an LLM assumes standard REST and guesses:

```
GET    /orders          orders#index
GET    /orders/:id      orders#show
POST   /orders          orders#create
...
```

Your app has custom routes: `POST /checkout` → `orders#create`, `PUT /orders/:id/cancel`
→ `orders#cancel`, and a nested resource under `/shops/:shop_id`. The LLM's guess is wrong
on path, wrong on nesting, and missing the custom action entirely.

With CodebaseIndex, `ControllerExtractor` calls `Rails.application.routes` at runtime and
prepends the real route table to the controller source. No guessing.

### "What does the checkout flow do?"

Without CodebaseIndex, an LLM reads `CheckoutService` and sees a 60-line service object.
It describes what the service does — but misses that `order.save!` triggers `after_commit
:send_confirmation_email` on `Order`, which itself enqueues `InventoryJob` via
`after_save :reserve_stock` on `LineItem`.

With CodebaseIndex, the dependency graph links `CheckoutService` → `Order` → `LineItem` →
`InventoryJob`. A single retrieval call assembles the full execution picture: the service,
the models it touches, the callbacks those models fire, and the jobs those callbacks enqueue.

---

## What Does CodebaseIndex Do?

CodebaseIndex runs inside your Rails application and produces structured, runtime-accurate
representations of every layer: models, controllers, services, jobs, components, routes,
middleware, and more.

**The key outcomes:**

**Concern inlining.** Every `include`d concern is read from disk and embedded directly into
the model unit. When an AI asks about `User`, it gets `User` + `Auditable` + `Searchable`
in one context block — not three separate lookups.

**Schema prepending.** Model source gets a schema header with column types, indexes, and
foreign keys pulled live from the database. No more confusing `string` vs `text` vs
`integer` guesses.

**Route-to-controller binding.** Controller source gets a route block prepended showing
exactly which HTTP verbs and paths map to which actions. URL → code is always explicit.

**Dependency graph.** 34 extractors build a bidirectional graph: what each unit depends on,
and what depends on it. Change `Auditable` and you can trace every model affected.

**Two MCP servers.** The Index Server (27 tools) reads pre-extracted JSON from disk — no
Rails boot needed. The Console Server (31 tools) bridges to a live Rails process for
database queries, job inspection, and model diagnostics.

```bash
# What you get after extraction
tmp/codebase_index/
├── manifest.json              # Extraction metadata and git SHA
├── dependency_graph.json      # Full graph with PageRank scores
├── models/User.json           # Schema + inlined concerns + resolved callbacks
├── controllers/OrdersController.json  # Real routes + per-action filter chains
└── services/CheckoutService.json      # Entry points + inferred dependencies
```

---

## Who Is CodebaseIndex For?

**Teams using AI coding assistants** — Claude Code, Cursor, Windsurf, Copilot. If your
team asks an AI to help with Rails code and gets wrong answers, CodebaseIndex is the fix.

**Rails apps of any size.** Small apps benefit from accurate schema and route context.
Large monoliths benefit most — hundreds of models with deep callback chains and concern
hierarchies are exactly where static tools fail and CodebaseIndex shines.

**Anyone who wants structured codebase context.** The extraction output is plain JSON —
useful beyond AI tools for documentation, impact analysis, and onboarding.

CodebaseIndex works with any database (MySQL, PostgreSQL, SQLite), any background job
system (Sidekiq, Solid Queue, GoodJob), and any view layer (ERB, Phlex, ViewComponent).
See [docs/BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

## Quick Start

Install, extract, and connect in six steps:

```bash
# 1. Add to your Rails app's Gemfile
gem 'codebase_index', group: :development

# 2. Install
bundle install
rails generate codebase_index:install

# 3. Extract (requires a booted Rails environment)
bundle exec rake codebase_index:extract

# 4. Verify
bundle exec rake codebase_index:stats

# 5. Add to .mcp.json
# { "mcpServers": { "codebase": { "command": "codebase-index-mcp-start",
#     "args": ["./tmp/codebase_index"] } } }

# 6. Ask your AI tool a question about your codebase
```

For Docker, run extraction inside the container and point the MCP server at the
volume-mounted output directory on the host. See [docs/GETTING_STARTED.md](GETTING_STARTED.md)
for the complete walkthrough including Docker setup, storage presets, and incremental CI updates.
