# Why Woods?

AI coding assistants are only as good as the context they receive. For Rails applications,
that context is almost always wrong, not because the AI is bad, but because Rails hides
most of its behavior behind conventions, concerns, and runtime magic that no static tool
can see. Woods fixes this.

---

## The Problem: LLMs Get Rails Wrong

Rails is a framework built on convention over configuration. That's great for developers,
but it means the "real" code, the callbacks, the scopes, the route bindings, the concern
behavior, isn't visible in source files. An LLM reading your files sees the skeleton.
Woods shows the whole body.

**Three concrete examples:**

### "What callbacks fire when User saves?"

Without Woods, an LLM reads your 40-line `User` model and guesses:

```
User has: before_validation :normalize_email, before_save :set_slug
```

But `User` includes `Auditable`, `Searchable`, and `SoftDeletable`, each with their own
callback chains. The real answer is a chain of 11 callbacks across 4 files, including
`after_commit :reindex_search` and `after_destroy :purge_avatar`.

With Woods, the model unit has all concerns inlined and the full resolved callback
chain in structured metadata. The LLM sees exactly what Rails sees at runtime.

### "What routes map to OrdersController?"

Without Woods, an LLM assumes standard REST and guesses:

```
GET    /orders          orders#index
GET    /orders/:id      orders#show
POST   /orders          orders#create
...
```

Your app has custom routes: `POST /checkout` → `orders#create`, `PUT /orders/:id/cancel`
→ `orders#cancel`, and a nested resource under `/shops/:shop_id`. The LLM's guess is wrong
on path, wrong on nesting, and missing the custom action entirely.

With Woods, `ControllerExtractor` calls `Rails.application.routes` at runtime and
prepends the real route table to the controller source. No guessing.

### "What does the checkout flow do?"

Without Woods, an LLM reads `CheckoutService` and sees a 60-line service object.
It describes what the service does, but misses that `order.save!` triggers `after_commit
:send_confirmation_email` on `Order`, which itself enqueues `InventoryJob` via
`after_save :reserve_stock` on `LineItem`.

With Woods, the dependency graph links `CheckoutService` → `Order` → `LineItem` →
`InventoryJob`. A single retrieval call assembles the full execution picture: the service,
the models it touches, the callbacks those models fire, and the jobs those callbacks enqueue.

---

## What Does Woods Do?

Woods runs inside your Rails application and produces structured, runtime-accurate
representations of every layer: models, controllers, services, jobs, components, routes,
middleware, and more.

**The key outcomes:**

**Concern inlining.** Every `include`d concern is read from disk and embedded directly into
the model unit. When an AI asks about `User`, it gets `User` + `Auditable` + `Searchable`
in one context block, not three separate lookups.

```ruby
# What an AI sees without Woods (app/models/user.rb):
class User < ApplicationRecord
  include Auditable
  include Searchable
end  # 4 lines, the AI guesses what these concerns add

# What Woods produces (User.json source_code field):
# == Schema Information
# email    :string           not null
# name     :string
#
# class User < ApplicationRecord
#   include Auditable
#   include Searchable
#   validates :email, presence: true
# end
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Auditable                                            │
# └─────────────────────────────────────────────────────────────────────┘
#   def audit_trail; AuditLog.create!(auditable: self); end
#   after_save :audit_trail
# ─────────────────────────── End Auditable ───────────────────────────
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Searchable                                           │
# └─────────────────────────────────────────────────────────────────────┘
#   scope :search, ->(q) { where("name ILIKE ?", "%#{q}%") }
#   after_commit :reindex_search
# ─────────────────────────── End Searchable ───────────────────────────
```

**Schema prepending.** Model source gets a schema header with column types, indexes, and
foreign keys pulled live from the database. No more confusing `string` vs `text` vs
`integer` guesses.

**Route-to-controller binding.** Controller source gets a route block prepended showing
exactly which HTTP verbs and paths map to which actions. URL → code is always explicit.

**Dependency graph.** 34 extractors build a bidirectional graph: what each unit depends on,
and what depends on it. Change `Auditable` and you can trace every model affected.

**Two MCP servers.** The Index Server defines 29 schemas and registers 14 in the normal
packaged launch; it reads pre-extracted JSON without booting Rails. The Console Server
has a 31-schema inventory but registers 9 tools by default, or 11 with explicit embedded
read tools, and bridges to a live Rails process for bounded database queries.

```bash
# What you get after extraction
tmp/woods/
├── generation.json            # Atomic pointer to the current complete payload
└── payloads/gen-<N>/
    ├── manifest.json          # Extraction metadata and git SHA
    ├── dependency_graph.json  # Full graph with PageRank scores
    └── models/User.json       # Schema + inlined concerns + resolved callbacks
```

---

## Who Is Woods For?

**Teams using MCP-capable coding tools and agents.** Woods is model-independent; it
supplies Rails context through MCP to tools backed by OpenAI, Anthropic, Google, xAI,
or other model providers. If an agent helps with Rails code but lacks runtime context,
Woods fills that gap.

**Rails apps of any size.** Small apps benefit from accurate schema and route context.
Large monoliths benefit most, hundreds of models with deep callback chains and concern
hierarchies are exactly where static tools fail and Woods shines.

**Anyone who wants structured codebase context.** The extraction output is plain JSON, useful beyond AI tools for documentation, impact analysis, and onboarding.

Woods works with any database (MySQL, PostgreSQL, SQLite), any background job
system (Sidekiq, Solid Queue, GoodJob), and any view layer (ERB, Phlex, ViewComponent).
See [docs/BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full compatibility matrix.

---

## When NOT to Use Woods

Woods is not a universal fit. Skip it when:

- **You're not building in Rails.** Woods leans hard on `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs, the value dries up outside Rails. For Django, Phoenix, or non-framework Ruby, other tools are a better fit.
- **You need static analysis without booting.** Extraction requires a booted Rails environment because runtime introspection is the whole point. If your constraint is "can't boot the app" (locked-down CI, untrusted code review), static parsers are what you want.
- **Production-only environments.** Extraction should run in development or CI. The Console Server is explicitly unsafe for production even with all five defense layers, it is a dev/staging tool.
- **Row-level data is the goal.** Woods extracts schema and structure, not data. If you need to index row content for retrieval (customer records, documents, audit events), a different pipeline is appropriate.
- **Tiny apps that already fit in context.** A 20-model app may not benefit, the LLM can probably read every file. Woods' win scales with monolith size and concern depth.
- **You want a hosted service.** Woods is a gem, not a SaaS. Extraction output lives on your machines and the MCP servers run on your hardware. There is no cloud component.

---

## Quick Start

Install, extract, validate, and connect:

```bash
# 1. Add to your Rails app's Gemfile
gem 'woods', '~> 2.0', group: :development

# 2. Install
bundle install
bin/rails generate woods:install

# The generator also emits a legacy application migration. Woods 2's shipped
# paths do not use those tables; remove it for a new default installation.

# 3. Extract (requires a booted Rails environment)
bin/rails woods:extract

# 4. Verify
bin/rails woods:validate
bin/rails woods:stats

# 5. Add to .mcp.json
# { "mcpServers": { "woods": { "command": "bundle",
#     "args": ["exec", "woods-mcp-start", "./tmp/woods"],
#     "cwd": "/absolute/path/to/your-rails-app" } } }

# 6. Ask your AI tool a question about your codebase
```

For Docker, run extraction inside the application container. If Woods is installed
only there, launch the Index Server through that container too. See
[Getting started](GETTING_STARTED.md) for the complete walkthrough and
[Docker setup](DOCKER_SETUP.md) for executable container and host alternatives.
