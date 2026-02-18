# CodebaseIndex Coverage Gap Analysis: Technical Review

We analyzed the 15 unextracted Rails concepts against the needs of three distinct practitioner roles to determine which gaps matter most and which are overrated. CodebaseIndex currently covers 24 extractors producing `ExtractedUnit` objects across models, controllers, jobs, mailers, GraphQL, components, services, policies, validators, serializers, managers, concerns, routes, middleware, I18n, Pundit policies, configurations, engines, view templates, migrations, ActionCable channels, scheduled jobs, and Rails source. Extraction also includes behavioral enrichment: callback side-effect analysis, a behavioral profile of resolved `Rails.application.config` values, and optional pre-computed request flow maps. This review identifies the 8-10 highest-value gaps, ordered by cross-role demand, unique value, and feasibility within the existing architecture.

## Implementation Status

Since this analysis was written, all 8 ranked gaps have been addressed:

| Gap | Status | Extractor |
|-----|--------|-----------|
| Concerns | **Done** | `ConcernExtractor` — scans `app/*/concerns/` |
| Routes | **Done** | `RouteExtractor` — `Rails.application.routes` introspection |
| Middleware | **Done** | `MiddlewareExtractor` — `Rails.application.middleware` introspection |
| I18n | **Done** | `I18nExtractor` — YAML parsing of `config/locales/` |
| Pundit | **Done** | `PunditExtractor` — Pundit authorization policies |
| Configuration | **Partial** | `ConfigurationExtractor` (file scanning) + `BehavioralProfile` (runtime config introspection). Semantic parsing of heterogeneous initializer content remains. |
| View templates | **Done** | `ViewTemplateExtractor` — ERB MVP, scans `app/views/**/*.erb` |
| Engines | **Done** | `EngineExtractor` — `Rails::Engine.subclasses` introspection |

Additionally, **behavioral depth** enrichment was added: callback side-effect analysis (`CallbackAnalyzer`), resolved config introspection (`BehavioralProfile`), and pre-computed request flow maps (`FlowPrecomputer`).

The per-perspective analysis below reflects the original gap assessment. See the [Synthesized Priority Ranking](#synthesized-priority-ranking) for current status.

---

The existing extractor infrastructure — `SharedDependencyScanner`, `SharedUtilityMethods`, `ExtractedUnit`, the dependency graph with PageRank, and the 21-tool MCP server — provides a well-defined insertion point for new extractors. Most gaps fall into two categories: (1) file-based extractors that follow the `ServiceExtractor` pattern (directory scan, source read, metadata extraction), and (2) runtime-introspection extractors that follow the `ModelExtractor` pattern (class hierarchy traversal, reflection APIs).

---

## Methodology

We examined:

- All 13 existing extractors in `~/work/codebase_index/lib/codebase_index/extractors/` to understand the interface contract
- The orchestrator at `~/work/codebase_index/lib/codebase_index/extractor.rb` (lines 43-79) for `EXTRACTORS`, `TYPE_TO_EXTRACTOR_KEY`, `CLASS_BASED`, and `FILE_BASED` dispatch maps
- `SharedDependencyScanner` at `~/work/codebase_index/lib/codebase_index/extractors/shared_dependency_scanner.rb` for dependency infrastructure
- `DependencyGraph` at `~/work/codebase_index/lib/codebase_index/dependency_graph.rb` for graph integration requirements
- `QueryClassifier` at `~/work/codebase_index/lib/codebase_index/retrieval/query_classifier.rb` for retrieval integration
- The `EXTRACTION_DIRECTORIES` constant (extractor.rb, line 46-63) for the current eager-load fallback scope
- The MCP server at `~/work/codebase_index/lib/codebase_index/mcp/server.rb` for tool surface area
- Existing docs in `~/work/codebase_index/docs/` for architectural constraints

Each gap was evaluated for: (a) concrete use-case frequency, (b) whether the information is available elsewhere or uniquely requires CodebaseIndex's runtime introspection, and (c) implementation effort given the existing extractor contract.

---

## Perspective 1: Senior Rails Developer

*Daily work: building features, debugging production issues, onboarding to unfamiliar codebases.*

### Top 5 Missing Use Cases

**1. View Templates (ERB/HAML/Slim)**

This is the single biggest gap for day-to-day work. When debugging why a page renders incorrectly, you need the controller action, the template, the partials it renders, and the helpers it calls. CodebaseIndex gives you the controller but drops you at the edge of the rendering layer.

Concrete scenario: "Why does the users/show page show stale data?" requires tracing from `UsersController#show` through `app/views/users/show.html.erb` into `_profile_card.html.erb` into `_avatar.html.erb`. Without view extraction, you have controller context but no rendering context.

Why it matters for onboarding: views are where Rails conventions are most chaotic. Partials nest 3-4 levels deep, helpers are defined across multiple modules, and the naming conventions that map controllers to views are implicit. A developer new to the codebase needs the view graph to orient.

What makes it hard: view templates are not Ruby classes. They require static parsing (ERB/HAML/Slim grammar), not runtime introspection. The extractor would need to handle `render partial:`, `render collection:`, `render template:`, local variable passing, layout inheritance, and helper method resolution. This is medium-large effort because it is a fundamentally different extraction approach.

**Effort:** Large (40-60 hours). Template parsing, partial resolution, helper tracking.
**Dependencies:** New parsing infrastructure (not Prism-based — templates are not Ruby ASTs). Would benefit from a dedicated view dependency graph linking controllers to templates to partials.

**2. Routes as Standalone Units**

Routes are currently embedded as metadata in controller extraction (via `build_routes_map` in `ControllerExtractor`). But when debugging "what URL hits what code?", you need routes as a first-class queryable index, not metadata nested inside controller units.

Concrete scenario: "What happens when someone hits `POST /api/v2/webhooks/stripe`?" Today you need to know the controller name first, then look it up. With route units, you could search by path pattern.

Concrete scenario: "Why is `/admin/reports/:id` returning 404?" Namespace routing (engines, scope blocks, constraints) is the #1 source of routing confusion. A route-level extractor would capture constraints, scopes, and middleware — context currently invisible to CodebaseIndex.

**Effort:** Small (8-12 hours). `Rails.application.routes.routes` provides everything via runtime introspection. The data is already partially computed by `ControllerExtractor#build_routes_map`.
**Dependencies:** None new. Extends the existing runtime introspection pattern.

**3. Configuration and Initializers** *(partially addressed)*

When debugging production issues, configuration is frequently the root cause. "Why is the cache returning nil?" is often answered by `config/initializers/cache_store.rb` or `config/environments/production.rb`.

**What's now covered:** `BehavioralProfile` introspects resolved `Rails.application.config` values at runtime — database adapter, active frameworks, behavior flags (api_only, strong_params_action, etc.), job adapter, cache store, email config. `ConfigurationExtractor` scans `config/initializers/` and `config/environments/` files as source units.

**Remaining gap:** Raw initializer files that register middleware, patch classes, or configure third-party gems are extracted as source but not semantically parsed. Questions like "is CORS configured?" require reading initializer source rather than querying structured metadata.

**Effort:** Medium (16-24 hours) for the remaining semantic parsing of heterogeneous initializer files.
**Dependencies:** None. Extends the existing `ConfigurationExtractor`.

**4. Concerns as Standalone Units**

Concerns are inlined into models and controllers today, which is correct for understanding a specific model. But when debugging "which models use the `Auditable` concern and what does it actually do?", you need the concern as its own unit with its own dependents list.

Concrete scenario: "I changed the `Searchable` concern — what breaks?" Today, the dependency graph has no node for `Searchable` itself, so `affected_by` cannot compute the blast radius of a concern change.

**Effort:** Small-Medium (12-20 hours). The concern source is already being read and cached (`@concern_cache` in `ModelExtractor`). The extractor would reuse that cache and create standalone units for each concern, plus register them in the dependency graph.
**Dependencies:** Requires changes to `ModelExtractor` and `ControllerExtractor` to emit concern dependency edges pointing at the standalone concern units instead of (or in addition to) inlining.

**5. Stimulus Controllers / Hotwire JavaScript**

Modern Rails apps (Rails 7+) use Stimulus for JavaScript. When debugging "why doesn't this dropdown work?", you need the Stimulus controller that handles the DOM event. These live in `app/javascript/controllers/` and have a well-defined structure (`connect()`, `targets`, `values`, `actions`).

Concrete scenario: "What JavaScript runs when the user clicks 'Submit' on the order form?" The answer is a Stimulus controller wired via `data-controller` attributes in a template. Without extracting Stimulus controllers, the entire frontend behavior layer is invisible.

**Effort:** Medium (16-24 hours). Stimulus controllers follow strict conventions (file naming, class structure). Parsing is straightforward JavaScript/TypeScript AST work. The challenge is connecting Stimulus controllers to the templates that wire them.
**Dependencies:** Maximally useful when combined with view template extraction (gap #1), but valuable standalone for understanding the JS layer.

---

## Perspective 2: Tech Lead / Architect

*PR review, refactor planning, technical debt evaluation, architectural decision-making.*

### Top 5 Missing Use Cases

**1. Concerns as Standalone Units (shared with Perspective 1)**

For architects, the concern gap is about **architectural visibility**. Concerns are Rails' primary code-sharing mechanism, and understanding concern usage patterns reveals architectural health. A concern included by 30 models is a god-concern. A concern included by 1 model is pointless indirection.

Concrete scenario: tech debt audit asks "which concerns are over-used, which are orphaned, and which have circular dependencies?" Today, `GraphAnalyzer` cannot answer this because concerns are inlined rather than graphed.

Concern extraction would immediately plug into `GraphAnalyzer`'s hub detection, orphan detection, and cycle detection — providing architectural insights that are currently blind to the concern layer.

**Effort:** Small-Medium (12-20 hours).
**Dependencies:** Same as Perspective 1 analysis.

**2. Middleware Chain**

Middleware is the invisible layer between the router and the controller. When reviewing PRs that add authentication, rate limiting, CORS, or request logging, the architect needs to see the full middleware stack and understand ordering.

Concrete scenario: "Why are healthcheck endpoints hitting the database?" Because a middleware inserted before the router initializes a database connection. You cannot diagnose this without seeing the middleware chain.

Concrete scenario: "Is our rate limiter running before or after authentication?" Middleware ordering bugs are subtle and hard to detect in PR review. A middleware extractor that captures the ordered stack with source locations would make these visible.

What makes this valuable: `Rails.application.middleware` provides the full stack via runtime introspection. No parsing needed. The runtime data includes class names, arguments, and insertion order.

**Effort:** Small (6-10 hours). Pure runtime introspection via `Rails.application.middleware`. The middleware stack is a simple ordered list.
**Dependencies:** None. Simplest possible extractor pattern.

**3. Routes as Standalone Units (shared with Perspective 1)**

For architects, routes matter differently: they reveal API surface area, versioning strategy, and namespace organization. "How many v1 vs v2 endpoints exist?" and "which routes lack authentication?" are architectural questions that require routes as first-class units.

The route extractor would also capture constraints, which are architecturally significant (API versioning via headers, subdomain routing, format restrictions).

**Effort:** Small (8-12 hours).
**Dependencies:** Same as Perspective 1 analysis.

**4. Engines and Mountable Gems**

Production Rails apps frequently use engines (Devise, ActiveAdmin, Sidekiq Web, custom internal engines). These mount entire route trees and middleware stacks that are invisible to the current extraction. When planning upgrades or security audits, architects need to know what engines are mounted and what they expose.

Concrete scenario: "What routes does Sidekiq Web expose, and is it behind authentication?" Today, the index has no knowledge of mounted engines. The architect must manually inspect `config/routes.rb` and trace the engine's source.

What makes this valuable: `Rails::Engine.subclasses` provides the list, and `engine.routes.routes` gives the route tree. This is pure runtime introspection.

**Effort:** Medium (16-24 hours). Engine discovery is simple. The challenge is deciding how deep to go — extracting engine routes is straightforward, but extracting engine models/controllers creates a scope explosion.
**Dependencies:** Benefits from route extraction (gap #2 from Perspective 1). Engine routes would be units that link to the engine's namespace.

**5. Database Migrations as Code Units**

Schema is already extracted via `ActiveRecord::Base` reflection, which gives the current state. But architects need migration history to understand schema evolution: "When was the `orders` table last changed?" and "What migration added the `metadata` JSONB column?" and "Are there any pending migrations that could cause deployment issues?"

Concrete scenario: upgrade planning requires understanding which migrations are irreversible, which touch large tables (risky in production), and which have data backfills that might conflict with new code.

**Effort:** Medium (16-24 hours). File-based scanning of `db/migrate/` is simple. Metadata extraction (up/down methods, table/column changes, reversibility) requires source parsing. `ActiveRecord::Base.connection.migration_context` provides runtime status.
**Dependencies:** None. Follows the file-based extractor pattern.

---

## Perspective 3: AI/LLM Tool Builder

*Building coding assistants, code generation tools. Wants maximum context for accurate generation, needs to understand how code connects.*

### Top 5 Missing Use Cases

**1. View Templates (shared with Perspective 1)**

For AI tools, the view layer gap creates a fundamental context problem. When generating code for a feature, the AI needs to produce the controller action, the model changes, the service logic, AND the view template. Without view context, generated templates will use incorrect partial names, wrong helper methods, and mismatched local variables.

What makes this uniquely valuable: unlike models and controllers (which have well-known Rails conventions an LLM can guess at), view templates are almost entirely app-specific. Partial names, layout structure, component usage, and helper methods are unpredictable without extraction. This is the gap where AI tools make the most errors.

The view extractor's dependency edges (controller -> template -> partials -> helpers) would also be the highest-value addition to the dependency graph for code generation. Today the graph ends at the controller. With views, the graph extends through the full request cycle.

**Effort:** Large (40-60 hours).
**Dependencies:** Same as Perspective 1 analysis.

**2. Concerns as Standalone Units (shared with all perspectives)**

For AI code generation, the concern gap creates incorrect modification suggestions. When an AI is asked to "add soft-delete to the User model", it needs to know whether a `SoftDeletable` concern already exists, what it provides, and which models use it. Without concern units in the index, the AI might recreate functionality that already exists in a concern, or miss that the concern handles the exact feature being requested.

The inlined concern source is available in model units, but the AI cannot search for "which concern provides soft-delete?" because concerns are not indexed as searchable units. `QueryClassifier` has no `concern` target type.

**Effort:** Small-Medium (12-20 hours).
**Dependencies:** Would require adding `:concern` to `QueryClassifier::TARGET_PATTERNS` and `ExtractedUnit` type vocabulary.

**3. Configuration and Initializers (shared with Perspective 1)**

AI tools generating code need to know the app's configuration to produce correct code. "Add Redis caching to the ProductController" requires knowing whether the app uses Redis, Memcached, or file-based caching — and what the cache store configuration looks like. "Add a webhook endpoint" requires knowing whether the app has CORS configured, what authentication middleware is in place, and whether there are API-specific base controllers.

Without configuration context, AI tools generate code against assumed defaults rather than the app's actual setup. This produces working-but-wrong code that conflicts with existing configuration.

**Effort:** Medium (16-24 hours).
**Dependencies:** Same as Perspective 1 analysis.

**4. I18n Translations**

For AI code generation in internationalized apps, the I18n gap causes incorrect string handling. When generating a new view or mailer, the AI needs to know whether the app uses I18n (many Rails apps do not), what the key structure looks like, and what translations already exist.

Concrete scenario: AI generates `<h1>Welcome</h1>` when the app convention is `<h1><%= t('.welcome') %></h1>`. Or it generates `t('users.show.welcome')` when the existing convention uses `t('.welcome')` (relative keys). Without I18n context, every generated view and mailer has string-handling errors.

What makes this feasible: YAML files have a trivial parse structure. The extractor would index locale files as units with key paths as metadata.

**Effort:** Small (6-10 hours). YAML parsing of `config/locales/` with key-path indexing.
**Dependencies:** None. The simplest possible extractor — no Ruby parsing, no runtime introspection, just YAML traversal.

**5. Pundit Authorization Policies**

CodebaseIndex extracts generic "policy" classes (business rule classes), but does not specifically extract Pundit authorization policies — the most common authorization pattern in Rails. For AI code generation, authorization context is critical: "Add an admin-only endpoint" requires knowing the app's authorization pattern, existing policy classes, and how policies map to controllers.

Concrete scenario: AI generates a controller action without authorization because it does not know the app uses Pundit. Or it generates `authorize @post` when the app's convention is `authorize @post, :admin_update?` with custom policy methods.

What makes this straightforward: Pundit policies follow strict conventions (`app/policies/`, class naming matches model naming, standard method interface `index?`, `show?`, `create?`, etc.). Runtime introspection via `Pundit.policy` mapping provides the authorization graph.

**Effort:** Small (8-12 hours). Extends the existing `PolicyExtractor` or creates a parallel `PunditExtractor`.
**Dependencies:** Would link to model units (policy -> model) and controller units (controller -> policy). Requires detecting whether Pundit is installed (`defined?(Pundit)`).

---

## Synthesized Priority Ranking

Ranked by: (1) how many perspectives value it, (2) unique value (cannot easily get this elsewhere), (3) feasibility given existing architecture.

| Rank | Gap | Status | Perspectives | Unique Value | Effort | Rationale |
|------|-----|--------|-------------|-------------|--------|-----------|
| 1 | **Concerns as standalone units** | **Done** | All 3 | High | — | `ConcernExtractor` scans `app/*/concerns/`, 19 specs. |
| 2 | **Routes as standalone units** | **Done** | 2 of 3 (Dev, Architect) | High | — | `RouteExtractor` uses `Rails.application.routes`, 16 specs. |
| 3 | **View templates** | **Done** | 2 of 3 (Dev, AI) | Very High | — | `ViewTemplateExtractor` — ERB MVP with render call, instance variable, and helper extraction. 24 specs. |
| 4 | **Configuration/Initializers** | **Partial** | 2 of 3 (Dev, AI) | Medium | Medium (16-24h remaining) | `ConfigurationExtractor` scans initializer/environment files (16 specs). `BehavioralProfile` introspects resolved config values (43 specs). Remaining: semantic parsing of heterogeneous initializer content. |
| 5 | **Middleware chain** | **Done** | 1 of 3 (Architect) | Very High | — | `MiddlewareExtractor` uses `Rails.application.middleware`, 10 specs. |
| 6 | **I18n translations** | **Done** | 1 of 3 (AI) | Medium | — | `I18nExtractor` parses `config/locales/` YAML, 14 specs. |
| 7 | **Pundit authorization policies** | **Done** | 1 of 3 (AI) | Medium | — | `PunditExtractor`, 17 specs. |
| 8 | **Engines/mountable gems** | **Done** | 1 of 3 (Architect) | High | — | `EngineExtractor` — runtime introspection via `Rails::Engine.subclasses`. Mount path, route count, isolate_namespace. 18 specs. |

### What Didn't Make the Cut (and Why)

**Stimulus/Hotwire JavaScript** (Perspective 1, #5): Valuable but requires JavaScript/TypeScript parsing — a fundamentally different toolchain from Ruby. The ROI is lower than Ruby-side gaps because CodebaseIndex's core strength is runtime introspection, which does not apply to frontend assets. If the tool expands to frontend, this should be a separate extraction pipeline, not bolted onto the Ruby extractors.

**Database migrations** (Perspective 2, #5): **Now Done.** `MigrationExtractor` scans `db/migrate/*.rb`, extracting DDL metadata (tables, columns, indexes, references), reversibility, risk indicators (data migrations, raw SQL), and model dependencies via table name classification. 55 specs.

**Rake tasks** (from the original list): Rarely queried. Most rake tasks are thin wrappers around service objects or direct ActiveRecord calls. The service extractor already captures the logic that matters.

**ActionCable channels** (from the original list): **Now Done.** `ActionCableExtractor` uses runtime introspection via `ActionCable::Channel::Base.descendants`. Extracts stream subscriptions, actions, broadcast patterns. 29 specs.

**ActiveStorage/ActionText** (from the original list): Configuration-level concerns already partially covered by model association extraction (`has_one_attached`, `has_rich_text` show up in model metadata). A dedicated extractor adds little over what model extraction provides.

**Scheduled job definitions** (from the original list): **Now Done.** `ScheduledJobExtractor` parses three formats: Solid Queue (`config/recurring.yml`), Sidekiq-Cron (`config/sidekiq_cron.yml`), and Whenever (`config/schedule.rb`). One unit per scheduled entry with cron expression, job class, and human-readable frequency. 45 specs.

---

## Gotchas

- **View template parsing is not Prism.** The existing AST layer (`~/work/codebase_index/lib/codebase_index/ast/`) is Prism-based and handles Ruby source. ERB/HAML/Slim templates require dedicated parsers (`erubi` for ERB, `haml` gem for HAML, `slim` gem for Slim). Each template engine is a separate dependency and parsing path. This is why views are ranked #3 despite highest unique value — the implementation cost is discontinuous with other extractors.

- **Concern extraction changes the dependency graph semantics.** Today, model units have dependencies on other models, services, jobs, etc. Adding concern units means models would depend on concerns, and concerns would depend on models. This creates a new class of edges in the graph. `GraphAnalyzer`'s hub/cycle detection would need testing against this new topology to ensure the metrics remain meaningful.

- **Route extraction must handle engine-mounted routes.** If routes and engines are both extracted, there is a design decision about whether engine routes appear as children of the engine unit or as standalone route units. This needs to be resolved before implementing either extractor.

- **`EXTRACTION_DIRECTORIES`** (extractor.rb, line 46-63) currently does not include `app/views/` or `config/`. Adding view or config extraction requires updating this constant for the eager-load fallback path — though views and config do not contain autoloadable Ruby classes, so the update is a no-op functionally. The real change is adding new entries to the `EXTRACTORS` hash (line 65-79) and the dispatch maps.

- **`QueryClassifier::TARGET_PATTERNS`** needs updates for each new unit type. Concerns, routes, middleware, I18n, Pundit, and configuration patterns have been added. Views and engines still need entries when implemented.

---

## Suggested Implementation Order

All 8 original priority gaps are complete. The 3 "Didn't Make the Cut" items (Database Migrations, ActionCable Channels, Scheduled Jobs) are also now implemented, bringing the total to **24 extractors**.

Remaining gap work:

1. **Configuration semantic parsing** (~16-24 hours). `ConfigurationExtractor` and `BehavioralProfile` cover file scanning and runtime introspection. Remaining: semantic parsing of heterogeneous initializer content for structured metadata.

2. **View template expansion** — HAML/Slim support, layout inheritance, partial dependency graphs. The ERB MVP is in place.

3. **Stimulus/Hotwire JavaScript** — frontend layer extraction, requires separate JS/TS parsing toolchain.
