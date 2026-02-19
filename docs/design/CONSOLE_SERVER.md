# Console MCP Server

## Purpose

The codebase-index MCP server provides structural knowledge: models, associations, routes, dependency graphs, PageRank scores — all from pre-extracted JSON. It has no runtime connection to the Rails application and cannot answer questions about live data, performance, or actual records.

The console server closes that gap. It maintains a persistent Rails console session inside the client's environment (Docker, direct process, or SSH) and exposes structured tools for querying live application state. Combined with extraction data, an agent gains a complete picture: how the app is built (structure) and what's happening in it (runtime).

### What This Enables

| Capability | What an agent can do | Requires |
|------------|---------------------|----------|
| **App knowledge** | Answer "how many orders are in processing?" alongside "what callbacks fire on Order?" | Console + Index |
| **Analytics access** | Pull revenue figures, conversion rates, cohort data without writing dashboards | Console |
| **Marketing data** | Query subscriber counts, campaign performance, content metrics for non-technical teams | Console |
| **Support diagnostics** | Look up a specific user's state, recent errors, subscription status | Console |
| **Expert code review** | Verify that model validations match actual data, find constraint violations | Console + Index |
| **Safety evaluation** | Check for orphaned records, data integrity issues, N+1 patterns in production | Console + Index |

None of these require raw `eval` access. The MVP achieves all six through structured, safe-by-construction tools.

---

## Architecture

### System Overview

```
Agent (Claude Code, Cursor, etc.)
  │
  │ MCP protocol (stdio)
  │
  ▼
┌─────────────────────────────┐
│ codebase-console-mcp        │  Host machine — Ruby process
│ MCP Server                  │  Validates params, enforces limits,
│                             │  formats responses, redacts sensitive data
└─────────────────────────────┘
  │
  │ JSON-lines over stdio (or docker exec / ssh)
  │
  ▼
┌─────────────────────────────┐
│ Console Bridge              │  Inside Rails environment
│                             │  Persistent Rails boot, ActiveRecord
│ (Docker container /         │  connection, eval in SafeContext
│  direct process / SSH host) │
└─────────────────────────────┘
  │
  │ ActiveRecord / raw SQL
  │
  ▼
┌─────────────────────────────┐
│ Database                    │  Read replica preferred
│ (MySQL / PostgreSQL)        │
└─────────────────────────────┘
```

### Relationship to codebase-index

Same gem, separate executable. Both servers share `CodebaseIndex::` namespace but run independently.

| | codebase-index | codebase-console |
|---|---|---|
| **Executable** | `exe/codebase-index-mcp` | `exe/codebase-console-mcp` |
| **Data source** | JSON files on disk | Live database via Rails console |
| **Rails required** | No | Yes (inside bridge) |
| **Answers** | "What models exist? What are Order's associations?" | "How many orders are pending? What's user #42's status?" |
| **Safety model** | Read-only by design (static files) | Defense in depth (see below) |
| **State** | Point-in-time extraction snapshot | Real-time |

An agent with both servers connected can do things neither can alone: "Find all models with `dependent: :destroy` (index) and check which ones have orphaned children (console)."

### Bridge Protocol

The bridge is a long-running Ruby process that boots Rails and accepts JSON-lines requests over stdio. One request, one response, newline-delimited.

**Request:**

```json
{"id": "req_1", "tool": "count", "params": {"model": "Order", "scope": {"status": "pending"}}}
```

**Response:**

```json
{"id": "req_1", "ok": true, "result": {"count": 1847}, "timing_ms": 12.3}
```

**Error:**

```json
{"id": "req_1", "ok": false, "error": "Model not found: Ordr", "error_type": "validation"}
```

The bridge validates model names against `ActiveRecord::Base.descendants`, validates column names against the schema, and rejects anything that doesn't match a known tool. It never receives arbitrary Ruby code in Tiers 1-3.

### Connection Modes

**Docker exec (recommended for development):**

```yaml
# MCP server config
console:
  mode: docker
  container: my-rails-app-web-1
  command: "bundle exec rails runner lib/codebase_index/console/bridge.rb"
```

The MCP server spawns `docker exec -i <container> <command>` and communicates over the attached stdin/stdout.

**Direct process:**

```yaml
console:
  mode: direct
  directory: /path/to/rails/app
  command: "bundle exec rails runner lib/codebase_index/console/bridge.rb"
```

For when the Rails app runs on the same machine (local development without Docker).

**SSH:**

```yaml
console:
  mode: ssh
  host: staging.example.com
  user: deploy
  command: "cd /var/www/app/current && bundle exec rails runner lib/codebase_index/console/bridge.rb"
```

For querying staging or production environments. SSH connection is persistent (reused across requests).

---

## Safety Model

Defense in depth — five layers, each independent. A failure in any single layer doesn't expose write access.

### Layer 1: Connection-Level Isolation

Connect the bridge to a read replica or a database role with read-only grants.

**MySQL:**

```sql
CREATE USER 'codebase_reader'@'%' IDENTIFIED BY '...';
GRANT SELECT ON my_app_production.* TO 'codebase_reader'@'%';
FLUSH PRIVILEGES;
```

**PostgreSQL:**

```sql
CREATE ROLE codebase_reader LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE my_app_production TO codebase_reader;
GRANT USAGE ON SCHEMA public TO codebase_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO codebase_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO codebase_reader;
```

Configure in the bridge:

```ruby
# config/database.yml (or environment variable)
console_readonly:
  adapter: mysql2  # or postgresql
  host: read-replica.internal
  database: my_app_production
  username: codebase_reader
  password: <%= ENV["CONSOLE_DB_PASSWORD"] %>
```

This is the strongest layer — even if all other layers fail, the database rejects writes.

### Layer 2: Transaction Rollback

Every bridge request runs inside a rolled-back transaction. Reads succeed; writes are discarded silently.

```ruby
module CodebaseIndex
  module Console
    class SafeContext
      def execute(tool, params)
        ActiveRecord::Base.connection.transaction do
          result = dispatch(tool, params)
          raise ActiveRecord::Rollback  # Always rollback
          result  # Returned before rollback unwinds
        end
      end
    end
  end
end
```

This catches any accidental writes from callbacks, counter caches, or touch updates that fire during reads.

### Layer 3: Statement Timeouts

Every request gets a statement-level timeout to prevent runaway queries.

**MySQL:**

```sql
SET SESSION max_execution_time = 5000;  -- 5 seconds, milliseconds
```

**PostgreSQL:**

```sql
SET statement_timeout = '5s';
```

The bridge sets this at connection establishment and resets per-request if the configuration specifies a per-tool timeout. Long-running analytics queries can opt into a higher limit (30s) while simple lookups stay at 5s.

### Layer 4: Structured Tools Only (MVP)

Tiers 1-3 tools are safe by construction. The bridge receives `{"tool": "count", "params": {"model": "Order"}}`, not arbitrary Ruby. The bridge:

1. Validates `model` is in `ActiveRecord::Base.descendants.map(&:name)`
2. Validates all column names against `model.column_names`
3. Validates scope operators against an allowlist (`=`, `>`, `<`, `>=`, `<=`, `!=`, `IN`, `NOT IN`, `BETWEEN`, `IS NULL`, `IS NOT NULL`, `LIKE`)
4. Builds the ActiveRecord query programmatically — no string interpolation, no `where("...")` with user input

No tool in Tiers 1-3 accepts arbitrary Ruby or SQL strings.

### Layer 5: Controlled Writes (Tier 2+)

When writes are needed (e.g., toggling a feature flag), they go through pre-registered actions with human confirmation:

```ruby
CodebaseIndex::Console.configure do |config|
  config.register_write_action(
    name: "update_setting",
    model: "Setting",
    allowed_attributes: %w[value],
    requires_confirmation: true,
    description: "Update an application setting value"
  )
end
```

The MCP server presents the proposed change to the human before executing. The bridge only executes registered actions — no ad-hoc writes.

### Sensitive Data Handling

**Column redaction:**

```ruby
config.redact_columns %w[
  password_digest encrypted_password
  ssn tax_id credit_card_number
  api_key secret_key token
]
```

Redacted columns return `"[REDACTED]"` in all tool responses. The redaction list is configured once and enforced in the bridge, not the MCP server.

**Result size caps:**

| Tool | Default limit | Maximum |
|------|--------------|---------|
| `sample` | 5 records | 25 |
| `pluck` | 100 values | 1000 |
| `find` | 1 record | 1 |
| `recent` | 10 records | 50 |
| `aggregate` | 1 value | 1 |

---

## Tool Interface

### Tier 1: MVP (Safe Reads)

These tools are safe by construction — no arbitrary code, no writes, all inputs validated against the schema.

```yaml
tools:
  - name: console_count
    description: >
      Count records matching conditions. Returns integer count.
      Supports scoping by any column with standard operators.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name (e.g. "Order", "User")'
        scope:
          type: object
          description: >
            Conditions as { column: value } for equality,
            or { column: { op: ">", value: 100 } } for operators.
          additionalProperties: true
      required: [model]

  - name: console_sample
    description: >
      Fetch a random sample of records. Returns attributes
      (excluding redacted columns) with limited result set.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        scope:
          type: object
          description: 'Filter conditions (same format as count)'
          additionalProperties: true
        limit:
          type: integer
          description: 'Number of records (default: 5, max: 25)'
        columns:
          type: array
          items: { type: string }
          description: 'Specific columns to return (default: all non-redacted)'
      required: [model]

  - name: console_find
    description: >
      Look up a single record by primary key or unique column value.
      Returns all non-redacted attributes.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        id:
          description: 'Primary key value'
        by:
          type: object
          description: 'Unique column lookup: { "email": "user@example.com" }'
          additionalProperties: true
        columns:
          type: array
          items: { type: string }
          description: 'Specific columns to return'
      required: [model]

  - name: console_pluck
    description: >
      Extract values of specific columns. Efficient — uses SQL
      SELECT directly, no model instantiation.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        columns:
          type: array
          items: { type: string }
          description: 'Column names to pluck'
        scope:
          type: object
          description: 'Filter conditions'
          additionalProperties: true
        limit:
          type: integer
          description: 'Maximum values (default: 100, max: 1000)'
        distinct:
          type: boolean
          description: 'Return unique values only (default: false)'
      required: [model, columns]

  - name: console_aggregate
    description: >
      Run an aggregate function on a column. Supports sum, avg,
      minimum, maximum.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        function:
          type: string
          enum: [sum, avg, minimum, maximum]
          description: 'Aggregate function'
        column:
          type: string
          description: 'Column to aggregate'
        scope:
          type: object
          description: 'Filter conditions'
          additionalProperties: true
      required: [model, function, column]

  - name: console_association_count
    description: >
      Count associated records for a given record. E.g., "how many
      line_items does Order #42 have?"
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        id:
          description: 'Primary key of the parent record'
        association:
          type: string
          description: 'Association name (e.g. "line_items", "comments")'
        scope:
          type: object
          description: 'Additional conditions on the association'
          additionalProperties: true
      required: [model, id, association]

  - name: console_schema
    description: >
      Return the database schema for a model. Column names, types,
      nullability, defaults, indexes. Does not query data.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        include_indexes:
          type: boolean
          description: 'Include index definitions (default: true)'
      required: [model]

  - name: console_recent
    description: >
      Fetch recently created or updated records. Defaults to
      ordering by created_at descending.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        order_by:
          type: string
          description: 'Column to order by (default: "created_at")'
        direction:
          type: string
          enum: [asc, desc]
          description: 'Sort direction (default: "desc")'
        limit:
          type: integer
          description: 'Number of records (default: 10, max: 50)'
        scope:
          type: object
          description: 'Filter conditions'
          additionalProperties: true
        columns:
          type: array
          items: { type: string }
          description: 'Specific columns to return'
      required: [model]

  - name: console_status
    description: >
      Health check for the console bridge. Returns connection state,
      database adapter, Rails version, available models, and uptime.
    input_schema:
      properties: {}
```

### Tier 2: Domain-Aware Tools

Higher-level tools that combine multiple queries, plus tools for querying non-model domain classes: managers (SimpleDelegator wrappers), policies (eligibility rules), standalone validators, and decorators/view models (presentation objects). Built on Tier 1 primitives.

```yaml
tools:
  - name: console_diagnose_model
    description: >
      Run diagnostic checks on a model: record count, null rates
      for key columns, recent error-state records, orphaned
      associations. Returns a structured health report.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        checks:
          type: array
          items:
            type: string
            enum: [counts, nulls, orphans, recent_errors, distribution]
          description: 'Which checks to run (default: all)'
      required: [model]

  - name: console_data_snapshot
    description: >
      Capture a point-in-time summary of key metrics for a model:
      total count, count by status/state column, recent creation
      rate, and age distribution.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        group_by:
          type: string
          description: 'Column to group counts by (e.g. "status", "state")'
      required: [model]

  - name: console_validate_record
    description: >
      Run ActiveRecord validations on a record without saving.
      Returns validation errors if any. Useful for diagnosing
      why a record can't be updated.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        id:
          description: 'Primary key of the record to validate'
      required: [model, id]

  - name: console_check_setting
    description: >
      Look up an application setting or configuration value.
      Works with Settings/Configuration models or Rails credentials.
      Read-only.
    input_schema:
      properties:
        key:
          type: string
          description: 'Setting key to look up'
        model:
          type: string
          description: 'Settings model name (default: auto-detect from Setting, AppSetting, Configuration)'
      required: [key]

  - name: console_update_setting
    description: >
      Update an application setting. Requires human confirmation
      via the MCP client. Only works for pre-registered write
      actions.
    input_schema:
      properties:
        key:
          type: string
          description: 'Setting key to update'
        value:
          type: string
          description: 'New value'
        model:
          type: string
          description: 'Settings model name (default: auto-detect)'
      required: [key, value]

  - name: console_check_policy
    description: >
      Evaluate a domain policy class against live data. Works with
      eligibility/authorization classes that respond to allowed?,
      eligible?, or valid?. Returns the boolean result and any
      reason/error messages exposed by the policy.
    input_schema:
      properties:
        policy:
          type: string
          description: 'Policy class name (e.g. "SubscriptionPausePolicy", "ProductLimitPolicy")'
        args:
          type: object
          description: >
            Constructor arguments as { model: id } pairs.
            E.g. { "account": 42 } instantiates the policy with Account.find(42).
          additionalProperties: true
        method:
          type: string
          description: 'Method to call (default: auto-detect from allowed?, eligible?, valid?)'
      required: [policy, args]

  - name: console_validate_with
    description: >
      Run a standalone validator class against a record. Unlike
      console_validate_record (which runs model-level validations),
      this invokes domain-specific validator classes that may span
      multiple models or check external state. Returns all errors
      added by the validator.
    input_schema:
      properties:
        validator:
          type: string
          description: 'Validator class name (e.g. "DiscountCodeValidator", "ItemAvailableValidator")'
        model:
          type: string
          description: 'Model of the record to validate'
        id:
          description: 'Primary key of the record'
      required: [validator, model, id]

  - name: console_check_eligibility
    description: >
      Invoke a manager or delegator method to check account-scoped
      business state. Works with SimpleDelegator subclasses that
      wrap a model (e.g. AccountManagingProducts wrapping Account).
      Returns the method result. Read-only — the manager is
      instantiated inside a rolled-back transaction.
    input_schema:
      properties:
        manager:
          type: string
          description: 'Manager/delegator class name (e.g. "AccountManagingProducts")'
        model:
          type: string
          description: 'Model to wrap (default: inferred from class name)'
        id:
          description: 'Primary key of the record to wrap'
        method:
          type: string
          description: 'Method to call (e.g. "product_limit_reached?")'
      required: [manager, id, method]

  - name: console_decorate
    description: >
      Instantiate a decorator or view model around a record and
      call accessor methods. Useful for previewing computed
      presentation state — what the view will actually see.
      Returns a hash of requested method results.
    input_schema:
      properties:
        decorator:
          type: string
          description: 'Decorator/ViewModel class name (e.g. "AccountDecorator", "DashboardStatsView")'
        model:
          type: string
          description: 'Model to wrap (default: inferred from class name)'
        id:
          description: 'Primary key of the record'
        methods:
          type: array
          items: { type: string }
          description: 'Methods to call and return results for (e.g. ["plan_name", "product_count"])'
      required: [decorator, id, methods]
```

### Tier 3: Analytics Integration

For applications with analytics data in the primary database (or a connected analytics store).

```yaml
tools:
  - name: console_slow_endpoints
    description: >
      Query request log data for slow endpoints. Requires a request
      log model (configurable). Returns path, method, p50/p95/p99
      duration, and request count.
    input_schema:
      properties:
        period:
          type: string
          description: 'Time period: "1h", "24h", "7d" (default: "24h")'
        threshold_ms:
          type: integer
          description: 'Minimum p95 to include (default: 500)'
        limit:
          type: integer
          description: 'Maximum results (default: 20)'
      required: []

  - name: console_error_rates
    description: >
      Error rate by controller/action or endpoint. Requires an error
      tracking model or request log with status codes.
    input_schema:
      properties:
        period:
          type: string
          description: 'Time period (default: "24h")'
        group_by:
          type: string
          enum: [controller, endpoint, error_class]
          description: 'How to group errors (default: "controller")'
        limit:
          type: integer
          description: 'Maximum results (default: 20)'
      required: []

  - name: console_throughput
    description: >
      Request throughput over time. Returns time-bucketed counts
      for monitoring traffic patterns.
    input_schema:
      properties:
        period:
          type: string
          description: 'Time period (default: "24h")'
        bucket:
          type: string
          description: 'Time bucket size: "1m", "5m", "1h" (default: "1h")'
        scope:
          type: object
          description: 'Filter conditions (e.g. { "controller": "OrdersController" })'
          additionalProperties: true
      required: []

  - name: console_job_queues
    description: >
      Queue-level overview: size, latency, and paused state for
      each queue. Works with Sidekiq (via Redis API), Solid Queue
      (via solid_queue_* tables), or GoodJob (via good_jobs table).
      Handles mixed frameworks in the same app.
    input_schema:
      properties:
        backend:
          type: string
          enum: [sidekiq, solid_queue, good_job, auto]
          description: 'Job backend to query (default: auto-detect)'
      required: []

  - name: console_job_failures
    description: >
      Recent failed jobs with error class, message, queue, and
      failure time. For Sidekiq: reads the RetrySet and DeadSet.
      For Solid Queue: queries failed_executions. For GoodJob:
      queries errored jobs. Useful for diagnosing recurring
      failures without opening the Sidekiq dashboard.
    input_schema:
      properties:
        queue:
          type: string
          description: 'Filter to a specific queue (default: all)'
        worker:
          type: string
          description: 'Filter to a specific worker/job class (e.g. "AbandonedCartWorker")'
        period:
          type: string
          description: 'Time window: "1h", "24h", "7d" (default: "24h")'
        limit:
          type: integer
          description: 'Maximum results (default: 20, max: 50)'
        backend:
          type: string
          enum: [sidekiq, solid_queue, good_job, auto]
          description: 'Job backend to query (default: auto-detect)'
      required: []

  - name: console_job_find
    description: >
      Look up a specific job by ID (Sidekiq JID, Solid Queue job
      ID, or GoodJob ID). Returns job class, args, queue, status,
      enqueued_at, and error details if failed. Supports retrying
      a specific failed job (requires human confirmation).
    input_schema:
      properties:
        job_id:
          type: string
          description: 'Job identifier (JID for Sidekiq, ID for Solid Queue/GoodJob)'
        backend:
          type: string
          enum: [sidekiq, solid_queue, good_job, auto]
          description: 'Job backend (default: auto-detect)'
      required: [job_id]

  - name: console_job_schedule
    description: >
      View scheduled/enqueued jobs. For Sidekiq: reads the
      ScheduledSet. For Solid Queue: queries scheduled_executions.
      Shows what's coming up and when.
    input_schema:
      properties:
        queue:
          type: string
          description: 'Filter to a specific queue'
        worker:
          type: string
          description: 'Filter to a specific worker/job class'
        limit:
          type: integer
          description: 'Maximum results (default: 20, max: 50)'
        backend:
          type: string
          enum: [sidekiq, solid_queue, good_job, auto]
          description: 'Job backend (default: auto-detect)'
      required: []

  - name: console_redis_info
    description: >
      Redis server diagnostics: memory usage, connected clients,
      keyspace stats, and command stats. Does not expose key values
      — only aggregate metrics. Useful for diagnosing Redis-backed
      issues (Sidekiq, caching, sessions, rate limiting).
    input_schema:
      properties:
        sections:
          type: array
          items:
            type: string
            enum: [memory, clients, stats, keyspace, all]
          description: 'INFO sections to return (default: [memory, clients, keyspace])'
      required: []

  - name: console_cache_stats
    description: >
      Cache store diagnostics. For Redis cache: key count by
      pattern, memory usage, hit/miss ratio (if stats enabled).
      For Solid Cache: row count, byte size, oldest/newest entries,
      eviction rate. For file/memory stores: basic stats only.
    input_schema:
      properties:
        pattern:
          type: string
          description: 'Key pattern to inspect (e.g. "views/*", "accounts/*"). Redis/Solid Cache only.'
        backend:
          type: string
          enum: [redis, solid_cache, memory, file, auto]
          description: 'Cache backend (default: auto-detect from Rails.cache)'
      required: []

  - name: console_channel_status
    description: >
      ActionCable channel statistics. Returns active subscription
      counts per channel, recent broadcast events, and connection
      pool state. Queries the ActionCable subscription adapter
      (Redis or PostgreSQL). Useful for debugging real-time update
      issues.
    input_schema:
      properties:
        channel:
          type: string
          description: 'Specific channel class name (default: all channels)'
      required: []
```

### Tier 4: Advanced (Guarded)

These tools accept less-structured input and require stronger guardrails.

```yaml
tools:
  - name: console_eval
    description: >
      Evaluate arbitrary Ruby in the Rails console. REQUIRES human
      confirmation for every invocation. The code is displayed to
      the human before execution. Results are size-capped and
      sensitive data is redacted.
    input_schema:
      properties:
        code:
          type: string
          description: 'Ruby code to evaluate'
        timeout:
          type: integer
          description: 'Execution timeout in seconds (default: 10, max: 30)'
      required: [code]

  - name: console_sql
    description: >
      Execute a read-only SQL query. The bridge validates that the
      statement begins with SELECT (or WITH ... SELECT for CTEs).
      Rejects INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE.
    input_schema:
      properties:
        sql:
          type: string
          description: 'SQL SELECT statement'
        timeout:
          type: integer
          description: 'Execution timeout in seconds (default: 10, max: 30)'
        limit:
          type: integer
          description: 'Max rows to return (default: 100, max: 1000)'
      required: [sql]

  - name: console_query
    description: >
      Enhanced query builder with joins, grouping, and ordering.
      Builds ActiveRecord queries programmatically — more
      expressive than count/pluck but still validated.
    input_schema:
      properties:
        model:
          type: string
          description: 'ActiveRecord model name'
        select:
          type: array
          items: { type: string }
          description: 'Columns or expressions to select'
        joins:
          type: array
          items: { type: string }
          description: 'Association names to join'
        scope:
          type: object
          description: 'WHERE conditions'
          additionalProperties: true
        group:
          type: array
          items: { type: string }
          description: 'GROUP BY columns'
        order:
          type: object
          description: '{ column: "asc"|"desc" }'
          additionalProperties: true
        limit:
          type: integer
          description: 'Max rows (default: 100, max: 1000)'
      required: [model]
```

---

## Goal-to-Tool Mapping

How the six capability goals map to tools across both MCP servers.

| Goal | Index tools | Console tools | Example flow |
|------|-------------|---------------|-------------|
| **App knowledge** | `lookup`, `dependencies`, `structure` | `console_count`, `console_sample`, `console_aggregate` | "How does Order work?" → `lookup("Order")` then "How many are pending?" → `console_count(model: "Order", scope: {status: "pending"})` |
| **Analytics access** | `structure` (to understand available models) | `console_aggregate`, `console_throughput`, `console_query` | "What's the revenue this month?" → `console_aggregate(model: "Order", function: "sum", column: "total", scope: {created_at: {op: ">=", value: "2026-02-01"}})` |
| **Marketing data** | `search` (find subscriber/campaign models) | `console_count`, `console_pluck`, `console_data_snapshot` | "How many active subscribers?" → `search("subscriber")` to find model, then `console_data_snapshot(model: "Subscriber", group_by: "status")` |
| **Support diagnostics** | `lookup` (understand model structure) | `console_find`, `console_check_policy`, `console_validate_with`, `console_check_eligibility` | "Why can't account #42 pause?" → `console_find(model: "Account", id: 42)` → `console_check_policy(policy: "SubscriptionPausePolicy", args: {account: 42})` → see rejection reason |
| **Expert code review** | `lookup`, `graph_analysis`, `dependents` | `console_diagnose_model`, `console_validate_with`, `console_decorate` | "Are Order validations enforced?" → `lookup("Order")` for validations, then `console_diagnose_model(model: "Order", checks: ["nulls"])` to find violations |
| **Safety evaluation** | `graph_analysis`, `pagerank`, `dependencies` | `console_diagnose_model`, `console_count`, `console_slow_endpoints`, `console_channel_status` | "Any data integrity issues?" → `graph_analysis(analysis: "orphans")` for structural orphans, then `console_diagnose_model(model: "LineItem", checks: ["orphans"])` for data orphans |

### Multi-Step Example: Support Diagnostic

**Scenario:** "User reports they can't complete checkout"

```
1. console_find(model: "User", id: 42, columns: ["id", "email", "status", "created_at"])
   → User exists, status: "active"

2. lookup("Order")
   → Understand Order model: validations, associations, callbacks

3. console_count(model: "Order", scope: {user_id: 42, status: "pending"})
   → 1 pending order found

4. console_find(model: "Order", by: {user_id: 42, status: "pending"})
   → Order #789, total: 0.00, payment_method_id: null

5. console_validate_record(model: "Order", id: 789)
   → Errors: ["payment_method can't be blank", "total must be greater than 0"]

6. Agent responds: "User #42 has a pending order (#789) that's failing validation —
   missing payment method and zero total. The cart likely didn't sync prices."
```

### Multi-Step Example: Data Quality Audit

**Scenario:** "Check if our foreign keys are healthy"

```
1. graph_analysis(analysis: "all")
   → Structural analysis: models with associations defined

2. console_diagnose_model(model: "LineItem", checks: ["orphans"])
   → 47 line_items with order_id pointing to deleted orders

3. console_diagnose_model(model: "Comment", checks: ["orphans"])
   → 0 orphans — foreign keys enforced

4. dependencies("LineItem")
   → Depends on: Order (belongs_to), Product (belongs_to)

5. console_count(model: "LineItem", scope: {product_id: null})
   → 12 line_items with null product_id

6. Agent responds: "Found 47 orphaned LineItems referencing deleted Orders and
   12 with null product_id. Consider adding database-level foreign key constraints
   and a NOT NULL constraint on product_id."
```

### Multi-Step Example: Account Eligibility Debugging

**Scenario:** "Support ticket: account #1234 says they can't add more products"

```
1. console_find(model: "Account", id: 1234, columns: ["id", "name", "plan_id", "status"])
   → Account exists, plan: "gold", status: "active"

2. console_check_eligibility(manager: "AccountManagingProducts", id: 1234,
     method: "product_limit_reached?")
   → true — at limit

3. console_count(model: "Product", scope: {account_id: 1234})
   → 250 products

4. console_check_policy(policy: "ProductLimitPolicy", args: {account: 1234})
   → { allowed: false, reason: "Gold plan allows 250 products", current: 250, limit: 250 }

5. console_decorate(decorator: "AccountDecorator", id: 1234,
     methods: ["plan_name", "max_products", "products_remaining"])
   → { plan_name: "Gold", max_products: 250, products_remaining: 0 }

6. Agent responds: "Account #1234 is on the Gold plan (250 product limit) and has
   exactly 250 products. They'll need to upgrade to Platinum or remove existing
   products. The account is otherwise healthy."
```

---

## Deployment

### Quick Start: Standalone Bridge Script

For evaluation or local development. No gem dependency in the Rails app — copy a single file.

```bash
# Copy the bridge script into your Rails app
cp vendor/codebase_index/console_bridge.rb lib/

# Start the bridge directly
bundle exec rails runner lib/console_bridge.rb
```

Configure the MCP server to connect:

```yaml
# Claude Code MCP config
mcpServers:
  codebase-console:
    command: exe/codebase-console-mcp
    args:
      - --mode=direct
      - --directory=/path/to/rails/app
      - --bridge-command=bundle exec rails runner lib/console_bridge.rb
```

### Production: Gem Dependency

Add the gem to the Rails app's Gemfile for automatic bridge discovery and configuration.

```ruby
# Gemfile
group :development do
  gem "codebase_index"
end
```

```yaml
# Claude Code MCP config
mcpServers:
  codebase-console:
    command: exe/codebase-console-mcp
    args:
      - --mode=docker
      - --container=my-rails-app-web-1
```

The bridge auto-detects the gem and uses its built-in bridge script.

### Docker Mode Configuration

```ruby
CodebaseIndex::Console.configure do |config|
  config.mode = :docker
  config.container = "my-rails-app-web-1"
  # Or use compose service name:
  # config.compose_service = "web"
  # config.compose_file = "docker-compose.yml"

  config.statement_timeout = 5  # seconds
  config.max_result_size = 1_000

  config.redact_columns %w[
    password_digest encrypted_password
    ssn tax_id api_key secret_key
  ]
end
```

### Direct Mode Configuration

```ruby
CodebaseIndex::Console.configure do |config|
  config.mode = :direct
  config.rails_root = "/path/to/rails/app"
  config.environment = "development"

  config.statement_timeout = 10
  config.max_result_size = 5_000
end
```

### SSH Mode Configuration

```ruby
CodebaseIndex::Console.configure do |config|
  config.mode = :ssh
  config.ssh_host = "staging.example.com"
  config.ssh_user = "deploy"
  config.ssh_key = "~/.ssh/id_ed25519"  # Or use SSH agent
  config.rails_root = "/var/www/app/current"
  config.environment = "production"

  # Tighter limits for production
  config.statement_timeout = 3
  config.max_result_size = 500
  config.read_only_database = true  # Enforces Layer 1

  config.redact_columns %w[
    password_digest encrypted_password
    ssn tax_id credit_card_number
    api_key secret_key token
  ]
end
```

### Presets

```ruby
# Local development, no Docker
CodebaseIndex::Console.configure_with_preset(:local)

# Docker Compose (detects running containers)
CodebaseIndex::Console.configure_with_preset(:docker)

# Production read-only (strict limits, column redaction)
CodebaseIndex::Console.configure_with_preset(:production)
```

### Connection Lifecycle

**Boot:** The MCP server spawns the bridge process on first tool invocation (lazy). The bridge boots Rails, establishes the database connection, sets statement timeouts, and sends a ready signal.

**Keepalive:** The bridge sends a heartbeat every 30 seconds. If the MCP server doesn't receive a heartbeat within 90 seconds, it marks the connection as stale.

**Reconnect:** On connection loss, the MCP server attempts reconnection with exponential backoff (1s, 2s, 4s, 8s, max 30s). After 5 consecutive failures, it stops retrying and reports the bridge as unavailable via `console_status`.

**Shutdown:** The MCP server sends `{"tool": "shutdown"}` to the bridge on process exit. The bridge closes the database connection and exits cleanly. If the bridge doesn't respond within 5 seconds, the MCP server sends SIGTERM.

### Configuration Reference

**MCP Server (YAML):**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mode` | string | `docker` | Connection mode: `docker`, `direct`, `ssh` |
| `container` | string | — | Docker container name or ID |
| `compose_service` | string | — | Docker Compose service name (alternative to `container`) |
| `directory` | string | — | Rails app directory (direct mode) |
| `ssh_host` | string | — | SSH hostname (ssh mode) |
| `ssh_user` | string | — | SSH username |
| `ssh_key` | string | — | Path to SSH private key |
| `bridge_command` | string | auto-detect | Custom bridge launch command |
| `statement_timeout` | integer | `5` | Default query timeout in seconds |
| `max_result_size` | integer | `1000` | Maximum rows/values in responses |
| `boot_timeout` | integer | `60` | Seconds to wait for bridge boot |
| `heartbeat_interval` | integer | `30` | Seconds between keepalive pings |

**Bridge (Ruby DSL):**

| Method | Type | Default | Description |
|--------|------|---------|-------------|
| `redact_columns` | array | `[]` | Column names to replace with `[REDACTED]` |
| `allowed_models` | array | all AR descendants | Restrict which models are queryable |
| `denied_models` | array | `[]` | Models to exclude from queries |
| `read_only_database` | boolean | `false` | Enforce read-only DB connection |
| `register_write_action` | block | — | Register a controlled write (Tier 2+) |
| `allowed_classes` | hash | auto-detect | Non-model classes queryable per type: `{ policies: [...], validators: [...] }` |
| `manager_dirs` | array | `["app/managers"]` | Directories to scan for manager/delegator classes |
| `policy_dirs` | array | `["app/policies"]` | Directories to scan for policy classes |
| `validator_dirs` | array | `["app/validators"]` | Directories to scan for standalone validator classes |
| `decorator_dirs` | array | `["app/decorators", "app/view_models"]` | Directories to scan for decorator/view model classes |
| `analytics_model` | string | auto-detect | Model for request log analytics |
| `job_backend` | symbol | auto-detect | `:sidekiq`, `:solid_queue`, `:good_job` |
| `cache_backend` | symbol | auto-detect | `:redis`, `:solid_cache`, `:memory`, `:file` |
| `redis_url` | string | auto-detect | Redis URL for `redis_info` tool (defaults to Sidekiq or Rails.cache connection) |

---

## Phased Implementation

### Phase 0: Bridge Protocol + Connection Layer

**Goal:** Establish reliable communication between MCP server and Rails console.

**Deliverables:**
- Bridge script: Rails runner that accepts JSON-lines, dispatches to tools, returns JSON-lines
- Connection manager: Docker exec, direct, and SSH modes with lifecycle management
- Heartbeat/reconnect logic
- Model and column validation (allowlist from `ActiveRecord::Base.descendants`)

**Unlocks:** The communication foundation. No user-facing tools yet, but the bridge can be tested end-to-end.

### Phase 1: MVP Tools + MCP Server

**Goal:** A working console MCP server with safe read-only tools.

**Deliverables:**
- MCP server executable (`exe/codebase-console-mcp`)
- Tier 1 tools: `count`, `sample`, `find`, `pluck`, `aggregate`, `association_count`, `schema`, `recent`, `console_status`
- Safety layers 1-4: read-only connection, transaction rollback, statement timeout, structured tools
- Column redaction
- Result size caps

**Unlocks:** All six capability goals at a basic level. An agent can query live data alongside extraction data.

### Phase 2: High-Level Tools + Controlled Writes

**Goal:** Domain-aware tools that compose Tier 1 primitives, plus safe writes.

**Deliverables:**
- Tier 2 tools: `diagnose_model`, `data_snapshot`, `validate_record`, `check_setting`, `update_setting`, `check_policy`, `validate_with`, `check_eligibility`, `decorate`
- Safety layer 5: registered write actions with human confirmation
- Preset configurations (`:local`, `:docker`, `:production`)
- Class discovery for managers, policies, validators, decorators (auto-detect from app directory conventions)

**Unlocks:** Support diagnostics, data quality audits, policy/eligibility debugging, presentation previews, and controlled configuration changes without raw console access.

### Phase 3: Analytics Integration

**Goal:** Structured access to application performance and business metrics.

**Deliverables:**
- Tier 3 tools: `slow_endpoints`, `error_rates`, `throughput`, `job_queues`, `job_failures`, `job_find`, `job_schedule`, `redis_info`, `cache_stats`, `channel_status`
- Sidekiq adapter: reads Queue, RetrySet, DeadSet, ScheduledSet via Sidekiq API (Redis-backed)
- Solid Queue adapter: queries `solid_queue_jobs`, `solid_queue_failed_executions`, `solid_queue_scheduled_executions` tables
- GoodJob adapter: queries `good_jobs` table with status filtering
- Cache adapter: Redis key patterns, Solid Cache table stats, memory/file basic stats
- Mixed job framework support (Sidekiq workers + ActiveJob jobs in the same app)
- ActionCable subscription adapter queries (Redis or PostgreSQL)
- Configurable analytics model, job backend, and cache backend

**Unlocks:** Performance investigation and business intelligence queries through the agent, without building dashboards.

### Phase 4: Guarded Eval + Advanced Queries

**Goal:** Flexible query capabilities with appropriate guardrails.

**Deliverables:**
- Tier 4 tools: `console_eval` (human-approved), `console_sql` (read-only validated), `console_query` (structured builder)
- Statement validation for SQL (reject DML/DDL)
- Human confirmation flow for eval
- Audit logging for all Tier 4 invocations

**Unlocks:** Edge cases that structured tools can't cover — complex joins, custom aggregations, one-off investigations.

### Phase 5: Polish + Deployment Guide

**Goal:** Production-ready documentation and operational tooling.

**Deliverables:**
- Deployment guide for Docker, direct, and SSH modes
- Security hardening checklist
- Monitoring integration (ActiveSupport::Notifications events matching OPERATIONS.md patterns)
- Quick-start bridge script for evaluation without gem dependency
- Configuration validation and startup diagnostics

**Unlocks:** Teams can deploy confidently to staging/production environments.

---

## Open Questions

1. **Raw eval sandboxing approach.** `console_eval` (Tier 4) accepts arbitrary Ruby. Transaction rollback prevents persistent writes, but eval can still read sensitive data and consume resources. Options: method allowlist, AST inspection, or rely on human approval per invocation. Defer to Phase 4 experimentation.

2. **Multi-database support.** Rails 6+ supports multiple databases. The bridge currently connects to the primary database. Should it support `connects_to` for reading from specific databases? Defer until a client needs it.

3. **Session persistence between requests.** Should the bridge maintain instance variables across requests (e.g., caching a user lookup for follow-up queries)? Current design is stateless per request. Stateful sessions add complexity but reduce repeated queries.

4. **Concurrent agent sessions.** Can multiple agents share one bridge process, or does each need its own? Current design is single-session (one bridge per MCP server). Multi-session would need request multiplexing and per-session transaction isolation.

5. **Audit log storage location.** Tier 4 tool invocations should be logged. Options: bridge-side file log, application database table, or external service. File log is simplest but not queryable. Database table needs a migration. External service adds a dependency.

6. **Analytics provider abstraction.** Tier 3 tools assume analytics data is in the database. Apps using external analytics (Datadog, New Relic, Mixpanel, Amplitude) would need provider adapters. Amplitude support has been specifically requested — its event and cohort data would map well to the `throughput` and `data_snapshot` tool patterns. Is this worth the abstraction cost, or should Tier 3 focus on database-resident data first and add provider adapters (starting with Amplitude) as a follow-on?

7. **Bridge authentication.** The current design trusts the connection (Docker exec, local process, SSH with key auth). Should the bridge have its own authentication token for defense in depth? Adds complexity but prevents a local process from connecting to the bridge without authorization.
