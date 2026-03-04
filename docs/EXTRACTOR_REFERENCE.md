# CodebaseIndex Extractor Reference

CodebaseIndex ships 34 extractors — one for each meaningful category of Rails code. This doc covers what each extractor captures, how to configure them, and the shape of the data they produce.

---

## How Do Extractors Work?

### The Five Phases

A full extraction (`bundle exec rake codebase_index:extract`) runs five phases:

```
Phase 1: Extract     — All 34 extractors run, producing ExtractedUnit objects
Phase 1.5: Dedupe    — Duplicate identifiers are dropped (engines can double-register routes)
Phase 2: Resolve     — Reverse dependency edges are built (A depends on B → B gets a dependent)
Phase 3: Graph       — PageRank + structural analysis (orphans, hubs, cycles, bridges)
Phase 4: Enrich      — Git metadata added (last author, change frequency, recent commits)
Phase 5: Write       — One JSON file per unit, _index.json per type, dependency_graph.json, SUMMARY.md
```

### Two Discovery Strategies

Extractors discover code one of two ways:

| Strategy | How it works | Examples |
|----------|-------------|---------|
| **Class-based** | `ActiveRecord::Base.descendants`, `ApplicationController.descendants`, etc. — requires `eager_load!` | ModelExtractor, ControllerExtractor, MailerExtractor |
| **File-based** | Scans conventional directories (`app/services`, `db/migrate`, etc.) — more robust for non-AR classes | ServiceExtractor, MigrationExtractor, ViewTemplateExtractor |

Some extractors combine both (e.g., `JobExtractor` scans directories first, then supplements with `ApplicationJob.descendants`).

### Eager Loading

The orchestrator calls `Rails.application.eager_load!` once before extraction begins. If that fails with a `NameError` (common when `app/graphql/` references an uninstalled gem), it falls back to per-directory loading via `EXTRACTION_DIRECTORIES`. This fallback covers the directories that matter for extraction.

### What Every Extractor Returns

Every extractor returns `Array<ExtractedUnit>`. An `ExtractedUnit` is a self-contained snapshot of one code unit with source, metadata, and relationships. See [ExtractedUnit Field Reference](#extractedunit-field-reference) at the bottom of this doc.

---

## Core Application Extractors

### ModelExtractor

**What it captures:** Every non-abstract `ActiveRecord::Base` descendant with concrete table-backed state. The source_code is the model's actual Ruby source *plus* all included concerns inlined below it as formatted comment blocks. Schema information (columns, types, indexes, foreign keys) is prepended as a header comment.

**Key details:**
- Uses `ActiveRecord::Base.descendants` for discovery (runtime introspection, not static parsing)
- Inlines concerns: all `include FooConcern` references are resolved and the concern source is appended to `source_code`. Inlined concern names are recorded in `metadata[:inlined_concerns]`
- Extracts all 13 callback types: `before_validation`, `after_validation`, `before_save`, `around_save`, `after_save`, `before_create`, `after_create`, `before_update`, `after_update`, `before_destroy`, `after_destroy`, `after_commit`, `after_rollback`
- Callback side-effects are analyzed via `CallbackAnalyzer`: detects columns written (`self.col =`), jobs enqueued (`perform_later`), and services called
- Automatically skips HABTM join models and anonymous classes
- Chunks every model into semantic sections: `:summary`, `:associations`, `:callbacks`, `:validations`, `:scopes`, `:methods`

**Edge cases:**
- STI subclasses are extracted separately from their parent (each has its own identifier)
- `callback.options` was removed in Rails 4.2 — the extractor uses `@if`/`@unless` ivars and ActionFilter duck-typing to extract `:only`/`:except` action lists
- AR-generated internal methods (like `autosave_associated_records_for_comments`) are filtered by a single combined regex to avoid noise

**Example output (abbreviated):**

```json
{
  "type": "model",
  "identifier": "Order",
  "file_path": "app/models/order.rb",
  "namespace": null,
  "source_code": "# == Schema Information\n# id :bigint\n# user_id :bigint\n# status :string\n# total_cents :integer\n#\nclass Order < ApplicationRecord\n  belongs_to :user\n  has_many :line_items\n  ...\nend\n\n# --- Concern: Auditable ---\nmodule Auditable\n  ...\nend",
  "metadata": {
    "associations": [
      { "type": "belongs_to", "name": "user", "model": "User" },
      { "type": "has_many", "name": "line_items", "model": "LineItem" }
    ],
    "callbacks": [
      { "type": "after_commit", "method": "send_confirmation_email", "on": ["create"] }
    ],
    "validations": [
      { "attribute": "status", "kind": "inclusion", "in": ["pending", "paid", "shipped"] }
    ],
    "inlined_concerns": ["Auditable"]
  },
  "dependencies": [
    { "type": "model", "target": "User", "via": "belongs_to" },
    { "type": "model", "target": "LineItem", "via": "has_many" }
  ]
}
```

---

### ControllerExtractor

**What it captures:** Every `ApplicationController` and `ActionController::API` descendant. Route context is prepended to the source — each controller gets a header block showing which HTTP verb + path maps to each action. Before/after filter chains are resolved per action.

**Key details:**
- Discovers controllers via `ApplicationController.descendants` (and `ActionController::API.descendants` if present)
- Builds a routes map from `Rails.application.routes` at initialization time
- Route context is inlined in `source_code` as a comment header, not just in metadata
- Chunks per-action: each action becomes a `:action` chunk with its applicable filters and route
- Metadata includes permitted params (strong parameters), response formats, and applied filters per action

**Edge cases:**
- API-only controllers (`ActionController::API` descendants) are included when the gem is present
- Controllers with no corresponding routes still get extracted (they may be base classes)

**Example output (abbreviated):**

```json
{
  "type": "controller",
  "identifier": "OrdersController",
  "metadata": {
    "actions": ["index", "show", "create", "update"],
    "routes": [
      { "verb": "GET", "path": "/orders", "action": "index" },
      { "verb": "POST", "path": "/orders", "action": "create" }
    ],
    "filters": {
      "before": ["authenticate_user!", "set_order"],
      "after": ["track_event"]
    }
  }
}
```

---

### ServiceExtractor

**What it captures:** Service objects, interactors, operations, commands, and use cases — the "business logic layer." Discovers them by scanning conventional directories for Ruby files.

**Key details:**
- Scans: `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`
- Extracts public entry points (`call`, `perform`, `execute`, `run`), custom error classes, and dependency references
- File-based discovery (not class introspection), so it catches services with non-standard superclasses

**Example output (abbreviated):**

```json
{
  "type": "service",
  "identifier": "CheckoutService",
  "metadata": {
    "entry_points": ["call"],
    "custom_errors": ["CheckoutService::PaymentFailedError"],
    "dependencies": ["Order", "PaymentProcessor"]
  }
}
```

---

### JobExtractor

**What it captures:** ActiveJob workers and Sidekiq workers. Scans job directories, then supplements with `ApplicationJob.descendants` for anything discovered at runtime but not found via files.

**Key details:**
- Scans: `app/jobs`, `app/workers`, `app/sidekiq`
- Extracts queue name, retry configuration, concurrency options, perform method arguments, and callbacks
- Records what triggers this job (reverse lookup via dependency graph after extraction)
- Supports both ActiveJob and Sidekiq native workers

**Example output (abbreviated):**

```json
{
  "type": "job",
  "identifier": "ProcessOrderJob",
  "metadata": {
    "queue": "default",
    "retry_on": ["Stripe::APIError"],
    "perform_args": ["order_id"],
    "adapter": "ActiveJob"
  }
}
```

---

### MailerExtractor

**What it captures:** ActionMailer classes with their mailer actions, defaults, template paths, callbacks, and helper usage.

**Key details:**
- Discovers via class introspection (`ActionMailer::Base.descendants`)
- Each mailer action corresponds to an email template — template paths are recorded in metadata
- Extracts `default from:`, `layout`, and per-action subject patterns

---

### ConfigurationExtractor

**What it captures:** Rails initializers (`config/initializers/**/*.rb`) and environment files (`config/environments/*.rb`). Also extracts a behavioral profile from the resolved `Rails.application.config` values at runtime.

**Key details:**
- `BehavioralProfile` introspects live config using `respond_to?`/`defined?` guards — a missing config section produces `nil`, not an error
- Captures: asset pipeline config, middleware additions, cache store, logger config, and custom initializer logic
- One unit per config file, plus one special `:behavioral_profile` unit per environment

---

### RouteExtractor

**What it captures:** Every route in the Rails routing table via `Rails.application.routes.routes`. Each route becomes its own `ExtractedUnit`.

**Key details:**
- Pure runtime introspection — reads the live routing table, not `config/routes.rb` AST
- Each unit's identifier is `"VERB /path"` (e.g., `"POST /orders"`)
- Records controller, action, route name, and constraints
- Since routes don't map to individual files, incremental re-extraction skips this type (always full)

**Example output (abbreviated):**

```json
{
  "type": "route",
  "identifier": "POST /orders",
  "metadata": {
    "controller": "orders",
    "action": "create",
    "route_name": "orders"
  }
}
```

---

### MiddlewareExtractor

**What it captures:** The full Rack middleware stack as a single ordered unit. Useful for understanding request preprocessing and which middleware is active.

**Key details:**
- Extracts the entire stack as one unit (not one per middleware)
- Records middleware class names, insertion order, and any initialization arguments

---

## UI Component Extractors

### PhlexExtractor

**What it captures:** Phlex component classes (`Phlex::HTML`, `Phlex::SVG` subclasses) from `app/components`. Extracts slots, initialize parameters, sub-component references, Stimulus controller names, and route helper usage.

**Key details:**
- Phlex components render pure Ruby — no template files to parse separately
- Slots and sub-component composition are extracted from the `view_template` method

---

### ViewComponentExtractor

**What it captures:** ViewComponent classes from `app/components`. Extracts slots, template paths, preview class references, and collection rendering support.

**Key details:**
- Template path is inferred from the component file name (e.g., `ButtonComponent` → `button_component.html.erb`)
- Preview class associations are extracted when `<ComponentName>Preview` is found in `spec/components/previews/` or `test/components/previews/`

**Edge cases:**
- Phlex and ViewComponent both scan `app/components` — the orchestrator uses separate extractors for each. A Phlex component won't be extracted by ViewComponentExtractor and vice versa (the filtering is by superclass, not file name)

---

### ViewTemplateExtractor

**What it captures:** ERB view templates from `app/views`. Extracts render calls (partials and components), instance variable references, and helper method usage.

**Key details:**
- File-based scanning — no Rails boot needed for the actual file reading
- Records which partials a template renders and which instance variables it expects

---

### DecoratorExtractor

**What it captures:** Decorator, presenter, and form object classes from `app/decorators`, `app/presenters`, and `app/form_objects`.

**Key details:**
- These directories are also added to `EXTRACTION_DIRECTORIES` for eager loading
- Extracts delegated methods, wrapped model class, and custom presentation methods

---

## Data Layer Extractors

### ConcernExtractor

**What it captures:** `ActiveSupport::Concern` modules from `app/models/concerns` and `app/controllers/concerns`.

**Key details:**
- Scans: `app/models/concerns`, `app/controllers/concerns`
- Extracts included hooks, `ClassMethods` block, instance methods, and class methods added by the concern
- Dependencies on models and other concerns are tracked
- Note: concerns are *also* inlined into model/controller source by ModelExtractor and ControllerExtractor. ConcernExtractor produces standalone units for direct lookup

---

### PoroExtractor

**What it captures:** Plain Ruby objects in `app/models` that are not ActiveRecord (non-AR classes, excluding concerns).

**Key details:**
- Scans `app/models` for files that don't define an `ActiveRecord::Base` descendant
- Common examples: value objects, form objects placed in `app/models`, domain structs
- Excludes concerns (those go to ConcernExtractor)

---

### SerializerExtractor

**What it captures:** Serializer classes for ActiveModelSerializers, Blueprinter, Alba, and Draper. Auto-detects which serialization gems are loaded.

**Key details:**
- Each supported library is probed with `defined?` before attempting extraction
- Extracts serialized attributes, associations, and any custom method overrides

---

### ValidatorExtractor

**What it captures:** Custom `ActiveModel::Validator` subclasses with their validation rules.

**Key details:**
- File-based scanning; extracts `validate` method logic and the attribute being validated

---

### ManagerExtractor

**What it captures:** `SimpleDelegator` subclasses that wrap a model. Records the wrapped model class, all public methods, and the delegation chain.

---

## API & Authorization Extractors

### GraphQLExtractor

**What it captures:** graphql-ruby types, mutations, queries, and resolvers. Produces four distinct unit types from one extractor.

**Key details:**
- Scans `app/graphql` with runtime introspection via `GraphQL::Schema.types` when available, falls back to file discovery
- Produces unit types: `graphql_type`, `graphql_mutation`, `graphql_resolver`, `graphql_query`
- Extracts field metadata (types, descriptions, complexity, arguments), authorization patterns (Pundit, CanCan, `authorized?`), and dependencies on models/services
- Since all GraphQL units come from one extractor, incremental re-extraction handles them via `extract_graphql_file`

**Example output (abbreviated):**

```json
{
  "type": "graphql_type",
  "identifier": "Types::UserType",
  "metadata": {
    "fields": [
      { "name": "id", "type": "ID!", "description": null },
      { "name": "email", "type": "String!" }
    ],
    "authorized_by": "pundit"
  }
}
```

---

### PunditExtractor

**What it captures:** Pundit policy classes with their action methods (`index?`, `show?`, `create?`, `update?`, `destroy?`, and custom predicates).

**Key details:**
- Pairs policy units with their corresponding model (e.g., `UserPolicy` → `User`)
- Extracts scope class and `resolve` method when present

---

### PolicyExtractor

**What it captures:** Domain policy classes (non-Pundit) with decision methods and eligibility rules. Covers plain Ruby objects used for authorization decisions.

**Key details:**
- Scans `app/policies` for files not identified as Pundit policies
- Extracts public predicate methods and their dependencies

---

## Infrastructure Extractors

### EngineExtractor

**What it captures:** Mounted Rails engines via runtime introspection. Records mount points and route counts for each engine.

**Key details:**
- Uses `Rails::Engine.subclasses` at runtime — finds both gem-mounted and in-repo engines
- Incremental re-extraction skips engine units (they don't map to individual files; requires full extraction)
- A mounted engine may duplicate some routes; the deduplication phase handles this

---

### I18nExtractor

**What it captures:** Locale files from `config/locales` with the full translation key hierarchy.

**Key details:**
- Scans `config/locales/**/*.{yml,yaml}`
- Produces one unit per locale file with the nested key structure flattened in metadata
- Useful for answering "what locales do we support?" and "what keys exist under X?"

---

### ActionCableExtractor

**What it captures:** ActionCable channel classes with stream subscriptions, subscribed/unsubscribed hooks, broadcast patterns, and action methods.

**Key details:**
- Discovers via `ActionCable::Channel::Base.descendants`
- Records stream names, authentication checks in `subscribed`, and any `broadcast_to` calls

---

### ScheduledJobExtractor

**What it captures:** Scheduled job definitions from cron-style config files. Supports multiple scheduling backends.

**Key details:**
- Reads: `config/recurring.yml` (Solid Queue), `config/sidekiq_cron.yml` (Sidekiq Cron), `config/schedule.rb` (Whenever)
- Extracts job class name, cron expression, queue, and any arguments
- File-based (static read, no Rails introspection needed)
- Incremental re-extraction skips scheduled jobs (no per-file mapping)

---

### RakeTaskExtractor

**What it captures:** Rake tasks from `lib/tasks/*.rake`. Extracts namespaces, task names, descriptions, prerequisites (`:depends_on`), and the task body.

**Key details:**
- Reads `.rake` files statically — no Rails boot required for parsing
- Uses `block_opener?` for depth tracking; `if`/`unless` only match at line start to avoid counting trailing modifiers as blocks
- Supports nested namespaces (`namespace :data do namespace :import do task :users`)

---

### MigrationExtractor

**What it captures:** ActiveRecord migration files from `db/migrate`. Extracts DDL metadata, affected tables, risk indicators, and reversibility.

**Key details:**
- Scans `db/migrate/*.rb`
- Extracts: tables created/dropped/modified, columns added/removed, indexes, references
- Risk indicators: data migrations (manual SQL or bulk updates), irreversible operations (`remove_column` without type), `execute` calls with raw SQL
- Rails internal tables (`schema_migrations`, `active_storage_blobs`, etc.) are excluded from model dependency links

**Example output (abbreviated):**

```json
{
  "type": "migration",
  "identifier": "AddStatusToOrders",
  "metadata": {
    "version": "20240115120000",
    "tables_affected": ["orders"],
    "operations": [
      { "type": "add_column", "table": "orders", "column": "status", "column_type": "string" }
    ],
    "reversible": true,
    "risk_level": "low"
  }
}
```

---

### DatabaseViewExtractor

**What it captures:** SQL views from `db/views` following the Scenic gem convention.

**Key details:**
- Only extracts the **latest version** of each view (highest `_vNN` suffix)
- Older versions are skipped
- Records whether the view is materialized and which tables it references

---

### StateMachineExtractor

**What it captures:** State machine DSL definitions using AASM, Statesman, or the `state_machines` gem.

**Key details:**
- Detects which library is active by checking `defined?` for each DSL constant
- Extracts states, events, transitions, guard conditions, and callbacks
- Returns an array from the file method (like `ScheduledJobExtractor`) — cannot be used in the incremental file-based dispatch map

---

### EventExtractor

**What it captures:** Event publish/subscribe patterns using `ActiveSupport::Notifications` or Wisper.

**Key details:**
- Two-pass approach: first collects all `publish`/`instrument` calls, then `subscribe`/`on` calls, then merges them
- No single-file extraction method — requires full extraction to update (like routes)
- Useful for tracing event-driven flows: "what subscribes to order.created?"

---

### CachingExtractor

**What it captures:** Cache usage patterns across controllers, models, and ERB view templates.

**Key details:**
- Scans controllers, models, and `.erb` view files
- Extracts: `cache` blocks, `Rails.cache.fetch`, `expire_fragment`, TTLs, and cache keys
- The `file_type` parameter on `extract_caching_file` defaults to `nil` (auto-detected from path)

---

## Testing & Source Extractors

### FactoryExtractor

**What it captures:** FactoryBot factory definitions including traits, associations, and lazy attribute blocks.

**Key details:**
- Scans `spec/factories` and `test/factories`
- Produces one unit per factory definition (including trait sub-factories)
- Useful for understanding test data structure and available factory combinations

---

### TestMappingExtractor

**What it captures:** Test file-to-subject mappings with test counts, describe/context hierarchy, and test framework detection.

**Key details:**
- Scans `spec/` and `test/` directories
- Maps each spec file to its subject class by convention (e.g., `spec/models/user_spec.rb` → `User`)
- Records test count and whether RSpec or Minitest is detected
- These directories are outside `app/` so no eager loading is needed

---

### LibExtractor

**What it captures:** Ruby files from `lib/` — utility modules, standalone libraries, and infrastructure code.

**Key details:**
- Excludes `lib/tasks/` (covered by RakeTaskExtractor) and `lib/generators/`
- File-based scanning; no assumption about class hierarchy

---

### RailsSourceExtractor

**What it captures:** High-value Rails framework source and gem source files, pinned to the exact versions in `Gemfile.lock`.

**Key details:**
- Reads from `Gem.loaded_specs` — paths depend on the installed gem location
- Indexes selected paths from: `activerecord` (associations, callbacks, validations, relation, enum, transactions), `actionpack` (controller metal, callbacks, rendering, redirecting), `activesupport` (callbacks, concern, configurable, delegation)
- Additional gems can be indexed via `config.add_gem "devise", paths: [...]`
- This is what makes framework-specific queries accurate: "what options does `has_many` support?" returns the actual source for the installed Rails version

---

## How Do I Enable or Disable Extractors?

All 34 extractors run during a full extraction. The `config.extractors` array controls which unit types are considered by the *retrieval pipeline* (embedding and search scope), not which extractors run during extraction.

To customize the retrieval scope:

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  # Default retrieval scope (13 types)
  config.extractors = %i[
    models controllers services components view_components
    jobs mailers graphql serializers managers policies validators
    rails_source
  ]

  # Add more types to retrieval scope
  config.extractors += %i[concerns routes migrations]

  # Or restrict to a focused subset
  config.extractors = %i[models controllers services]

  # Index additional gem source files
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
end
```

To add a custom gem to be indexed by `RailsSourceExtractor`:

```ruby
config.add_gem "pundit", paths: ["lib/pundit"], priority: :medium
```

---

## ExtractedUnit Field Reference

Every extractor produces `ExtractedUnit` objects with this schema:

| Field | Type | Description |
|-------|------|-------------|
| `type` | Symbol | Unit category: `:model`, `:controller`, `:service`, `:job`, `:mailer`, `:component`, `:view_component`, `:graphql_type`, `:graphql_mutation`, `:graphql_resolver`, `:graphql_query`, `:serializer`, `:manager`, `:policy`, `:validator`, `:concern`, `:route`, `:middleware`, `:i18n`, `:pundit_policy`, `:configuration`, `:engine`, `:view_template`, `:migration`, `:action_cable_channel`, `:scheduled_job`, `:rake_task`, `:state_machine`, `:event`, `:decorator`, `:database_view`, `:caching`, `:factory`, `:test_mapping`, `:rails_source`, `:poro`, `:lib` |
| `identifier` | String | Unique key for this unit. Usually the class name (e.g., `"User"`, `"OrdersController"`) or a descriptive string for non-class units (e.g., `"POST /orders"`) |
| `file_path` | String | Relative path to the source file (e.g., `"app/models/user.rb"`). Relative to `Rails.root` after normalization. |
| `namespace` | String\|nil | Module namespace if the class is nested (e.g., `"Admin"` for `Admin::DashboardController`) |
| `source_code` | String | The full source code, potentially enriched: models have concerns inlined and schema prepended; controllers have a route context header prepended |
| `metadata` | Hash | Type-specific structured data — associations, callbacks, actions, fields, etc. Keys and structure vary by extractor |
| `dependencies` | Array\<Hash\> | Forward edges: `[{ type: :model, target: "User", via: "belongs_to" }, ...]` |
| `dependents` | Array\<Hash\> | Reverse edges: populated in the second pass. `[{ type: :controller, identifier: "OrdersController" }, ...]` |
| `chunks` | Array\<Hash\> | Semantic sub-sections for large units. Each chunk: `{ chunk_index:, identifier:, content:, content_hash:, estimated_tokens: }` |
| `estimated_tokens` | Integer | Approximate token count for `source_code + metadata.to_json` using 4.0 chars/token. Computed, not stored. |

### Serialized JSON Fields

When written to disk, units also include:

| Field | Description |
|-------|-------------|
| `extracted_at` | ISO 8601 timestamp of extraction |
| `source_hash` | SHA-256 of `source_code` for change detection |

### Git Enrichment Fields (`metadata[:git]`)

If the host app is a git repo, the following are added to `metadata[:git]` after extraction:

| Field | Description |
|-------|-------------|
| `last_modified` | ISO 8601 date of last commit touching this file |
| `last_author` | Name of the author who last modified the file |
| `commit_count` | Total commit count for this file (past 365 days) |
| `contributors` | Top 5 contributors by commit count: `[{ name:, commits: }]` |
| `recent_commits` | Last 5 commits: `[{ sha:, message:, date:, author: }]` |
| `change_frequency` | `:new`, `:hot`, `:active`, `:stable`, or `:dormant` |

### Full Example JSON

```json
{
  "type": "model",
  "identifier": "User",
  "file_path": "app/models/user.rb",
  "namespace": null,
  "source_code": "# == Schema Information\n# id :bigint not null, pk\n# email :string not null\n# created_at :datetime\n#\nclass User < ApplicationRecord\n  has_many :orders\n  validates :email, presence: true, uniqueness: true\nend\n\n# --- Concern: Searchable ---\nmodule Searchable\n  extend ActiveSupport::Concern\n  ...\nend",
  "metadata": {
    "associations": [{ "type": "has_many", "name": "orders", "model": "Order" }],
    "validations": [{ "attribute": "email", "kind": "presence" }, { "attribute": "email", "kind": "uniqueness" }],
    "callbacks": [],
    "scopes": [],
    "inlined_concerns": ["Searchable"],
    "git": {
      "last_modified": "2024-11-20T14:32:00Z",
      "last_author": "Alice",
      "commit_count": 23,
      "change_frequency": "active"
    }
  },
  "dependencies": [
    { "type": "model", "target": "Order", "via": "has_many" }
  ],
  "dependents": [
    { "type": "controller", "identifier": "UsersController" }
  ],
  "chunks": [
    {
      "chunk_index": 0,
      "identifier": "User#chunk_0",
      "content": "# Unit: User (model)\n# File: app/models/user.rb\n# ---\nclass User < ApplicationRecord\n  has_many :orders\n  ...",
      "content_hash": "abc123...",
      "estimated_tokens": 312
    }
  ],
  "extracted_at": "2024-11-21T09:15:00Z",
  "source_hash": "def456..."
}
```
