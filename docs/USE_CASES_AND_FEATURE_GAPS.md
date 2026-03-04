# CodebaseIndex: Use Cases & Feature Gap Analysis

Comprehensive evaluation of CodebaseIndex's applicability to Rails applications and identification of remaining feature gaps. Based on analysis of all 32 extractors, the retrieval pipeline, both MCP servers (27 + 31 tools), the embedding/storage/chunking layers, AST analysis, flow tracing, resilience/observability infrastructure, and evaluation harness.

---

## Part 1: Use Cases for Rails Applications

### Category A: AI-Assisted Development

**A1. Context-Aware Code Generation**
An AI coding assistant (via MCP) retrieves the model schema, existing associations, callback side-effects, and related services before generating new code. This prevents the AI from recreating functionality already in a concern, using wrong association names, or conflicting with existing callbacks. The `codebase_retrieve` tool provides query-classified, RRF-ranked context within a token budget.

**A2. Feature Implementation Planning**
Before writing code for a new feature, an agent queries the dependency graph to understand blast radius. "Add soft-delete to Order" triggers lookups of Order's dependents (controllers, serializers, jobs, policies), callback chains, and associated models — producing a checklist of files that need changes. `dependencies` and `dependents` tools with BFS traversal provide this.

**A3. Pull Request Context Assembly**
Given a diff, the system computes `affected_by(changed_files)` via the bidirectional dependency graph to identify all transitively impacted units. This enables automated PR descriptions that explain downstream effects: "This change to `Auditable` concern affects 12 models, 3 controllers, and 2 serializers."

**A4. Code Review Assistance**
An AI reviewer uses the MCP index server to understand the architectural context of changes. For a PR modifying a callback, it retrieves `CallbackAnalyzer` side-effects (columns written, jobs enqueued, services called) and flags unexpected behavioral changes.

**A5. Codebase Q&A / Onboarding Chatbot**
New developers query the index in natural language: "How does order fulfillment work?" The retrieval pipeline classifies intent (`trace`), scope (`exploratory`), and target types, then assembles context from the Order model, FulfillmentService, fulfillment jobs, and mailer — formatted for the target LLM (Claude XML, GPT markdown, or human-readable).

**A6. Documentation Generation**
The extracted metadata (associations, callbacks, side-effects, route maps, filter chains) provides structured input for generating API documentation, model relationship diagrams, and architecture overviews. The `MermaidRenderer` already produces call graphs, dependency maps, and dataflow diagrams.

**A7. Test Generation**
AI test generators use extraction metadata to understand what needs testing: model validations, callback side-effects, controller filter chains, service entry points, and job retry configurations. The structured metadata answers "what should this test cover?" rather than requiring the AI to infer from raw source.

---

### Category B: Architecture & Technical Debt

**B1. Architectural Health Dashboard**
`GraphAnalyzer` detects orphans (dead code candidates), hubs (bottleneck models with 50+ dependents), cycles (circular dependencies), bridges (single points of failure), and dead-ends (leaf nodes). Combined with PageRank importance scoring, this produces a quantified architectural health report.

**B2. Dependency Impact Analysis**
Before refactoring a model or service, query `dependents` with depth control to see the full transitive impact. "If I change the User model, what controllers, serializers, jobs, and policies are affected?" The BFS traversal with type filtering answers this precisely.

**B3. Concern Usage Audit**
`ConcernExtractor` produces standalone units for every concern, and `GraphAnalyzer` can identify over-used concerns (hubs included by 30+ models), orphaned concerns (included by nothing), and circular concern dependencies. This directly supports refactoring decisions.

**B4. Migration Risk Assessment**
`MigrationExtractor` captures DDL metadata (tables affected, columns added/removed, indexes), reversibility, data migration detection, and raw SQL flags. This supports deployment risk evaluation: "Which pending migrations touch large tables or include irreversible operations?"

**B5. API Surface Area Analysis**
`RouteExtractor` + `ControllerExtractor` together provide the complete API surface: every endpoint, its HTTP method, path parameters, constraints, controller action, filter chain, permitted params, and response formats. This supports API versioning audits, security reviews, and deprecation planning.

**B6. Callback Chain Auditing**
`CallbackAnalyzer` detects side-effects of model callbacks: which columns are written, which jobs are enqueued, which services are called, which mailers are triggered, and which database reads occur. This answers "what hidden behavior happens when I save a User?" — the #1 source of unexpected bugs in Rails.

**B7. Configuration Drift Detection**
`BehavioralProfile` introspects resolved `Rails.application.config` at runtime (database adapter, active frameworks, behavior flags, job adapter, cache store, email delivery). Combined with `ConfigurationExtractor`'s file scanning, this detects discrepancies between what's configured in files and what's actually resolved at runtime.

**B8. Engine & Middleware Visibility**
`EngineExtractor` surfaces mounted engines (Devise, ActiveAdmin, Sidekiq Web) with their route counts and mount paths. `MiddlewareExtractor` captures the ordered middleware stack. Together they answer "what's running between the request and my controller?" — critical for security audits and performance debugging.

---

### Category C: Debugging & Incident Response

**C1. Request Flow Tracing**
`FlowPrecomputer` generates per-action request flow maps: for each controller action, it traces the execution path through filters, service calls, model operations, and responses. The `trace_flow` MCP tool exposes this. "What happens when POST /orders is called?" returns the complete execution sequence.

**C2. Production Data Exploration (Console MCP)**
The 31-tool Console MCP server provides safe, read-only access to production data:
- `console_sample` / `console_find` / `console_pluck` for data inspection
- `console_diagnose_model` for multi-query model health checks
- `console_data_snapshot` for record + associations (depth control)
- `console_slow_endpoints` / `console_error_rates` / `console_throughput` for performance metrics
- `console_job_queues` / `console_job_failures` for background job health
- `console_redis_info` / `console_cache_stats` for infrastructure status
- All wrapped in rolled-back transactions (`SafeContext`) with SQL validation

**C3. "What Changed?" Analysis**
`recent_changes` MCP tool surfaces units modified recently by git timestamp. Combined with `affected_by(changed_files)` in the dependency graph, this answers "what changed in the last deploy and what could it have broken?"

**C4. Authorization Debugging**
`PunditExtractor` extracts authorization policies with their decision methods. `console_check_policy` lets you test "can user X perform action Y on resource Z?" against the live system. Together they support debugging "why is this user getting 403?"

**C5. Data Validation Debugging**
`console_validate_record` runs validations on existing records. `console_validate_with` validates hypothetical attributes without persisting. `ValidatorExtractor` provides the validation rules, error messages, and conditions. This supports debugging "why won't this record save?"

**C6. Job Queue Triage**
`JobExtractor` + `ScheduledJobExtractor` provide the job definitions (queue, retry config, concurrency controls). Console tools (`console_job_queues`, `console_job_failures`, `console_job_find`, `console_job_schedule`) provide live queue state. Together they support incident response: "Why is the email queue backed up?"

---

### Category D: Search & Retrieval

**D1. Semantic Codebase Search**
The retrieval pipeline supports 7 query intents (understand, locate, trace, debug, implement, compare, framework), 4 scopes (pinpoint, focused, exploratory, comprehensive), and hybrid search strategies (vector + keyword + graph). Results are ranked by 6 weighted signals including semantic similarity, keyword match, recency, PageRank importance, type match, and diversity.

**D2. Framework Source Lookup**
`RailsSourceExtractor` indexes Rails framework and gem source code for the exact versions in the app's Gemfile.lock. The `framework` MCP tool searches this index. "How does `has_many` work internally?" returns the actual ActiveRecord source from the installed version, not documentation that might be for a different version.

**D3. Pattern Search Across Types**
The `search` MCP tool supports pattern matching across identifiers, source code, and metadata with type filtering. "Find all services that call Stripe" searches service source code. "Find all models with soft-delete" searches model metadata for relevant scopes/concerns.

**D4. Graph-Based Exploration**
Starting from any unit, traverse forward dependencies ("what does Order depend on?") or reverse dependencies ("what depends on Order?") with configurable depth and type filtering. This supports exploratory understanding of unfamiliar code.

---

### Category E: Pipeline & Operations

**E1. Incremental Extraction**
Git-aware incremental extraction (`codebase_index:incremental`) re-extracts only changed files, using content hashing to skip unchanged units. This supports CI integration where the index is updated on every merge.

**E2. Embedding Pipeline Management**
`pipeline_extract`, `pipeline_embed`, `pipeline_status`, `pipeline_diagnose`, and `pipeline_repair` MCP tools provide full pipeline lifecycle management. `PipelineGuard` rate-limits operations (5-minute cooldown). `CircuitBreaker` protects against embedding provider failures.

**E3. Retrieval Quality Evaluation**
The evaluation harness (`Evaluator`, `QuerySet`, `BaselineRunner`, `Metrics`) measures retrieval quality: precision@k, recall, MRR, context completeness, and token efficiency. This supports tuning the retrieval pipeline and comparing against baselines (grep, random, file-level).

**E4. Feedback-Driven Improvement**
`FeedbackStore` collects retrieval quality ratings (1-5 scale) and gap reports (missing units). `GapDetector` mines patterns in low scores and frequently-missing units. MCP tools (`retrieval_rate`, `retrieval_report_gap`, `retrieval_explain`, `retrieval_suggest`) expose this loop.

**E5. Multi-Agent Coordination**
`PipelineLock` provides file-based mutual exclusion with stale lock detection (1-hour timeout), enabling multiple agents to safely share the extraction pipeline without conflicts.

**E6. Health Monitoring**
`HealthCheck` probes vector store, metadata store, and embedding provider status. `StructuredLogger` produces JSON-line logs with timestamps and structured fields. `Instrumentation` delegates to `ActiveSupport::Notifications` when available.

---

### Category F: Multi-Backend Deployment

**F1. Local Development (Zero Dependencies)**
`:local` preset: InMemory vector store + SQLite metadata + Ollama embeddings. No external services required. Suitable for individual developer machines.

**F2. PostgreSQL-Native Stack**
`:postgresql` preset: pgvector + SQLite + OpenAI. Leverages existing PostgreSQL infrastructure. HNSW indexing for fast similarity search. Suitable for Rails 8 standard deployments.

**F3. Docker/Self-Hosted Production**
`:production` preset: Qdrant + SQLite + OpenAI. Dedicated vector database for scale. Suitable for containerized deployments.

**F4. Fully Air-Gapped**
Qdrant + Ollama (nomic-embed-text). No external API calls. Suitable for regulated environments.

**F5. MySQL Compatibility**
All database-touching code handles MySQL and PostgreSQL differences. JSON querying, indexing, and CTE syntax are backend-aware.

---

### Category G: Specific Rails Ecosystem Coverage

**G1. GraphQL API Understanding**
`GraphQLExtractor` handles types, mutations, queries, resolvers, enums, unions, input objects, and interfaces. Captures fields, arguments, authorization patterns, and complexity settings. Supports both file-based and runtime introspection discovery.

**G2. ViewComponent & Phlex Support**
Both component frameworks are extracted with slots, initialize params, sidecar templates, preview classes, and Stimulus controller references. This supports modern Rails UI patterns.

**G3. Serializer Pattern Coverage**
`SerializerExtractor` handles ActiveModelSerializers, Blueprinter, and Draper decorators. Captures attributes, associations, views, and wrapped models.

**G4. ActionCable Channel Mapping**
`ActionCableExtractor` captures stream subscriptions, channel actions, and broadcast patterns. Supports understanding real-time features.

**G5. Scheduled Job Visibility**
`ScheduledJobExtractor` parses three schedule formats: Solid Queue (`recurring.yml`), Sidekiq-Cron (`sidekiq_cron.yml`), and Whenever (`schedule.rb`). Each scheduled entry becomes a unit linked to its job class.

**G6. I18n Coverage**
`I18nExtractor` parses locale YAML files and indexes key paths. Supports "does this translation key exist?" and "what keys are defined for this model?"

---

## Part 2: Feature Gaps

### Gap 1: HAML/Slim View Template Support (High Impact)

**Current state:** `ViewTemplateExtractor` handles ERB only.
**Gap:** Many production Rails apps use HAML or Slim exclusively. These apps get zero view layer coverage.
**Impact:** Complete blind spot for the rendering layer in HAML/Slim apps. AI tools cannot generate views matching the app's template engine.
**Suggested approach:** Add `haml` and `slim` gem parsers alongside the existing ERB extraction. The metadata schema (partials rendered, instance variables, helpers) is identical — only the parsing differs.

### Gap 2: Stimulus/Hotwire Frontend Extraction (High Impact)

**Current state:** No JavaScript/TypeScript extraction exists.
**Gap:** Modern Rails 7+ apps use Stimulus controllers for all frontend interactivity. `data-controller` attributes in templates reference controllers in `app/javascript/controllers/`. This entire layer is invisible.
**Impact:** The dependency graph ends at the template layer. "What happens when the user clicks Submit?" cannot be answered. AI tools generate Stimulus controller references blindly.
**Suggested approach:** A dedicated JS/TS extractor using a JavaScript AST parser (e.g., `acorn` or `esbuild` via subprocess). Stimulus controllers have strict conventions: `connect()`, `targets`, `values`, `actions`. The parser would also link `data-controller` attributes in extracted view templates to their Stimulus controllers.

### Gap 3: Configuration Semantic Parsing (Medium Impact)

**Current state:** `ConfigurationExtractor` scans initializer/environment files as source units. `BehavioralProfile` introspects resolved runtime config values.
**Gap:** Initializers that configure third-party gems (Devise, Sidekiq, Stripe) are captured as raw source but not semantically parsed. "Is CORS configured?" requires reading source rather than querying structured metadata.
**Impact:** AI tools and architects cannot query configuration declaratively. They must scan source text.
**Suggested approach:** Pattern-based extraction of common initializer structures: Devise config blocks, Sidekiq configure blocks, CORS configurations, exception notification setup, etc.

### Gap 4: Rake Task Extraction (Medium Impact)

**Current state:** Rake tasks are not extracted.
**Gap:** Custom rake tasks in `lib/tasks/` are a common pattern for data migrations, reports, maintenance scripts, and deployment hooks. Some apps have 50+ rake tasks. These are invisible to the index.
**Impact:** "What maintenance scripts exist?" and "What does `rake cleanup:stale_orders` do?" are unanswerable. CI/CD pipeline debugging often requires understanding rake task implementations.
**Suggested approach:** File-based extractor scanning `lib/tasks/**/*.rake`. Extract task names (from `task :name`/`desc` blocks), dependencies (from `=> [:dep1, :dep2]`), and source code. Link to models/services called within.

### Gap 5: ActiveStorage/ActionText Attachment Metadata (Low-Medium Impact)

**Current state:** `has_one_attached` and `has_rich_text` appear in model association metadata but are not semantically enriched.
**Gap:** Which models have file attachments? What variants are defined? What content types are allowed? What storage service is configured? These questions require dedicated extraction.
**Impact:** AI tools generating file upload features don't know the app's attachment patterns. Migration planning for storage service changes can't enumerate affected models.
**Suggested approach:** Extend `ModelExtractor` to enrich ActiveStorage/ActionText metadata: variant definitions, content type validations, service bindings.

### Gap 6: Test Coverage Mapping (Medium Impact)

**Current state:** No test file extraction exists.
**Gap:** There is no mapping from application units to their test files. "Does the OrderService have tests?" and "What's untested?" are unanswerable.
**Impact:** AI tools generating code cannot also generate corresponding tests that follow the app's testing patterns. Architecture audits cannot assess test coverage gaps.
**Suggested approach:** File-based extractor scanning `spec/` and `test/`. Map test files to their subjects via naming conventions (`spec/models/user_spec.rb` → `User` model) and explicit `describe` blocks. Extract test metadata: factories used, shared examples, VCR cassettes, test helpers.

### Gap 7: Factory/Fixture Extraction (Low-Medium Impact)

**Current state:** No factory or fixture extraction.
**Gap:** FactoryBot factories and test fixtures define the canonical data shapes for an application. "What does a valid Order look like?" is answered by the factory, not the model.
**Impact:** AI test generation cannot reference existing factories. Data modeling questions require reading factory source manually.
**Suggested approach:** Extract factory definitions (traits, associations, sequences) and fixture YAML files. Link factories to their model units.

### Gap 8: Decorator/Presenter Extraction (Low Impact)

**Current state:** `SerializerExtractor` handles Draper decorators via file scanning. No extraction for custom presenter patterns.
**Gap:** Apps using non-Draper presenter patterns (plain Ruby classes in `app/presenters/`) are not discovered.
**Impact:** Low — these are typically simple classes that `ServiceExtractor` might already catch if they follow service naming patterns. But if they live in `app/presenters/` (not in the scanned directories), they're missed entirely.
**Suggested approach:** Add `app/presenters/` to `ServiceExtractor`'s directory scan list, or create a lightweight `PresenterExtractor`.

### Gap 9: Webhook/Event System Extraction (Medium Impact)

**Current state:** No dedicated extraction for event-driven patterns.
**Gap:** Apps using `ActiveSupport::Notifications`, Wisper, Rails Event Store, or custom pub/sub systems have an entire event-driven layer that is invisible. Event subscribers, publishers, and event types are not extracted.
**Impact:** "What happens when an `order.completed` event fires?" is unanswerable. Event-driven architectures are increasingly common in Rails apps.
**Suggested approach:** Detect event system gem (via `BehavioralProfile`), then extract event publishers (`instrument`/`publish`/`broadcast` calls) and subscribers (`subscribe`/`on` registrations). Create event-type units that link publishers to subscribers.

### Gap 10: Database View/Function Extraction (Low Impact)

**Current state:** `MigrationExtractor` captures DDL from migration files. No extraction of database views or functions.
**Gap:** Apps using database views (via `scenic` gem) or custom SQL functions have database-level logic that migrations reference but that isn't captured as structured metadata.
**Impact:** Low for most apps. Higher for apps with significant database-level business logic.
**Suggested approach:** Detect `scenic` gem, extract view definitions. Parse `structure.sql` for custom functions/triggers if present.

### Gap 11: API Documentation Correlation (Medium Impact)

**Current state:** Routes and controllers are extracted but not correlated with API documentation tools.
**Gap:** Apps using `rswag`, `grape-swagger`, or `apipie-rails` have structured API documentation that describes request/response schemas, authentication requirements, and deprecation notices. This documentation layer is not extracted.
**Impact:** AI tools generating API endpoints cannot match existing documentation patterns. API completeness audits require manual correlation.
**Suggested approach:** Detect documentation gem and extract endpoint documentation metadata. Link to corresponding route/controller units.

### Gap 12: State Machine Extraction (Medium Impact)

**Current state:** State machine gems (AASM, statesman, state_machines) appear in `RailsSourceExtractor` gem coverage but model-level state machine definitions are not semantically extracted.
**Gap:** "What states can an Order be in?" and "What transitions are allowed from `pending`?" require reading model source. States, transitions, guards, and callbacks are not structured metadata.
**Impact:** State machines define critical business rules. AI tools and architects need structured access to state/transition definitions.
**Suggested approach:** Detect state machine DSL calls (`aasm`, `state_machine`, `include Statesman::Adapters`) in model source. Extract states, transitions, guards, and callbacks as structured metadata on the model unit.

### Gap 13: Background Job Dependency Chain Visualization (Low-Medium Impact)

**Current state:** Jobs are extracted individually. `CallbackAnalyzer` detects `perform_later` calls in callbacks.
**Gap:** There is no visualization of job chains: "Job A enqueues Job B which enqueues Job C." The dependency graph has edges from callers to jobs, but not from jobs to other jobs they enqueue.
**Impact:** Debugging cascading job failures ("why did the email queue blow up after the import job ran?") requires manual tracing.
**Suggested approach:** Scan job source for `OtherJob.perform_later` patterns and add job-to-job dependency edges. This is already partially done by `SharedDependencyScanner` but not specifically for job chain visualization.

### Gap 14: Multi-Database Topology (Low Impact)

**Current state:** `BehavioralProfile` captures the database adapter. Models are extracted from `ActiveRecord::Base.descendants`.
**Gap:** Rails 6+ supports multiple databases (`connects_to`, `connected_to`). Which models connect to which database, and replica vs. primary roles, are not extracted.
**Impact:** Low for single-database apps. For multi-database apps, deployment and migration planning requires knowing which models hit which database.
**Suggested approach:** Detect `connects_to`/`connected_to` in model source or class-level configuration. Add database role metadata to model units.

### Gap 15: Caching Strategy Extraction (Low-Medium Impact)

**Current state:** `BehavioralProfile` captures the cache store type. No extraction of caching patterns in code.
**Gap:** `Rails.cache.fetch` calls, `caches_action`, `caches_page`, fragment caching in views, and Russian doll caching patterns are not extracted. "What's cached and where?" is unanswerable.
**Impact:** Cache invalidation debugging and performance optimization require knowing what's cached.
**Suggested approach:** Scan controller and model source for caching method calls. Extract cache keys, expiration policies, and conditional caching. Link to the cache store configuration from `BehavioralProfile`.

### Gap 16: Persistent Graph Store (Infrastructure Gap)

**Current state:** `GraphStore` has only an in-memory adapter. The dependency graph is rebuilt from JSON on each load.
**Gap:** For large codebases (1000+ units), graph traversal and PageRank computation from in-memory JSON is adequate but doesn't support efficient incremental updates or persistent queries.
**Impact:** Low for most apps. Higher for organizations wanting to run graph queries across multiple codebases or track graph evolution over time.
**Suggested approach:** Add PostgreSQL and/or Neo4j graph store adapters.

### Gap 17: MetadataStore Backend Diversity (Infrastructure Gap)

**Current state:** Only SQLite adapter exists for `MetadataStore`.
**Gap:** The architecture defines PostgreSQL and MySQL adapters as planned but they don't exist. Apps that want to store metadata in their primary database must use SQLite separately.
**Impact:** Low — SQLite works well for this use case. But it means an extra data store to manage in production.

### Gap 18: Observability Depth (Infrastructure Gap)

**Current state:** `HealthCheck` probes component availability. `StructuredLogger` produces JSON logs. `Instrumentation` wraps `ActiveSupport::Notifications`.
**Gap:** No metrics collection (counters, gauges, histograms), no alerting thresholds, no performance profiling. The health check tests component existence but not actual connectivity (e.g., doesn't verify the embedding provider can actually embed).
**Impact:** Production deployments lack visibility into extraction/retrieval performance.
**Suggested approach:** Add optional metrics integration (StatsD, Prometheus) with extraction duration, retrieval latency, and embedding API call histograms. Deepen health checks to verify actual connectivity.

### Gap 19: Cross-Application Index Federation (Future Architecture)

**Current state:** Each Rails application has its own independent index.
**Gap:** Organizations with multiple Rails applications (monorepo or microservices) cannot query across application boundaries. "Which apps depend on the UserService API?" requires querying multiple independent indexes.
**Impact:** Low for single-app organizations. High for microservice architectures.
**Suggested approach:** A federation layer that aggregates indexes from multiple applications, with cross-app dependency edges for shared gems, API contracts, and message queues.

### Gap 20: Temporal Index / Change Tracking (Future Architecture)

**Current state:** The index represents current state only. `recent_changes` uses git timestamps but there is no historical index.
**Gap:** "How has the Order model changed over the last 6 months?" and "When did this dependency cycle first appear?" are unanswerable. The index is a snapshot, not a time series.
**Impact:** Useful for architectural evolution tracking and regression detection.
**Suggested approach:** Periodic index snapshots with diff computation. Store index versions alongside git SHAs. Enable temporal graph queries.

---

## Summary

### Use Cases: 32 identified across 7 categories

| Category | Count | Key Examples |
|----------|-------|-------------|
| AI-Assisted Development | 7 | Code generation, PR context, code review, onboarding |
| Architecture & Tech Debt | 8 | Health dashboard, impact analysis, concern audit, migration risk |
| Debugging & Incident Response | 6 | Flow tracing, production data, authorization debugging |
| Search & Retrieval | 4 | Semantic search, framework lookup, graph exploration |
| Pipeline & Operations | 6 | Incremental extraction, quality evaluation, feedback loop |
| Multi-Backend Deployment | 5 | Local dev, PostgreSQL, Docker, air-gapped, MySQL |
| Rails Ecosystem Coverage | 6 | GraphQL, components, serializers, ActionCable, scheduling |

### Feature Gaps: 20 identified, ordered by impact (10 resolved in Sprint 3)

| Priority | Gap | Impact | Category | Status |
|----------|-----|--------|----------|--------|
| 1 | HAML/Slim view templates | High | Extraction | Open |
| 2 | Stimulus/Hotwire frontend | High | Extraction | Open |
| 3 | Configuration semantic parsing | Medium | Extraction | Open |
| 4 | Rake task extraction | Medium | Extraction | **Done** (Sprint 2) |
| 5 | State machine extraction | Medium | Extraction | **Done** (Sprint 3) |
| 6 | Webhook/event system extraction | Medium | Extraction | **Done** (Sprint 3) |
| 7 | API documentation correlation | Medium | Extraction | Open |
| 8 | Test coverage mapping | Medium | Extraction | **Done** (Sprint 3) |
| 9 | Caching strategy extraction | Low-Medium | Extraction | **Done** (Sprint 3) |
| 10 | Job dependency chain visualization | Low-Medium | Extraction | **Done** (Sprint 3) |
| 11 | Factory/fixture extraction | Low-Medium | Extraction | **Done** (Sprint 3) |
| 12 | ActiveStorage/ActionText enrichment | Low-Medium | Extraction | **Done** (Sprint 3) |
| 13 | Decorator/presenter extraction | Low | Extraction | **Done** (Sprint 3) |
| 14 | Database view/function extraction | Low | Extraction | **Done** (Sprint 3) |
| 15 | Multi-database topology | Low | Extraction | **Done** (Sprint 3) |
| 16 | Persistent graph store | Low | Infrastructure | Open |
| 17 | MetadataStore backend diversity | Low | Infrastructure | Open |
| 18 | Observability depth | Low | Infrastructure | Open |
| 19 | Cross-application federation | Low | Future Architecture | Open |
| 20 | Temporal index / change tracking | Low | Future Architecture | **Done** (Sprint 2) |
