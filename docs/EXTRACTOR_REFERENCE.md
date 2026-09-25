# Woods Extractor Reference

Woods ships **35 extractor classes** producing **39 distinct unit types**: one for each meaningful category of Rails code. This doc covers what each extractor captures, how to configure them, and the shape of the data they produce.

> **Counts explained.** `lib/woods/extractors/` contains 35 extractor classes (each ending in `_extractor.rb`) plus supporting utilities such as `shared_utility_methods`, `shared_dependency_scanner`, `callback_analyzer`, `behavioral_profile`, `route_helper_resolver`, `ast_source_extraction`, `source_nesting`, and `declared_parent`. The 39 unit types comes from some extractors emitting multiple categories, `GraphQLExtractor` alone produces four (`graphql_type`, `graphql_mutation`, `graphql_resolver`, `graphql_query`), and `RailsSourceExtractor` produces both `rails_source` and `gem_source`. Supporting utilities enrich existing extractors (callback side-effects, behavioral config, AST-based source slicing, nested-namespace resolution) but are not themselves extractors and do not appear in the unit type enumeration. The authoritative mapping is `Woods::Extractor::TYPE_TO_EXTRACTOR_KEY` in `lib/woods/extractor.rb`.

---

## How do extractors work?

### The five phases

A full extraction (`bundle exec rake woods:extract`) runs five phases:

```
Phase 1: Extract    . All 35 extractors run, producing ExtractedUnit objects
Phase 1.5: Dedupe   . Re-derived same-source duplicates are dropped; a same-type identifier still derived from two different files aborts extraction naming both files
Phase 2: Resolve    . Reverse dependency edges are built (A depends on B → B gets a dependent)
Phase 3: Enrich     . Git metadata added (last author, change frequency, recent commits) and copied onto graph nodes
Phase 4: Graph      . PageRank + structural analysis (orphans, hubs, cycles, bridges, cross-database edges)
Phase 5: Write      . One JSON file per unit, _index.json per type, dependency_graph.json, SUMMARY.md
```

### Two discovery strategies

Extractors discover code one of two ways:

| Strategy | How it works | Examples |
|----------|-------------|---------|
| **Class-based** | `ActiveRecord::Base.descendants`, `ApplicationController.descendants`, etc., requires `eager_load!` | ModelExtractor, ControllerExtractor, MailerExtractor |
| **File-based** | Scans conventional directories (`app/services`, `db/migrate`, etc.), more robust for non-AR classes | ServiceExtractor, MigrationExtractor, ViewTemplateExtractor |

Some extractors combine both (e.g., `JobExtractor` scans directories first, then supplements with `ApplicationJob.descendants`).

Discovery is not exhaustive. Woods 2.0.0 does not discover callable standalone
modules under `app/models` through its model/PORO paths. The unreleased
[standalone-module support](#poroextractor) addresses that case; conventional
concerns and app modules included by live models retain concern ownership.
Dependency scanning also remains partial, including with the source-reference
pass below. A missing unit or edge is not proof of unused code; cross-check the
application source.

### Constant source references

**Unreleased after Woods 2.0.0; planned for 2.1.** For Git/path installations,
record the loaded gem path and exact revision; the development version alone
does not establish that this change is installed.

After discovery and deduplication, extraction adds `code_reference` relationships
from models, controllers, services, POROs, library units and concerns to verified,
indexed class/module targets. It parses original Ruby source and attributes reads
to their declaring owner. Ordinary method bodies, singleton methods and callback
blocks participate. Comments, plain strings and declaration names do not establish
references. Rails relationships derived through runtime reflection stay intact.

Resolution respects qualified names and supported lexical/runtime context.
Dynamic constant lookup, uncertain aliases, ambiguous typed identities and
unsupported scopes remain unresolved. In particular, references inside
`class << self` are recorded as candidates but currently skipped during resolution;
ordinary `def self.method` bodies are supported. A source reference does not prove
execution, and an absent edge does not prove there are no callers. The internal cache retains parsed candidates, their scope, and collector skip
reasons; it does not establish complete reference coverage.

Forward edges and reverse relationships publish together. Incremental extraction
and targeted refresh reconsider cached references when targets appear, disappear
or change resolution, including references in unchanged callers. Larger recorded
dependency sets can increase the incremental blast radius; no separate limit is
applied to these edges. See [source-reference baseline and upgrades](INCREMENTAL_EXTRACTION.md#source-reference-baseline-and-upgrades).

### Identifier naming (source-derived units)

File-based extractors derive an identifier in three steps, first match wins:

1. **Zeitwerk-governed naming.** For a file under a managed autoload path, the expected constant path comes from its owning Rails loader (`main` or `once`), including that loader's inflections, root namespace, collapsed directories and ignored paths. Without loader information, the offline path convention applies. The source must declare exactly the expected constant: `app/services/domain/container/parser.rb` is expected to define `Domain::Container::Parser`. This is what lets a file whose namespaces are written as *classes* (`module Domain; class Container; class Parser`) name the file's own constant instead of the wrapper `Domain::Container`, which every sibling under the same wrapper would otherwise collide with.
2. **Position-aware nesting scan** (`SourceNesting`, the supporting utility above). The first `class` declaration qualified by the namespaces actually open at that position. Compact declarations keep their segments; a helper module nested inside the class and sibling modules that closed earlier do not contribute.
3. **Path convention.** Camelize the path under `app/<kind>/` (details vary per extractor).

Unmanaged paths (`lib/` unless configured for autoloading, and configured non-autoload roots) and sources that declare nothing matching the expected constant skip step 1 entirely: the source scan and path convention decide. A namespace file containing only `Acme::VERSION` does not acquire an invented `Acme::Version` declaration.

Once-loader ownership (#579) is an unreleased correction after Woods `2.0.0`; verify the loaded revision as well as the gem version. It covers declared constants under `config.autoload_lib_once` and other once-managed roots. Direct ownership across both loaders takes precedence over copied-application inference; ambiguous roots and a loader's explicit non-claim remain unmanaged. After upgrading an affected index, run one full extraction before resuming incremental maintenance to replace stale wrapper identifiers. This does not aggregate multiple unmanaged source files reopening the same namespace.

### Eager loading

The orchestrator calls `Rails.application.eager_load!` once before extraction begins. If that fails with a `NameError` (common when `app/graphql/` references an uninstalled gem), it falls back to per-directory loading via `EXTRACTION_DIRECTORIES`. This fallback covers the directories that matter for extraction.

### What every extractor returns

Every extractor returns `Array<ExtractedUnit>`. An `ExtractedUnit` is a self-contained snapshot of one code unit with source, metadata, and relationships. See [ExtractedUnit Field Reference](#extractedunit-field-reference) at the bottom of this doc.

---

## Core application extractors

### ModelExtractor

**What it captures:** Every non-abstract `ActiveRecord::Base` descendant with concrete table-backed state. The source_code is the model's actual Ruby source *plus* all included concerns inlined below it as formatted comment blocks. Schema information (columns, types, indexes, foreign keys) is prepended as a header comment.

**Key details:**
- Uses `ActiveRecord::Base.descendants` for discovery (runtime introspection, not static parsing)
- Named, source-defined app model mixins (for example `Card::Pinnable` in `app/models/card/pinnable.rb`) resolve through runtime source locations, with conventional concern paths as fallbacks. Included mixins also receive `:concern` units, so their actual files map to the includer through dependency edges. Gem-owned modules stay outside this discovery. Conventional concern files retain their existing identity even when nested helpers share the same file. Outside those directories, each included runtime mixin receives its own concern identity even when several share a source file; editing that file refreshes every includer.
- Inlines concerns: all `include FooConcern` references are resolved and the concern source is appended to `source_code`. Inlined concern names are recorded in `metadata[:inlined_concerns]`
- Reads Rails' per-event callback chains (`_save_callbacks`, `_create_callbacks`, and the other lifecycle events), preserving each chain's order and each entry's `kind`, filter and conditions. The public `type` combines kind and event, such as `before_save` or `after_create`; Rails' separate `before_commit` event is reported as `before_commit`, not `before_before_commit`. `callback_count` equals the emitted callback list's length. The list includes framework-registered callbacks; it is runtime metadata, not an application-only filter or a cross-event execution trace. Regenerate the index after upgrading to pick up corrected callback metadata.
- Proc/lambda filters, including Rails-generated association callbacks, use stable source-site labels in both metadata and callback chunks: `#<Proc app/models/post.rb:12>` (or `lambda`). App paths are relative to `Rails.root`; external paths are retained and native procs use `native`. Rails 6's numeric filter identity is resolved through `raw_filter`. These labels describe location and callable kind, not captured closure state; callbacks are never executed. Model condition labels retain their existing format.
- Default callback-object representations omit process addresses: an instance becomes `#<CleanupCallback>`, an anonymous class becomes `#<Class>`, and its instance becomes `#<#<Class>>`. Anonymous namespace prefixes are normalized too (for example, `#<Module>::CleanupCallback`). Named classes and custom `to_s` labels retain their text. These labels do not distinguish arbitrary object state; separate registered callbacks remain separate entries even when their descriptive labels match. Controller object-filter formatting is unchanged.
- Direct Proc/lambda validation option values (for example inclusion/exclusion membership or message callables) use the same stable kind/source-site labels without execution. Validation order and duplicates, condition formats (`if`, `unless`, `on`), and non-Proc values are unchanged. Nested arrays/hashes are not recursively normalized, and labels do not serialize captured closure state. Run a full extraction after upgrading to refresh retained validation metadata; the stored schema is unchanged.
- Callback side-effects are analyzed via `CallbackAnalyzer`: detects columns written (`self.col =`), jobs enqueued (`perform_later`), and services called
- Reflects model class and instance methods after reading the schema, so Rails schema-loading optimizations produce the same method metadata in cold and warmed runs. Application-defined constructors remain visible; Rails versions that install an optimized singleton `new` during schema loading consistently include it in `class_methods`.
- Automatically skips HABTM join models and anonymous classes
- Chunks every model into semantic sections: `:summary`, `:associations`, `:callbacks`, `:validations`, `:scopes`, `:methods`
- **Runtime-generated method detection:** Because extraction runs inside a booted Rails process, `instance_methods(false)` captures every method Rails generates dynamically, enum predicates (`status_active?`, `status_pending?`), association builders (`build_profile`, `create_line_item!`), attribute accessors, and dynamically registered scopes. Static analysis tools cannot see these methods because they only exist after Rails processes the DSL declarations at boot time
- **Database partition (multi-DB apps).** `metadata[:database]` is `klass.connection_db_config.name` (Rails 6.1+; `nil` on 6.0). Because reflection climbs to the abstract class that declared `connects_to`, a concrete model that only inherits its connection still reports the right database. Each association entry carries `from_db`, `to_db`, `through_db` (the has_many :through join model's database, guarded the same way and nil for a plain association), and `disable_joins`; `metadata[:foreign_keys]` lists `{ from_table, to_table, column }`, the target table's owning database is resolved separately by the graph-level `cross_database_edges` report (see [Internals](INTERNALS.md#graphanalyzer-structural-metrics)), not stored per model. That report never picks an owner living in the foreign key's own source database, even when another database also claims the table; only when every owner sits elsewhere, across more than one database, does it come back ambiguous rather than guessing. The graph node carries `database`, `table`, and `foreign_key_tables`, and association edges carry `through`, `through_db`, and `disable_joins`. `consolidate_dependencies` keeps the first edge per `[type, target]`, so a model with two associations to the same target keeps only the first edge's `through`/`through_db`/`disable_joins`.

**Multi-database configuration Woods reads.** Woods needs nothing beyond the Rails configuration the app already has. Both shapes below produce `metadata[:database]` values of `primary` and `analytics`.

MySQL:

```yaml
# config/database.yml
production:
  primary:
    adapter: mysql2
    database: shop_production
  analytics:
    adapter: mysql2
    database: shop_analytics_production
    migrations_paths: db/analytics_migrate
```

PostgreSQL:

```yaml
# config/database.yml
production:
  primary:
    adapter: postgresql
    database: shop_production
  analytics:
    adapter: postgresql
    database: shop_analytics_production
    migrations_paths: db/analytics_migrate
```

```ruby
# app/models/analytics_record.rb
class AnalyticsRecord < ApplicationRecord
  self.abstract_class = true
  connects_to database: { writing: :analytics, reading: :analytics }
end

class PageView < AnalyticsRecord; end   # metadata[:database] => "analytics"
```

**Edge cases:**
- STI subclasses are extracted separately from their parent (each has its own identifier)
- `callback.options` was removed in Rails 4.2, the extractor uses `@if`/`@unless` ivars and ActionFilter duck-typing to extract `:only`/`:except` action lists
- AR-generated internal methods (like `autosave_associated_records_for_comments`) are filtered by a single combined regex to avoid noise

**Example output (abbreviated):**

```json
{
  "type": "model",
  "identifier": "Order",
  "file_path": "app/models/order.rb",
  "namespace": null,
  "source_code": "# == Schema Information\n# id :bigint\n# user_id :bigint\n# status :string\n# total_cents :integer\n#\nclass Order < ApplicationRecord\n  belongs_to :user\n  has_many :line_items\n  ...\nend\n\n# ┌───────────────────────────────────────────────────────────────────┐\n# │ Included from: Auditable                                          │\n# └───────────────────────────────────────────────────────────────────┘\n#   module Auditable\n#     ...\n#   end\n# ──────────────────────── End Auditable ────────────────────────────",
  "metadata": {
    "database": "primary",
    "associations": [
      { "type": "belongs_to", "name": "user", "target": "User", "from_db": "primary", "to_db": "primary", "disable_joins": false },
      { "type": "has_many", "name": "line_items", "target": "LineItem" }
    ],
    "callbacks": [
      { "type": "before_save", "filter": "calculate_total", "kind": "before", "conditions": {},
        "side_effects": { "columns_written": ["total_cents"], "jobs_enqueued": [], "services_called": [], "mailers_triggered": [], "database_reads": [], "operations": [] } },
      { "type": "after_commit", "filter": "send_confirmation_email", "kind": "after", "conditions": {},
        "side_effects": { "columns_written": [], "jobs_enqueued": ["OrderConfirmationJob"], "services_called": [], "mailers_triggered": ["OrderMailer"], "database_reads": [], "operations": [] } }
    ],
    "validations": [
      { "attribute": "status", "type": "inclusion", "options": { "in": ["pending", "paid", "shipped"] }, "conditions": {} }
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

**What it captures:** Every `ApplicationController` and `ActionController::API` descendant. Route context is prepended to the source, each controller gets a header block showing which HTTP verb + path maps to each action. Before/after filter chains are resolved per action.

**Key details:**
- Discovers controllers via `ApplicationController.descendants` (and `ActionController::API.descendants` if present)
- Builds a routes map from `Rails.application.routes` at initialization time
- Route context is inlined in `source_code` as a comment header, not just in metadata
- Chunks per-action: each action becomes a `:action` chunk with its applicable filters and route
- Metadata includes permitted params (strong parameters), response formats, and applied filters per action
- Inline callbacks use stable source-site labels in filter metadata, controller annotations and action chunks: `#<Proc app/controllers/posts_controller.rb:12>` (or `lambda`). The controller filter metadata and annotations use the same labels for `if`/`unless` procs. App paths are relative to `Rails.root`; external paths are retained and native procs use `native`. Labels describe the callable location and kind, not captured closure state, and never execute callbacks.
- Route helper resolution accepts every live named controller/action route, including `file_path`, `image_url`, `download_path`, and `root_path`. Unknown filesystem/asset helpers produce no edge; matching names are conservative source references, not proof a call executes.
- Extracts `redirect_to` navigation edges: named route helpers (`posts_path`, `users_url`) are resolved to controller targets via `RouteHelperResolver`, producing `:redirect_to` dependency edges (gated by `extract_navigation_edges` config)

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

**What it captures:** Service objects, interactors, operations, commands, and use cases, the "business logic layer." Discovers them by scanning conventional directories for Ruby files.

**Key details:**
- Scans: `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`
- Extracts public entry points (`call`, `perform`, `execute`, `run`), custom error classes, and dependency references
- File-based discovery (not class introspection), so it catches services with non-standard superclasses
- `initialize_params` describes declared names, default presence and keyword status from Ruby syntax. Nested/comma-bearing defaults are not evaluated or treated as parameters; named rest, keyword-rest and block parameters retain their names. Anonymous forwarding has no name to report; malformed source produces an empty parameter list.

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
- `perform_params` uses the same syntax-aware signature parsing as service initializers and preserves its `name`, `splat` (`single`/`double`/null), and `has_default` fields. Keyword defaults do not invent additional argument names.
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
- **Unreleased after 2.0.0:** discovers all app-owned `ActionMailer::Base.descendants`, including parallel abstract bases and direct subclasses even when `ApplicationMailer` exists. An app without ActionMailer contributes no mailer units.
- Discovery and direct extraction accept only mailers backed by an existing app-owned source file, excluding dependency mailers and fabricated convention paths.
- Each mailer action corresponds to an email template, template paths are recorded in metadata
- Extracts `default from:`, `layout`, and per-action subject patterns
- Action names are sorted consistently in metadata, the generated header, template discovery and action chunks. Callback chain order and duplicate registrations are preserved.
- Direct Proc-valued defaults and Proc callback filters use source-location/kind labels without executing them; application paths are relative to `Rails.root`. Default containers, literal strings and non-Proc values retain their existing types. This does not serialize closure captures or recursively normalize arbitrary nested objects.
- Object callback filters use descriptive labels with addresses removed only from Ruby's default representation, including anonymous classes and namespaces. Custom labels and literal hexadecimal text are preserved. Labels do not serialize callback object state, and extraction never invokes callbacks.
- After upgrading, run a full extraction to refresh retained mailer units. Stabilized headers and callable labels can cause a one-time source-hash change; stored index schemas are unchanged.

---

### ConfigurationExtractor

**What it captures:** Rails initializers (`config/initializers/**/*.rb`) and environment files (`config/environments/*.rb`). Also extracts a behavioral profile from the resolved `Rails.application.config` values at runtime.

**Key details:**
- `BehavioralProfile` introspects live config using `respond_to?`/`defined?` guards, a missing config section produces `nil`, not an error
- Captures: asset pipeline config, middleware additions, cache store, logger config, and custom initializer logic
- One unit per config file, plus one special `:behavioral_profile` unit per environment

---

### RouteExtractor

**What it captures:** Every route in the Rails routing table via `Rails.application.routes.routes`. Each route becomes its own `ExtractedUnit`.

**Key details:**
- Pure runtime introspection, reads the live routing table, not `config/routes.rb` AST
- Each unit's identifier is `"VERB /path"` (e.g., `"POST /orders"`)
- A route with request constraints is qualified: `"GET /users [subdomain=api]"`, `"GET /users [format=json]"`, `"GET /users [constraint=proc]"` for a callable. Path-segment requirements (`id: /\d+/`) do not qualify
- Routes that still share an identifier are numbered in route order (`"GET /users #2"`) so none are dropped
- Records controller, action, route name, and constraints
- Since routes don't map to individual files, incremental re-extraction re-runs `RouteExtractor` wholesale whenever `config/routes.rb` changes, it isn't skipped, just not diffed per file

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
- Records middleware class names, insertion order, and initialization arguments as readable strings
- Argument rendering preserves literal strings and nested array/hash configuration. Procs use source locations; anonymous classes (including Ruby temporary names used by Rails executors/reloaders) use parent names and method source locations. Opaque objects using Ruby's default `to_s` are represented by class, without walking private runtime state. Custom `to_s` output is preserved, so application-defined nondeterministic renderers can still vary. Closure captures and opaque object internals are not serialized.
- No per-file mapping, so incremental re-extraction re-runs `MiddlewareExtractor` wholesale when `config/application.rb`, `Gemfile.lock`, or a file under `config/initializers`/`config/environments` changes

---

## UI component extractors

### PhlexExtractor

**Unreleased after 2.0.0:** discovery and direct extraction require an existing app-owned source file; dependency components are excluded.

**What it captures:** Phlex component classes (`Phlex::HTML`, `Phlex::SVG` subclasses) from `app/components`. Extracts slots, initialize parameters, sub-component references, Stimulus controller names, and route helper usage.

**Key details:**
- Phlex components render pure Ruby, no template files to parse separately
- Slots and sub-component composition are extracted from the `view_template` method

---

### ViewComponentExtractor

**Unreleased after 2.0.0:** discovery and direct extraction require an existing app-owned source file and runtime ancestry; dependency components are excluded.

**What it captures:** ViewComponent classes from `app/components`. Extracts slots, template paths, preview class references, and collection rendering support.

**Key details:**
- Template path is inferred from the component file name (e.g., `ButtonComponent` → `button_component.html.erb`)
- **Unreleased after 2.0.0:** `metadata.sidecar_template` uses an application-relative path, such as `app/components/button_component.html.erb`. Detection still checks the actual file under `Rails.root`; extracting from another checkout does not change this metadata. Re-extract existing component units to update their stored paths.
- Preview class associations are extracted when `<ComponentName>Preview` is found in `spec/components/previews/` or `test/components/previews/`

**Edge cases:**
- Phlex and ViewComponent both scan `app/components`, the orchestrator uses separate extractors for each. A Phlex component won't be extracted by ViewComponentExtractor and vice versa (the filtering is by superclass, not file name)

---

### ViewTemplateExtractor

**What it captures:** ERB view templates from `app/views`. Extracts render calls (partials and components), instance variable references, and helper method usage.

**Key details:**
- File-based scanning, no Rails boot needed for the actual file reading
- Records which partials a template renders and which instance variables it expects
- Loads the runtime route collection before caching named helpers, including Rails lazy route sets. Fresh-process incremental view extraction resolves the same navigation targets as full extraction.
- Extracts navigation dependencies: `link_to` and `form_with`/`form_for` calls using `_path`/`_url` route helpers are resolved to controller targets via `RouteHelperResolver`
- Navigation edges use `:link_to` and `:form_action` via types in the dependency array
- Gated by `extract_navigation_edges` config (default: true)

**Template engine coverage.** ERB only as a parsed template engine, HAML, Slim, and Turbo Streams are not parsed at all; an app using HAML or Slim as its primary view engine gets zero view-layer coverage from this extractor. Stimulus controller *references* are a partial exception: `PhlexExtractor` and `ViewComponentExtractor` scan `data-controller` attributes in their component source and emit `:stimulus_controller` dependency edges, the target Stimulus controller files under `app/javascript/controllers/` are not themselves parsed or extracted. The MCP `structure` tool surfaces the supported engine list via the `template_engines` field. The pluggable `Woods::Extractors::ViewEngines::Base` protocol and the `ViewTemplateExtractor::ENGINES` registry shipped with issue #110, HAML / Slim / Turbo implementations become plug-in additions: subclass `Base`, implement `name` / `extensions` / the three `scan_*` methods / `resolve_partial_identifier`, and append the class to `ENGINES`.

---

### DecoratorExtractor

**What it captures:** Decorator, presenter, and form object classes from `app/decorators`, `app/presenters`, and `app/form_objects`.

**Key details:**
- These directories are also added to `EXTRACTION_DIRECTORIES` for eager loading
- Extracts delegated methods, wrapped model class, and custom presentation methods

---

## Data layer extractors

### ConcernExtractor

**What it captures:** `ActiveSupport::Concern` modules from `app/models/concerns` and `app/controllers/concerns`.

**Key details:**
- Scans: `app/models/concerns`, `app/controllers/concerns`
- Extracts included hooks, `ClassMethods` block, instance methods, and class methods added by the concern
- Dependencies on models and other concerns are tracked
- Note: concerns are *also* inlined into model/controller source by ModelExtractor and ControllerExtractor. ConcernExtractor produces standalone units for direct lookup

---

### PoroExtractor

**What it captures:** Plain Ruby objects in `app/models` that are not ActiveRecord (non-AR classes, excluding concerns). Supporting unreleased writers also discover callable standalone modules as described below.

**Key details:**
- Scans `app/models` for files that don't define an `ActiveRecord::Base` descendant
- Common examples: value objects, form objects placed in `app/models`, domain structs
- Excludes concerns (those go to ConcernExtractor)
- `parent_class` and the generated Parent annotation describe the selected unit declaration only. Nested or sibling classes cannot supply its parent. An implicit `Object` parent, a dynamic superclass expression, or unparseable source produces `nil`; explicit constant-path parents retain their source names.

#### Assigned value classes

**Unreleased after Woods 2.0.0; planned for 2.1.** Direct assignments such as
`Criteria = Struct.new(:value)` and `Page = Data.define(:items)` can own a PORO
unit inside class or module namespace wrappers. Discovery uses the active
loader's expected constant where available, then verifies the loaded class,
core factory, ancestry and canonical assignment file. For example, a reopened
`Products::Search` containing `Criteria = Struct.new(...)` in its child file
produces `Products::Search::Criteria`, not another `Products::Search` unit.

The same verified naming applies to [library files](#libextractor). Shadowed
factories, aliases, arbitrary `Class.new` assignments and unloaded nested value
classes are not promoted by this check. Existing top-level named-Struct lookup
identities remain compatible, but an alias is not a verified reference target.
A callable canonical module sharing the file retains its own PORO unit. Library
extraction preserves its canonical primary module when it matches the file's
identity or has its own methods defined there; namespace-only child-file wrappers
do not displace the assigned child. An assigned class can be the target of a
`code_reference` edge, but references inside its Struct/Data constructor block
remain unsupported because the block does not establish ordinary lexical class
nesting. Woods does not execute the constructor or its method bodies.

Run a **full extraction** after upgrading the writer. It repairs older wrapper
identities and rebuilds the source-reference cache in format 3; incremental
extraction refuses format 1 even when source files are unchanged. Existing
readers can continue serving the last published index until the full extraction
succeeds. Genuine collisions between different files still refuse publication.

**Standalone modules — unreleased after Woods 2.0.0; planned for 2.1.** A named,
loaded module whose canonical declaration and own methods are defined under
`app/models` can produce a `poro` unit with `metadata.ruby_kind: "module"` and
`parent_class: null`. This includes `def self.method`, `module_function`,
`class << self` methods and plain instance-method mixins. Discovery uses runtime
ownership and source locations without calling those methods.

Namespace-only wrappers, aliases, unloaded constants, gem-owned modules and
methods supplied only by another file do not establish standalone ownership.
An app module included by a live model belongs to `ConcernExtractor`; a library
module remains owned by `LibExtractor`. Separate callable modules sharing a
source file retain their own identities. Ordinary class PORO identifiers stay unchanged.

Incremental extraction and model/PORO/concern refreshes reconcile ownership when
an includer changes even if the module's file does not. Incomplete eager loading
cannot prove that a former concern became standalone or that an undiscovered
module disappeared. Those units remain retained unless positive ownership
evidence supersedes them; changed source for a retained unit refuses publication
until a complete run can re-extract it.

Module discovery and reference resolution are separate: a module with
`class << self` methods can be indexed even though references inside that scope
remain unresolved by the [constant-reference pass](#constant-source-references).
Run a full extraction when upgrading to establish the new units and their
reference cache; updating only the reader does not add them.

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

**Unreleased after Woods 2.0.0:** after eager loading, discovery checks the
selected class's actual delegator ancestry and source ownership. Application
base classes and leading `::` therefore work without changing the unit identity;
an unrelated or foreign same-named class cannot supply that proof. When the class
is unavailable, the extractor retains its limited direct-declaration fallback
without triggering autoloads. `delegation_type` reflects resolved SimpleDelegator
ancestry; unknown delegation mechanisms remain `unknown`.

---

## API & authorization extractors

### GraphQLExtractor

**What it captures:** graphql-ruby schemas, types, mutations, queries, and resolvers. Produces four distinct unit types from one extractor.

**Unreleased after Woods 2.0.0; planned for 2.1:** the discovery fixes below require the corresponding Git/path revision; the development version alone does not establish availability.

**Key details:**
- Scans every current, named application `GraphQL::Schema` subclass and unions their runtime type inventories by canonical Ruby constant name. Distinct Ruby classes can share a schema-local GraphQL name. A type used as the query root of any schema has one `graphql_query` identity.
- Produces unit types: `graphql_type`, `graphql_mutation`, `graphql_resolver`, `graphql_query`. Schema classes use `graphql_type` with `metadata.graphql_kind: "schema"`; their source includes configuration such as `max_complexity` for lookup and source search.
- Scans governed declarations in `app/graphql`, including unattached resolvers. Loaded declarations qualify through GraphQL ancestry, so application superclass chains, leading `::`, and superclass whitespace do not affect discovery. Reflection reads schema/type metadata without executing field or resolver bodies.
- When graphql-ruby or a declaration is unavailable, file discovery retains its limited recognized-source-form fallback; it cannot establish arbitrary application superclass ancestry. Woods does not trigger pending declaration autoloads itself.
- Extracts field metadata (types, descriptions, complexity, arguments), authorization patterns (Pundit, CanCan, `authorized?`), and dependencies on models/services
- Incremental extraction handles changed files and runtime inventory additions, and reclassifies an unchanged type when its query-root role changes. Runtime inventory absence alone does not delete units: unattached file-defined resolvers remain valid, and runtime-only removals still require a full extraction or `woods:refresh[graphql]` after the application reloads.
- A failed schema inventory logs the schema name and stops full, incremental, or refresh publication; the prior generation remains active. Fix the introspection error and retry the complete extraction batch.
- If application eager loading is incomplete, incremental extraction and refresh refuse a change to an existing GraphQL unit's kind rather than demoting a query root whose schema might not have loaded. Retry after a complete application boot.
- Runtime source locations take precedence over convention-named files. Initializer-built `Class.new` schemas/types can be indexed, but this does not add method-body `code_reference` ownership for generated declarations; see [source-reference coverage](#constant-source-references).
- `parent_class` and summary chunks describe the selected declaration's explicit constant-path superclass, preserving its written qualification. Nested or sibling declarations and literal text cannot supply a parent. Implicit Object, module interfaces, dynamic superclass expressions, unavailable source, and invalid source have no declared parent (`null` metadata; `unknown` in summaries). This is source declaration metadata, not resolved runtime ancestry.

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

**Unreleased after Woods 2.0.0:** a loaded policy's actual ApplicationPolicy
ancestry, including namespaced and intermediate application bases, establishes
Pundit inheritance. The selected constant must belong to the source being read;
aliases and foreign same-named classes do not qualify. Without a loaded class,
direct ApplicationPolicy declarations and the existing user/record conventions
remain supported. Woods does not invoke pending autoloads to classify a policy.
The generic PolicyExtractor retains its existing policy units and applies the
same ancestry correction to `metadata.is_pundit`.

---

### PolicyExtractor

**What it captures:** Policy classes with decision methods and eligibility rules, including plain Ruby objects used for authorization decisions.

**Key details:**
- Scans `app/policies`; `metadata.is_pundit` identifies recognized Pundit-style classes
- Extracts public predicate methods and their dependencies

---

## Infrastructure extractors

### EngineExtractor

**What it captures:** Mounted Rails engines via runtime introspection. Records mount points and route counts for each engine.

**Key details:**
- Uses `Rails::Engine.subclasses` at runtime, finds both gem-mounted and in-repo engines
- Engine units don't map to individual files, so incremental re-extraction re-runs `EngineExtractor` wholesale when `config/routes.rb` or `Gemfile.lock` changes
- A mounted engine may duplicate some routes; the deduplication phase handles this

---

### PackageExtractor

**What it captures:** Packwerk / pks package boundaries from every `package.yml`, one unit per package. No Rails boot is needed for the read itself.

**Key details:**
- Identifier is the package directory relative to `Rails.root` (`.` for the root package), the same name Packwerk uses
- Honors `packwerk.yml` `package_paths` and `exclude`; without one, `**/` with the Packwerk default excludes (`bin`, `node_modules`, `script`, `tmp`, `vendor`)
- With those exact defaults, excluded top-level directories are pruned before discovery descends into them, so an index or snapshots under `tmp/` do not add package-scan work. Custom patterns or exclusions retain their configured glob behavior. Hidden directories and symlink directories are not recursively followed by default.
- `metadata`: `name`, `dependencies` (sorted), `enforce_dependencies` (`true`, `false`, or `"strict"`), `enforce_privacy`, `layer` (pks), `public_path`, `owner`
- Each declared dependency becomes a `{ type: :package, target: <name>, via: :package_dependency }` edge
- Package membership on other units (`metadata[:package]`, below) does not depend on how a unit was discovered: any registered unit with a file path under a package root is annotated. The undeclared cross-package edge report remains a follow-up, not this extractor. Discovery is the separate open gap: a pack-resident file-based unit is not yet found by `PathDispatcher` when only its `package.yml` changes (follow-up B-175), so it carries no membership only because it has no unit at all yet, not because membership skips it
- Woods does not enforce anything. `pks check` and `packwerk check` own enforcement; Woods shows the boundary before an agent writes the cross-package call
- Whole-app: any `package.yml` or `packwerk.yml` change re-runs the extractor wholesale

**Example output (abbreviated):**

```json
{
  "type": "package",
  "identifier": "packs/billing",
  "file_path": "packs/billing/package.yml",
  "metadata": {
    "name": "packs/billing",
    "dependencies": [".", "packs/accounts"],
    "enforce_dependencies": "strict",
    "layer": "product",
    "owner": "billing-team"
  },
  "dependencies": [
    { "type": "package", "target": ".", "via": "package_dependency" },
    { "type": "package", "target": "packs/accounts", "via": "package_dependency" }
  ]
}
```

#### Package membership

Every single-file app-owned unit under a package root carries `metadata[:package]` with the package name (longest root wins; `.` when only a root package exists). Framework sources and units with no path never carry it. The graph node carries the same value as `package`. When a `package.yml` changes, an incremental run re-annotates every unit whose package changed in the same run, so `metadata[:package]` never lags behind the file that defines it.

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
- Discovers via `ActionCable::Channel::Base.descendants`. **Unreleased after 2.0.0:** discovery and direct extraction exclude dependency-owned source files.
- Records stream names, authentication checks in `subscribed`, and any `broadcast_to` calls

---

### ScheduledJobExtractor

**Unreleased after 2.0.0:** unique schedule names retain `scheduled:<name>`.
Names shared across scheduler formats become `scheduled:<format>:<name>`, with
a deterministic suffix if that identifier is already a literal task name.
`metadata.task_name` preserves the original name. Ambiguous names within one
format refuse publication; the last generation stays usable. Run a full
extraction to remove dependency-owned components/channels and reconcile these
expanded mailer and schedule identities in an existing index.


**What it captures:** Scheduled job definitions from cron-style config files. Supports multiple scheduling backends.

**Key details:**
- Reads: `config/recurring.yml` (Solid Queue), `config/sidekiq_cron.yml` (Sidekiq Cron), `config/schedule.rb` (Whenever)
- Extracts job class name, cron expression, queue, and any arguments
- Resolves trusted application `recurring.yml` through Rails' configuration loader,
  including ERB, filename-relative `require_relative`, and YAML aliases. On Rails
  6.0 (before that loader existed), evaluates ERB with its filename and retains
  safe YAML loading of scalars, hashes, arrays and symbols. ERB runs application
  code in the extraction process; index only applications you trust.
- Environment-wrapped task maps select the current Rails environment, including
  custom names; an absent environment falls back to the first section, while an
  explicitly empty section stays empty. Flat task maps remain supported.
- Sidekiq-Cron remains safe-loaded YAML; Whenever remains a static DSL scan.
  Invalid YAML/ERB, missing required files and runtime configuration errors are
  logged and omit that schedule file. Source remains the original file text.
- No per-file mapping, so incremental re-extraction re-runs `ScheduledJobExtractor` wholesale whenever one of the schedule files above changes

---

### RakeTaskExtractor

**What it captures:** Rake tasks from `lib/tasks/*.rake`. Extracts namespaces, task names, descriptions, prerequisites (`:depends_on`), and the task body.

**Key details:**
- Reads `.rake` files statically, no Rails boot required for parsing
- Uses `block_opener?` for depth tracking; `if`/`unless` only match at line start to avoid counting trailing modifiers as blocks
- Supports nested namespaces (`namespace :data do namespace :import do task :users`)
- A task reopened in more than one `.rake` file is one unit, as Rake sees it: the source carries every definition, `metadata.defined_in` lists the files, and a per-file incremental run yields the same merged unit as a full run

---

### MigrationExtractor

**What it captures:** ActiveRecord migration files from `db/migrate`. Extracts DDL metadata, affected tables, risk indicators, and reversibility.

**Key details:**
- Scans `db/migrate/*.rb`
- Extracts: tables created/dropped/modified, columns added/removed, indexes, references
- Risk indicators: data migrations (manual SQL or bulk updates), irreversible operations (`remove_column` without type), `execute` calls with raw SQL
- Rails internal tables (`schema_migrations`, `active_storage_blobs`, etc.) are excluded from model dependency links

**Unreleased after Woods 2.0.0:** migration identity comes from the actual Ruby
declaration, with the filename's conventional class name selecting among eligible
declarations. Helper classes and closed sibling namespaces cannot rename a
migration or contribute unrelated DDL metadata. Qualified declaration receivers
use verified lexical namespace ownership, including an existing outer or root
namespace; Woods does not prepend the syntactic nesting blindly. A namespace
established earlier in the same source can supply structural evidence. Unknown
receivers, pending autoloads, and unavailable lexical constant tables produce an
explicit ownership diagnostic rather than an invented identity. Leading
`::ActiveRecord::Migration` remains supported. A custom migration base requires
already-loaded runtime ancestry or a same-file structural chain to
ActiveRecord::Migration; unknown custom bases are not guessed. Historical files
are never required or evaluated for discovery. Ambiguous declarations produce an
explicit extraction error, and duplicate identities across files retain the
normal collision guard. Run a full extraction after upgrading to replace any
previously misidentified migration units.

If a qualified receiver cannot be verified, define its namespace before the
declaration in the same source, or make that namespace available through normal
application boot. Use a leading `::` when the receiver intentionally belongs to
the root namespace. Woods will not load a historical migration to discover its
namespace.

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
- Incremental re-extraction re-runs `DatabaseViewExtractor` wholesale on any `.sql` change under `db/views`, a per-file dispatch could index a version a full extraction drops

---

### StateMachineExtractor

**What it captures:** State machine DSL definitions using AASM, Statesman, or the `state_machines` gem.

**Key details:**
- Detects literal DSL declarations in model source; it does not evaluate the DSL or run callbacks
- Extracts states, events, transitions, guard conditions, and callbacks from supported source forms; it does not claim complete dynamic or inherited registry coverage
- **Unreleased after 2.0.0:** directly declared `state_machines` calls in the selected model class support the default `state` attribute (`state_machine initial: :pending do`), explicit attributes, and parenthesized calls, including multiline arguments. The default produces `Model::state_machine_state`; existing named identifiers remain `Model::state_machine_<attribute>`. Each declaration uses its own block and literal initial state, keeping multiple machines separate. Nested/sibling classes, singleton scopes and deferred/receiver blocks cannot supply another model's machine. Dynamic attribute expressions are not guessed, and dynamic initial-state functions are not called.
- Returns an array from the file method (like `ScheduledJobExtractor`), cannot be used in the incremental file-based dispatch map; incremental re-extraction re-runs it wholesale on any `.rb` change under the model directories it scans

---

### EventExtractor

**What it captures:** Event publish/subscribe patterns using `ActiveSupport::Notifications` or Wisper.

**Key details:**
- Two-pass approach: first collects all `publish`/`instrument` calls, then `subscribe`/`on` calls, then merges them
- No single-file extraction method, incremental re-extraction re-runs `EventExtractor` wholesale on any `.rb` change under `app/` (a publish or subscribe site can appear anywhere)
- Useful for tracing event-driven flows: "what subscribes to order.created?"
- **Unreleased after 2.0.0:** app-owned `metadata.publishers` and `metadata.subscribers` paths, and the same paths in generated source annotations, are relative to `Rails.root`. Their array order, counts and event identifiers stay unchanged. Explicitly scanned paths outside the application remain absolute. Re-extract event units after upgrading: removing the checkout prefix changes existing `source_hash` values once, then identical app sources produce the same annotations and hashes across checkout roots.

---

### CachingExtractor

**What it captures:** Cache usage patterns across controllers, models, and ERB view templates.

**Key details:**
- Scans controllers, models, and `.erb` view files
- Extracts: `cache` blocks, `Rails.cache.fetch`, `expire_fragment`, TTLs, and cache keys
- The `file_type` parameter on `extract_caching_file` defaults to `nil` (auto-detected from path)

---

## Testing & source extractors

### FactoryExtractor

**What it captures:** FactoryBot factory definitions including traits, associations, and lazy attribute blocks.

**Key details:**
- Scans `spec/factories` and `test/factories`
- Produces one unit per factory definition (including trait sub-factories)
- Useful for understanding test data structure and available factory combinations
- No per-file mapping, so incremental re-extraction re-runs `FactoryExtractor` wholesale on any `.rb` change under the factory directories

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

**What it captures:** Ruby files from `lib/`, utility modules, standalone libraries, and infrastructure code.

**Key details:**
- Excludes `lib/tasks/` (covered by RakeTaskExtractor) and `lib/generators/`
- File-based scanning; no assumption about class hierarchy
- `parent_class` and the generated Parent annotation describe the selected unit declaration only. Nested or sibling classes cannot supply its parent. An implicit `Object` parent, a dynamic superclass expression, or unparseable source produces `nil`; explicit constant-path parents retain their source names.

**Unreleased after 2.0.0:** compatible reopened library classes/modules across
files form one typed unit. Matching inferred names alone are insufficient:
conflicting declaration kinds/parents, unresolved constructors and aliases still
refuse ambiguous ownership. Extraction does not require or execute unmanaged
files. The sorted first path remains the compatibility `file_path`; it is a
primary display path, not a claim that every definition resides there.

Aggregates add `metadata.source_contributors_version: 1`, `source_contributors`,
and sorted `defined_in`. Each contributor records its own path, raw-file SHA256,
physical line range and half-open byte range inside the published composite.
Generated headers/separators lie outside those ranges. Per-file facts remain
separate; sorted paths do not establish runtime override order. The unit's
`source_hash` describes the composite. One-file units retain their prior shape.

The graph maps every contributor to the typed owner. Any relevant library edit,
deletion or dependency-triggered refresh reconciles the complete library family
once per batch; direct file extraction also returns the aggregate. This costs
more than re-reading only the primary file, and preserves full/incremental facts.
A contributor read failure prevents publishing a partial aggregate. Supporting
unreleased writers read library source explicitly as UTF-8 regardless of the
process locale; invalid UTF-8 is logged with the physical source path and still
prevents a partial aggregate.

Git facts remain per contributor: Woods does not fabricate a summed aggregate
commit count or churn rank. A unit-level package is emitted only when every
contributor belongs to the same package. Retrieval package/path scopes require
**all** contributors to match, avoiding disclosure of out-of-scope source.
Run one full extraction after upgrading: source-reference cache format 3 must
be rebuilt, and existing indexes do not yet contain contributor provenance.

Loaded Struct/Data assignments use the [assigned value-class ownership rules](#assigned-value-classes)
to avoid naming sibling files after their shared namespace wrapper.

---

### RailsSourceExtractor

**What it captures:** High-value Rails framework source and gem source files, pinned to the exact versions in `Gemfile.lock`.

**Key details:**
- Reads from `Gem.loaded_specs`, paths depend on the installed gem location
- Indexes selected paths from: `activerecord` (associations, callbacks, validations, relation, enum, transactions), `actionpack` (controller metal, callbacks, rendering, redirecting), `activesupport` (callbacks, concern, configurable, delegation)
- `config.add_gem` is accepted but not implemented; only the fixed framework path list is indexed
- This is what makes framework-specific queries accurate: "what options does `has_many` support?" returns the actual source for the installed Rails version

---

## How do I enable or disable extractors?

You can't, today. All 35 extractors always run during a full extraction, there is no opt-in/opt-out mechanism and nothing in the extraction path reads
`config.extractors`. The array is accepted for forward compatibility: setting
it to anything other than its default value emits a warning and has no
effect on which extractors run or what the retrieval pipeline sees.
Extractor selection is a documented future knob, not a shipped feature.

`config.add_gem` is in the same state: accepted with a warning, not read by
`RailsSourceExtractor`. There is no shipped way to widen the framework path list.

---

## ExtractedUnit field reference

Every extractor produces `ExtractedUnit` objects with this schema:

| Field | Type | Description |
|-------|------|-------------|
| `type` | Symbol | Unit category, one of the 39 types in `Woods::Extractor::TYPE_TO_EXTRACTOR_KEY`: `:model`, `:controller`, `:service`, `:job`, `:mailer`, `:component`, `:view_component`, `:graphql_type`, `:graphql_mutation`, `:graphql_resolver`, `:graphql_query`, `:serializer`, `:manager`, `:policy`, `:validator`, `:concern`, `:route`, `:middleware`, `:i18n`, `:pundit_policy`, `:configuration`, `:engine`, `:view_template`, `:migration`, `:action_cable_channel`, `:scheduled_job`, `:rake_task`, `:state_machine`, `:event`, `:decorator`, `:database_view`, `:caching`, `:factory`, `:test_mapping`, `:rails_source`, `:gem_source`, `:poro`, `:lib`, `:package` |
| `identifier` | String | Unique key for this unit. Usually the class name (e.g., `"User"`, `"OrdersController"`) or a descriptive string for non-class units (e.g., `"POST /orders"`) |
| `file_path` | String | Relative path to the source file (e.g., `"app/models/user.rb"`). Relative to `Rails.root` after normalization. A gem-owned unit (an engine model such as `ActiveStorage::Blob`, a framework source) keeps its absolute gem path, since nothing under `Rails.root` defines it. |
| `namespace` | String\|nil | Module namespace if the class is nested (e.g., `"Admin"` for `Admin::DashboardController`) |
| `source_code` | String | The full source code, potentially enriched: models have concerns inlined and schema prepended; controllers have a route context header prepended |
| `metadata` | Hash | Type-specific structured data, associations, callbacks, actions, fields, etc. Keys and structure vary by extractor. Model units add `database`, `foreign_keys`, and per-association `from_db`/`to_db`/`disable_joins` (#280). Any app-owned unit under a Packwerk package adds `package` (#280) |
| `dependencies` | Array\<Hash\> | Forward edges: `[{ type: :model, target: "User", via: "belongs_to" }, ...]` |
| `dependents` | Array\<Hash\> | Reverse edges: **populated in Phase 2 (Resolve)**, not Phase 1 (Extract). After Phase 2 every field on a unit is effectively immutable. Shape: `[{ type: :controller, identifier: "OrdersController" }, ...]` |
| `chunks` | Array\<Hash\> | Semantic sub-sections for large units. Each chunk: `{ chunk_index:, identifier:, content:, content_hash:, estimated_tokens: }` |
| `estimated_tokens` | Integer | Approximate token count for `source_code + metadata.to_json` using 4.0 chars/token. Computed, not stored. |

### Serialized JSON fields

When written to disk, units also include:

| Field | Description |
|-------|-------------|
| `extracted_at` | ISO 8601 timestamp of extraction |
| `source_hash` | SHA-256 of `source_code` for change detection |

### Git enrichment fields (`metadata[:git]`)

If the host app is a git repo, the following are added to `metadata[:git]` after extraction.
History is limited to commits reachable from `HEAD` in the past 365 days,
including merged branch history. Unmerged branches, remote refs, and tool
checkpoint refs do not contribute. Commands run against the application root;
when `WOODS_GIT_DIR` is set, `HEAD` belongs to that explicitly selected git
directory. For a linked worktree, select its `worktrees/<id>` directory within
the complete shared Git layout; selecting the shared root instead uses the
primary checkout's HEAD. See the [worktree mount guide](TROUBLESHOOTING.md#git-directory-mounts-for-linked-worktrees).

After upgrading from a version that included all refs, run a full
`woods:extract` to replace previously published git metadata. Incremental
extraction refreshes only the units it rewrites. A commit alone does not
necessarily trigger the source-file watcher; run full extraction when current
Git history is required.

| Field | Description |
|-------|-------------|
| `last_modified` | ISO 8601 date of last commit touching this file |
| `last_author` | Name of the author who last modified the file |
| `commit_count` | Total commit count for this file (past 365 days) |
| `contributors` | Top 5 contributors by commit count: `[{ name:, commits: }]` |
| `recent_commits` | Last 5 commits: `[{ sha:, message:, date:, author: }]` |
| `change_frequency` | `:new`, `:hot`, `:active`, `:stable`, or `:dormant` |

### Full example JSON

```json
{
  "type": "model",
  "identifier": "User",
  "file_path": "app/models/user.rb",
  "namespace": null,
  "source_code": "# == Schema Information\n# id :bigint not null, pk\n# email :string not null\n# created_at :datetime\n#\nclass User < ApplicationRecord\n  has_many :orders\n  validates :email, presence: true, uniqueness: true\nend\n\n# ┌───────────────────────────────────────────────────────────────────┐\n# │ Included from: Searchable                                         │\n# └───────────────────────────────────────────────────────────────────┘\n#   module Searchable\n#     extend ActiveSupport::Concern\n#     ...\n#   end\n# ──────────────────────── End Searchable ───────────────────────────",
  "metadata": {
    "associations": [{ "type": "has_many", "name": "orders", "target": "Order" }],
    "validations": [{ "attribute": "email", "type": "presence", "options": {}, "conditions": {} }, { "attribute": "email", "type": "uniqueness", "options": {}, "conditions": {} }],
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
