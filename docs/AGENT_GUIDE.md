# Woods Agent Guide

Woods gives AI agents accurate, structured context about a Rails application by running inside it. Instead of guessing from source files, Woods boots the app, introspects every model, controller, route, service, and job using Rails runtime APIs, and writes the result as JSON.

Two MCP servers make that data available:

- **Index Server**: 29 tool schemas (14 always-on, 15 wiring-conditional). Reads pre-extracted JSON. No Rails boot required.
- **Console Server**: 31 tool schemas as an inventory, but only **9 are executable by default** (11 with an explicit opt-in). It runs live queries against a booted Rails process. There is no "bridge mode" that unlocks the rest, see [Console Server](#console-server).

This guide covers how to set up both servers, which tools to use for common tasks, and what to avoid.

---

## Table of Contents

1. [What Woods Provides](#what-woods-provides)
2. [MCP Server Setup](#mcp-server-setup)
3. [Core Workflows](#core-workflows)
4. [Tool Quick Reference](#tool-quick-reference)
5. [Relationship Types (via)](#relationship-types-via)
6. [Configuration Quick Reference](#configuration-quick-reference)
7. [Gotchas](#gotchas)

---

## What Woods Provides

Each extracted unit is a self-contained JSON object carrying:

- **`source_code`**: annotated source with all included concerns appended inline and a schema header prepended (for models) or a route map prepended (for controllers). This is the full behavioral surface area in one block.
- **`metadata`**: structured data: associations, callbacks with side-effects, validations, enums, scopes, actions, filters, route maps, queue config, field definitions, and more depending on unit type.
- **`dependencies`**: forward edges: what this unit depends on, each with a `via` label describing the relationship type.
- **`dependents`**: reverse edges: what depends on this unit, same structure.

Key enrichments beyond source file content:

| Enrichment | What it does |
|---|---|
| **Concern inlining** | When a model includes `Auditable`, Woods reads the concern source and appends it to the unit's `source_code`. `metadata.inlined_concerns` records which concerns were resolved. |
| **Callback side-effects** | `CallbackAnalyzer` scans each callback method body and records what it actually does: columns written (`self.col =`), jobs enqueued (`perform_later`), mailers sent (`deliver_later`), services called. `metadata.callbacks` includes a `side_effects` hash per callback. |
| **Schema prepending** | Model source gets a comment block showing actual column types, nullability, and indexes from the live database, not guesses from migrations. |
| **Route binding** | Controller source gets a route map comment showing the real HTTP verb + path for every action, resolved from `Rails.application.routes`. |
| **Dependency graph with PageRank** | 34 extractors build a bidirectional graph. PageRank identifies the most structurally central units, the ones with the widest blast radius when changed. |
| **Navigation edges** | View templates scanning for `_path`/`_url` route helper calls produce `link_to` edges pointing to controllers. Controller `redirect_to` calls produce `redirect_to` edges. Form submissions produce `form_action` edges. Filter with `via` on `dependencies`/`dependents` to isolate UI navigation paths. |

**View-template coverage is ERB-only.** HAML, Slim, and Turbo Streams templates are not parsed, an app written in Slim shows zero view units even when views exist. Stimulus controller *references* are detected inside `PhlexExtractor` and `ViewComponentExtractor` via `data-controller` attribute scanning (dependency edges with `via: :html_attribute`, type `stimulus_controller`), but the Stimulus JS files under `app/javascript/controllers/` are not extracted themselves. Query `structure`'s `template_engines` field to confirm which engines the current index parses.

---

## MCP Server Setup

Run extraction first. Extraction requires a booted Rails app:

```bash
# Host app
bundle exec rake woods:extract

# Docker
docker compose exec app bundle exec rake woods:extract
```

### Index Server

The Index Server reads from `tmp/woods/` and does not require Rails.

**Claude Code**: add to `.mcp.json` in the Rails app root:

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

> Use `woods-mcp-start` on Claude Code for automatic restart after crashes. Use `woods-mcp` on Cursor, Windsurf, or other MCP clients.

**Cursor**: add to `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp",
      "args": ["/absolute/path/to/rails-app/tmp/woods"]
    }
  }
}
```

**Windsurf**: same config as Cursor, different file location. Use `woods-mcp` (not `-start`).

**Docker note.** The Index Server runs on the host. Point it at the host-side volume mount path, not the container path. If the container writes to `/app/tmp/woods`, the host path is `./tmp/woods` (or wherever the volume is mounted). Never use the container-internal path, the host process cannot access it.

**On-disk layout.** As of this release, every writer publishes into `tmp/woods/payloads/gen-<N>/`, and `tmp/woods/generation.json` points at the current one. Never assume `tmp/woods/manifest.json` exists directly, read `generation.json`'s `payload` field first, then look under that directory:

```bash
gen=$(jq -r '.payload // empty' tmp/woods/generation.json)
cat "tmp/woods/${gen:-.}/manifest.json"
```

An index written before payloads existed has no `payload` key; the fallback (`${gen:-.}`) reads the flat root in that case, matching how `IndexReader` and every MCP tool already resolve it.

### Console Server

The Console Server connects to a live Rails environment. It executes real queries against `ActiveRecord`, wrapped in rolled-back transactions.

**Simplest setup**: point the MCP client directly at the rake task (works for Docker via `docker compose exec`, direct on the host):

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
      "cwd": "/path/to/your/rails-app"
    }
  }
}
```

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "docker",
      "args": ["compose", "exec", "-i", "app", "bundle", "exec", "rake", "woods:console"]
    }
  }
}
```

The `-i` flag is required to keep stdin attached for MCP protocol communication.

**Launcher wrapper**: `woods-console-mcp` reads `~/.woods/console.yml` (or `$WOODS_CONSOLE_CONFIG`) and execs the same rake task directly, through `docker exec`, or through `ssh`:

```yaml
# ~/.woods/console.yml
mode: docker
container: my_app_web_1
command: bundle exec rake woods:console
```

`mode` is `direct`, `docker`, or `ssh`; matching keys are `directory` (direct), `container` (docker), `host`/`user` (ssh). There is no `service:` or `compose_file:` key, the launcher execs `docker exec` against a container name, not `docker compose`.

Every path above, rake directly, Docker exec, or the launcher wrapper, starts the **same embedded server**. It registers 9 tools by default, or 11 when `console_embedded_read_tools: true` is set in `Woods.configure`. See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full setup reference, including the HTTP/Rack middleware option and the security layers.

---

## Core Workflows

### Understanding a model

Start with `lookup` to get the full unit, source with inlined concerns, schema header, associations, and callback chain. Then traverse dependencies and dependents.

```json
{ "tool": "lookup", "params": { "identifier": "Order", "include_source": true } }
```

```json
{ "tool": "dependencies", "params": { "identifier": "Order", "depth": 2 } }
```

```json
{ "tool": "dependents", "params": { "identifier": "Order", "depth": 1 } }
```

To get only metadata without the full source (faster for large models):

```json
{ "tool": "lookup", "params": { "identifier": "Order", "include_source": false, "sections": ["metadata", "dependencies"] } }
```

### Tracing a feature flow

Find the entry point with `search`, then follow the dependency graph:

```json
{ "tool": "search", "params": { "query": "checkout", "types": ["controller", "route"], "limit": 5 } }
```

```json
{ "tool": "trace_flow", "params": { "entry_point": "OrdersController#create", "depth": 3 } }
```

Or traverse manually with depth control to see paths:

```json
{ "tool": "dependencies", "params": { "identifier": "CheckoutService", "depth": 3, "types": ["job", "mailer"] } }
```

### Assessing blast radius of a change

Get the unit's PageRank to understand its centrality, then traverse dependents:

```json
{ "tool": "pagerank", "params": { "limit": 1, "types": ["model"] } }
```

```json
{ "tool": "dependents", "params": { "identifier": "User", "depth": 3 } }
```

Use `graph_analysis` to check whether the unit is a structural hub or bridge, or `domain_clusters` to see which architectural domain it belongs to:

```json
{ "tool": "graph_analysis", "params": { "analysis": "hubs", "limit": 20 } }
```

```json
{ "tool": "domain_clusters", "params": { "types": ["model", "service", "job"] } }
```

### Finding UI navigation paths

Filter `dependents` to only navigation edges, views that link to or submit forms to a controller:

```json
{ "tool": "dependents", "params": { "identifier": "OrdersController", "depth": 1, "via": ["link_to", "form_action"] } }
```

Find where a controller redirects after an action:

```json
{ "tool": "dependencies", "params": { "identifier": "SessionsController", "depth": 1, "via": ["redirect_to"] } }
```

### Checking test coverage for a unit

Look up the test mapping unit, or search for specs that reference the unit:

```json
{ "tool": "search", "params": { "query": "Order", "types": ["test_mapping"], "limit": 5 } }
```

Then look up the test_mapping unit for the spec file association and coverage status.

### Understanding framework behavior

Use `framework` to search the Rails/gem source installed in the app, not documentation, the actual implementation:

```json
{ "tool": "framework", "params": { "keyword": "before_action", "limit": 5 } }
```

```json
{ "tool": "framework", "params": { "keyword": "has_many", "limit": 3 } }
```

---

## Tool Quick Reference

### Index Server (29 tool schemas: 14 always-on, 15 wiring-conditional)

A tool that isn't wired shows up as "tool not found" in `tools/list`, not as a runtime error, the server only registers what it can actually serve. See [MCP_TOOL_COOKBOOK.md](MCP_TOOL_COOKBOOK.md#conditional-tools--wiring) for the exact wiring condition per tool.

#### Core Query (always-on)

| Tool | Key Parameters | Description |
|------|---------------|-------------|
| `woods_status` | _(none)_ | Diagnose whether the server is ready. Returns extraction metadata (last run, unit counts, git SHA, staleness seconds), retriever/embedding configuration, feature flags, and `server.update` (installed vs. latest published gem version + an `update_available` flag). **Call first on cold connect.** |
| `lookup` | `identifier`, `include_source`, `sections` | Full unit by exact identifier. `sections` filters which fields to return. |
| `search` | `query`, `types`, `fields`, `limit` | Regex search across identifiers, source, or metadata. Returns `{ results: [...], note?, partial? }`, `note` flags broad patterns (>50% of a directory matched), `partial` means the phase-2 scan cap (`WOODS_SEARCH_MAX_SCAN`, default 500) was hit. Invalid regex falls back to literal match. Follow up with `lookup`. |
| `dependencies` | `identifier`, `depth`, `types`, `via` | Forward dependency tree (BFS). What a unit depends on. |
| `dependents` | `identifier`, `depth`, `types`, `via` | Reverse dependency tree (BFS). What depends on a unit. |
| `structure` | `detail` | Manifest summary or full unit breakdown by type. |
| `recent_changes` | `limit`, `types` | Recently modified units sorted by git timestamp. |
| `reload` | n/a | Reload extraction data from disk without restarting the server. |
| `codebase_retrieve` | `query`, `budget` | Natural-language query with RRF-ranked semantic search. Registered always, but returns no results without an embedding provider configured and `rake woods:embed` run. |
| `trace_flow` | `entry_point`, `depth` | Execution flow from a controller action through the dependency graph. |

#### Graph Analysis (always-on)

| Tool | Key Parameters | Description |
|------|---------------|-------------|
| `graph_analysis` | `analysis`, `limit` | Structural analysis. `analysis` is one of: `orphans`, `dead_ends`, `hubs`, `cycles`, `bridges`. |
| `domain_clusters` | `min_size`, `types` | Groups units into semantic domains by namespace and graph connectivity. Returns clusters with hub nodes, entry points, boundary edges, and type breakdowns. |
| `pagerank` | `limit`, `types` | Units ranked by PageRank score (higher = more dependents, wider blast radius). |
| `framework` | `keyword`, `limit` | Search Rails/gem source for installed versions by concept keyword. |

#### Wiring-conditional tools

| Tool group | Count | Wiring condition |
|---|---|---|
| `session_trace` | 1 | `Woods.configuration.session_store` set and readable |
| Pipeline (`pipeline_extract`, `pipeline_embed`, `pipeline_status`, `pipeline_diagnose`, `pipeline_repair`) | 5 | Operator config wired at server build time |
| Feedback (`retrieval_rate`, `retrieval_report_gap`, `retrieval_explain`, `retrieval_suggest`) | 4 | `feedback_store` wired |
| Snapshot (`list_snapshots`, `snapshot_diff`, `unit_history`, `snapshot_detail`) | 4 | `snapshot_store` wired (requires `enable_snapshots: true` + migrations 004/005) |
| `notion_sync` | 1 | `notion_api_token` + `notion_database_ids` both set |

### Structured Errors

Tool failures return `isError: true` with machine-readable `_meta.error_code` so agents can branch without parsing prose. Common codes:

| `error_code` | Meaning | Fix |
|--------------|---------|-----|
| `:not_configured` | A required config value is missing | Read `_meta.config_key` and `_meta.doc_link` |
| `:not_found` | Unit, snapshot, or other entity doesn't exist | Check `_meta.identifier` / `_meta.git_sha`; use `search` or `list_snapshots` |
| `:rate_limited` | PipelineGuard cooldown in effect | Wait `_meta.retry_after_seconds` and retry |
| `:unsupported_argument` | Enum value not allowed | See `_meta.allowed` for valid values |
| `:internal_error` | Assembly or rendering raised an exception | Inspect the text message |
| `:api_error` | External API (e.g. Notion) failed | Inspect the text message |

### Console Server

31 tool schemas exist as an inventory (`lib/woods/console/tool_specs.rb`), grouped into 4 tiers. **Only Tier 1 is ever executable.** There is no bridge process, config-driven unlock, or confirmation flow that registers Tier 2, Tier 3, or `console_eval`, `Server.build(config:)` always raises, and `Server.build_embedded` only ever registers `:embedded` (9 tools) or `:embedded_read` (11 tools, adding `console_sql`/`console_query`).

| Tool | Tier | Executable? | Description |
|------|------|-------------|-------------|
| `console_count` | 1 | Always | Count records matching scope conditions |
| `console_sample` | 1 | Always | Random sample of records (max 25) |
| `console_find` | 1 | Always | Find a record by primary key or unique column |
| `console_pluck` | 1 | Always | Extract column values (max 1000 rows) |
| `console_schema` | 1 | Always | Live database schema for a model |
| `console_aggregate` | 1 | Always | `sum`/`average`/`minimum`/`maximum`/`count` on a column |
| `console_association_count` | 1 | Always | Count associated records for a specific record |
| `console_recent` | 1 | Always | Recently created/updated records (max 50) |
| `console_status` | 1 | Always | Health check: available models and database adapter |
| `console_sql` | 4 | With `console_embedded_read_tools: true` | Execute read-only SQL (`SELECT` / `WITH...SELECT` only, validated) |
| `console_query` | 4 | With `console_embedded_read_tools: true` | Structured query builder, joins, grouping, HAVING |
| `console_diagnose_model`, `console_data_snapshot`, `console_validate_record`, `console_validate_with`, `console_check_setting`, `console_update_setting`, `console_check_policy`, `console_check_eligibility`, `console_decorate` | 2 | Never | Schema-only inventory |
| `console_slow_endpoints`, `console_error_rates`, `console_throughput`, `console_job_queues`, `console_job_failures`, `console_job_find`, `console_job_schedule`, `console_redis_info`, `console_cache_stats`, `console_channel_status` | 3 | Never | Schema-only inventory |
| `console_eval` | 4 | Never | Schema-only inventory. `WOODS_CONSOLE_UNSAFE_EVAL=true` fails server construction closed with `Woods::ConfigurationError` rather than enabling it. |

See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full defense-layer reference (blocked tables, redaction, credential scanning, SQL validation).

---

## Relationship Types (via)

Every edge in the dependency graph carries a `via` label. Use the `via` parameter on `dependencies` and `dependents` to filter to specific relationship types. Pass an array of strings.

### Model Associations

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `belongs_to` | `ModelExtractor`, `reflect_on_all_associations` | Model belongs_to association |
| `has_many` | `ModelExtractor` | Model has_many association |
| `has_one` | `ModelExtractor` | Model has_one association |
| `has_and_belongs_to_many` | `ModelExtractor` | HABTM association |

### Navigation (UI Flows)

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `link_to` | `ViewTemplateExtractor`, `SharedDependencyScanner` | View template links to a controller via `_path`/`_url` helper |
| `redirect_to` | `ControllerExtractor`, `SharedDependencyScanner` | Controller redirects to another controller via route helper |
| `form_action` | `SharedDependencyScanner` | Form submission targets a controller via route helper |

### Rendering

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `render` | `ControllerExtractor`, `ViewTemplateExtractor`, `PhlexExtractor`, `ViewComponentExtractor` | Renders a view, partial, or component |
| `view_render` | `ViewTemplateExtractor` | View template is rendered by a controller |
| `slot` | `ViewComponentExtractor` | Component used as a named slot in another component |

### Module Inclusion

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `include` | `ModelExtractor`, `ConcernExtractor`, `PhlexExtractor`, `ViewComponentExtractor` | Module included (instance-level methods) |
| `extend` | `ModelExtractor`, `ConcernExtractor` | Module extended (class-level methods) |

### Code References

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `code_reference` | `SharedDependencyScanner`, many extractors | Generic code dependency (service call, model reference, etc.) |
| `data_dependency` | `PhlexExtractor`, `ViewComponentExtractor` | Component reads from a model |
| `delegation` | `ManagerExtractor` | Manager delegates to a wrapped model |
| `decoration` | `DecoratorExtractor` | Decorator wraps a model |
| `serialization` | `SerializerExtractor` | Serializer targets a model |
| `authorization` | `PunditExtractor` | Policy governs a model |
| `validation` | `ValidatorExtractor` | Validator applies to a model |
| `test_coverage` | `TestMappingExtractor` | Spec file covers a source unit |

### Infrastructure and Framework

| `via` value | Where it comes from | What it means |
|-------------|--------------------|-|
| `route_dispatch` | `RouteExtractor` | Route dispatches to a controller |
| `engine_route` | `EngineExtractor` | Engine mounts a controller via routing |
| `url_helper` | `MailerExtractor`, `PhlexExtractor`, `ViewComponentExtractor` | Unit references a named route helper |
| `html_attribute` | `PhlexExtractor`, `ViewComponentExtractor` | Component references a Stimulus controller via `data-controller` |
| `job_enqueue` | `JobExtractor` | Job enqueues another job |
| `scheduled` | `ScheduledJobExtractor` | Scheduled job definition references a job class |
| `state_machine` | `StateMachineExtractor` | State machine belongs to a model |
| `state_machine_callback` | `StateMachineExtractor` | State machine callback references a service or job |
| `factory_for` | `FactoryExtractor` | Factory definition covers a model |
| `factory_parent` | `FactoryExtractor` | Factory inherits from a parent factory |
| `factory_association` | `FactoryExtractor` | Factory defines an association to another factory |
| `task_invoke` | `RakeTaskExtractor` | Rake task invokes another task |
| `task_dependency` | `RakeTaskExtractor` | Rake task declares a dependency |
| `table_name` | `DatabaseViewExtractor`, `MigrationExtractor` | View or migration references a model by table name |
| `reference` | `MigrationExtractor` | Migration adds a foreign key reference |
| `type_reference` | `GraphQLExtractor` | GraphQL type references another GraphQL type |
| `field_resolver` | `GraphQLExtractor` | GraphQL field uses a custom resolver |
| `behavioral_profile` | `BehavioralProfile` | App configuration references a framework constant |
| `configuration` | `ConfigurationExtractor` | Configuration references a gem |

---

## Configuration Quick Reference

Set these in `config/initializers/woods.rb` (created by `rails generate woods:install`).

| Option | Default | What Agents Care About |
|--------|---------|----------------------|
| `output_dir` | `Rails.root.join('tmp/woods')` | Where the Index Server points |
| `extractors` | all 34 | **Not implemented as a selection knob.** Setting it warns and every extractor still runs, see [Gotchas](#gotchas). |
| `include_framework_sources` | `true` | Set `false` to speed up extraction (disables `framework` tool results) |
| `embedding_provider` | `nil` | `:openai` or `:ollama`, required for `codebase_retrieve`. No other provider is implemented. |
| `embedding_model` | `'text-embedding-3-small'` | Must match what was used at embed time |
| `max_context_tokens` | `8000` | Token budget for `codebase_retrieve` results |
| `similarity_threshold` | `0.7` | Lower to include less similar results in `codebase_retrieve` |
| `enable_snapshots` | `false` | Required for snapshot diff tools |
| `precompute_flows` | `false` | Pre-generates per-action flow maps; expensive on large apps |
| `extract_navigation_edges` | `true` | Navigation edges (`link_to`, `redirect_to`, `form_action`) included in extraction |
| `session_tracer_enabled` | `false` | Required for `session_trace` tool |
| `console_redacted_columns` | `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` (~30 columns) | Columns hidden from Console Server results |
| `console_blocked_tables` | `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` (8 tables) | Tables rejected outright before any Console Server query runs |
| `console_embedded_read_tools` | `false` | Registers `console_sql` / `console_query` (Tier 4 read tools only, nothing else) |

Storage presets set vector store, metadata store, and embedding together. Only these three exist:

```ruby
Woods.configure_with_preset(:local)       # in-memory + SQLite + Ollama
Woods.configure_with_preset(:postgresql)  # pgvector + SQLite + OpenAI
Woods.configure_with_preset(:production)  # Qdrant + SQLite + OpenAI
```

See [BACKEND_MATRIX.md](BACKEND_MATRIX.md) for the full decision guide, including what's genuinely implemented vs. still a design target.

---

## Gotchas

**Extraction requires a Rails boot.** The Index Server reads static JSON and needs no Rails. But generating that JSON requires `rake woods:extract` inside a running Rails app (or Docker container). You cannot extract from the gem directory or from source files alone.

**`search` returns identifiers, not units.** The `search` tool returns a list of matching unit summaries. To get the full source, metadata, and dependency edges, follow up with `lookup` for each result you need.

**`config.extractors` doesn't select extractors.** It's accepted for forward compatibility, but setting it only emits a warning, every extractor still runs on a full extraction. Don't use it to shrink a CI run; there's no supported way to do that today.

**Navigation edges only exist if the navigation extractor ran.** Navigation edges (`link_to`, `redirect_to`, `form_action`) are extracted by `SharedDependencyScanner` when processing view templates and controllers. They require `extract_navigation_edges` (default `true`) to stay enabled.

**Old serialized graphs may lack `via` metadata.** The dependency graph format was updated to include `via` on every edge. If you have an index from before this change, edges may be bare strings without a `via` key. Re-run `rake woods:extract` to update.

**`dependents` traversal includes all edge types by default.** When you call `dependents` without a `via` filter, you get everything: code references, associations, nav edges, test coverage, and more. Filter with `via` when you want only a specific relationship category.

**Some unit types have no per-file entry point and re-run wholesale, not "skipped."** Routes, middleware, engines, state machines, events, factories, database views, and scheduled jobs are introspected across the whole app, not per file. An incremental run (`rake woods:incremental`) still re-runs these types wholesale whenever a trigger path in that group changes (e.g. any `config/routes.rb` edit re-runs every route-consumer type). It does **not** silently skip them, but a change that doesn't hit a trigger path (e.g. a new job schedule defined somewhere `PathDispatcher` doesn't watch) won't be picked up until the next full extraction. When in doubt after a structural change, run `rake woods:extract`.

**Console Server queries are always rolled back.** Every Console Server operation runs inside a database transaction that is rolled back at the end. Writes appear to succeed and return results, but no data is persisted. `SqlValidator` also blocks DML/DDL at the string level before any database interaction. This does **not** cover async side effects, a job enqueued via `perform_later` inside a validated write still runs.

**Console Server needs a running Rails process.** The Console Server bridges to a live Rails environment. It validates model names against `ActiveRecord::Base.descendants` at startup. If the Rails app is not running, the Console Server will fail to connect.

**Console Server: what you see is what you get.** There is no hidden "escalation" path. If a tool isn't in `tools/list`, no configuration flag, confirmation flow, or environment variable will make it callable, see [Console Server](#console-server) above.

**Parallel tool calls can fail together.** Some MCP clients batch parallel tool calls into a single protocol request. If one call in a batch fails (e.g., a typo in an identifier), the transport layer may reject the entire batch. Validate identifiers with `search` before calling `lookup` when operating in parallel, or serialize calls when any one might fail.

**The `codebase_retrieve` tool requires embedding setup.** The tool is listed in the tool catalog regardless of configuration, but returns no results unless `embedding_provider` is configured and `rake woods:embed` has been run. Use `pipeline_status` to check whether embeddings are available.

**Switching embedding models requires a full re-index.** Different models produce vectors in different embedding spaces with different dimensions. Woods refuses rather than corrupting the index: `rake woods:embed` raises `Woods::MCP::DimensionMismatch` before embedding anything when the configured provider's dimension disagrees with the store's, and the MCP server raises the same error at boot when a dump's recorded dimension disagrees. Drop the vector store, then re-run `rake woods:extract && rake woods:embed`.
