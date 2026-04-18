# Console MCP Server Setup

The Console MCP Server gives AI tools (Claude Code, Cursor, Windsurf) live access to your Rails application: real database counts, record lookups, schema inspection, and job monitoring — all inside rolled-back transactions.

## Transport Options at a Glance

| Option | How it works | When to use |
|--------|-------------|-------------|
| [Stdio via rake](#option-a-stdio-via-rake-recommended) | Rake task boots Rails, runs MCP in-process | Local dev, simplest setup |
| [Docker](#option-b-docker) | Same rake task, piped through `docker exec -i` | Docker/Compose environments |
| [HTTP/Rack middleware](#option-c-http-rack-middleware) | Middleware mounts `/mcp/console` endpoint | Shared access, multiple clients |
| [SSH remote bridge](#option-d-ssh-remote-bridge) | Separate bridge process over stdio | Remote servers, production-adjacent |

---

## Option A: Stdio via Rake (Recommended)

The simplest setup. The `woods:console` rake task boots Rails, then starts the embedded MCP server using stdio transport. All queries run in-process via ActiveRecord — no separate bridge process needed.

### Prerequisites

1. `gem 'woods'` in your Gemfile
2. `bundle install`

### How It Works

The rake task does two things before starting the MCP server:

1. **Captures stdout before Rails boots.** Rails boot emits OpenTelemetry warnings, gem notices, and other output to stdout. An MCP client cannot parse these as JSON-RPC — they break the protocol. The rake task redirects stdout → stderr immediately, saves the real stdout fd, and restores it after boot completes.
2. **Calls `Rails.application.eager_load!`** to load all application models. Without eager loading, only the models that happen to be autoloaded before the first query appear in the registry.

### MCP Client Configuration

**Claude Code** (`.mcp.json` or `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
      "cwd": "/path/to/your/rails-app"
    }
  }
}
```

**Cursor / Windsurf** (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
      "cwd": "/path/to/your/rails-app"
    }
  }
}
```

### What Happens Under the Hood

```
MCP client (Claude Code)
  │
  │ spawns via stdio
  │
  ▼
rake woods:console
  │
  ├─ capture $stdout before boot
  ├─ Rake::Task[:environment].invoke  (Rails boots)
  ├─ load exe/codebase-console
  │    ├─ Rails.application.eager_load!
  │    ├─ build model registry from ActiveRecord::Base.descendants
  │    ├─ Server.build_embedded(model_validator:, safe_context:, ...)
  │    └─ MCP::Server::Transports::StdioTransport.new(server).open
  │
  └─ MCP server responds to tool calls via stdin/stdout
```

---

## Option B: Docker

Same embedded approach as Option A, but piped through `docker exec -i`. The `-i` flag keeps stdin open for the MCP protocol. The container must be running before the MCP client starts.

### Prerequisites

- Running container with Rails app
- `woods` gem in the container's Gemfile

### MCP Client Configuration

**Claude Code:**

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "your_app_web_1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

**Docker Compose** (when the service name is `web`):

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "compose-dev-web-1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

> **Note:** The container name in MCP config must match exactly what `docker ps` shows. Docker Compose generates names like `<project>-<service>-<index>`. Check with `docker ps --format '{{.Names}}'`.

### Environment Variables

If your Rails app requires environment variables at boot (credentials, database URL), pass them via `docker exec -e` or ensure they are set in the container already:

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "-e", "RAILS_ENV=development",
        "your_app_web_1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

---

## Option C: HTTP/Rack Middleware

Mount the console as a Rack middleware endpoint. The MCP client connects over HTTP using the streamable-http transport instead of spawning a subprocess. Useful when multiple clients need shared access, or when stdio subprocess spawning is not practical.

### Prerequisites

1. `gem 'woods'` in Gemfile
2. `bundle install`
3. A running Rails server accessible to the MCP client

### Rails Configuration

In an initializer (`config/initializers/woods.rb`):

```ruby
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_mcp_path = '/mcp/console'       # default
  config.console_redacted_columns = %w[password_digest api_key ssn]
end
```

The middleware registers itself automatically via the gem's Railtie when `console_mcp_enabled` is true. To mount it manually:

```ruby
# config/application.rb
config.middleware.use Woods::Console::RackMiddleware, path: '/mcp/console'
```

### MCP Client Configuration

**Claude Code** (streamable-http transport):

```json
{
  "mcpServers": {
    "rails-console": {
      "type": "streamable-http",
      "url": "http://localhost:3000/mcp/console"
    }
  }
}
```

For production or staging, use HTTPS and restrict the path with authentication middleware upstream.

### What Happens Under the Hood

The middleware lazy-initializes the MCP server on first request:

```
First HTTP request to /mcp/console
  │
  ├─ mutex-locked initialization
  │    ├─ Rails.application.eager_load!
  │    ├─ build model registry from ActiveRecord::Base.descendants
  │    └─ Server.build_embedded(...)
  │         └─ StreamableHTTPTransport wraps the server
  │
  └─ subsequent requests: transport.handle_request(rack_request)
```

Each request gets its own database connection from the connection pool. `SafeContext` wraps that connection in a rolled-back transaction.

### Security Note

The HTTP endpoint grants read access to live database data. In production environments:

- Restrict the path to internal networks or authenticated users
- Use `console_redacted_columns` to redact sensitive fields (see [Configuration Options](#configuration-options))
- Consider mounting only in `development` and `staging` environments

---

## Option D: SSH Remote Bridge

The original bridge architecture for cases where the MCP client cannot spawn a subprocess directly into the Rails environment (remote servers, production-adjacent access, air-gapped apps). The `woods-console-mcp` binary runs on the client side and connects to a bridge process inside the Rails environment.

### How It Works

```
MCP client
  │
  ├─ spawns: woods-console-mcp (reads console.yml)
  │
  ▼
ConnectionManager (on client)
  │
  │ JSON-lines over stdio (ssh or docker exec)
  │
  ▼
Bridge process (inside Rails environment)
  │
  └─ evaluates queries in Rails console
```

### Configuration

Create `~/.woods/console.yml` (or point `CODEBASE_CONSOLE_CONFIG` to any YAML file):

```yaml
# Direct process (same machine, different process)
connection:
  mode: direct

# Docker
connection:
  mode: docker
  service: web
  compose_file: docker-compose.yml

# SSH
connection:
  mode: ssh
  host: app.example.com
  user: deploy
  command: cd /app && bundle exec rails runner -
```

Override config path with environment variable:

```bash
CODEBASE_CONSOLE_CONFIG=/path/to/console.yml woods-console-mcp
```

### MCP Client Configuration

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "woods-console-mcp",
      "env": {
        "CODEBASE_CONSOLE_CONFIG": "/path/to/console.yml"
      }
    }
  }
}
```

> **Tier support:** The bridge architecture supports all 31 tools across all 4 tiers. The embedded approach (Options A–C) supports only Tier 1 tools — see [Tool Support by Mode](#tool-support-by-mode).

---

## Tool Support by Mode

All 31 tools are registered and visible in the MCP server regardless of transport. However, **Tier 2–4 tools return an "unsupported in embedded mode" error** when called via Options A–C (embedded executor). Only the bridge architecture (Option D) supports those tiers.

### Tier 1: Read-Only (9 tools) — Supported in all modes

| Tool | Description |
|------|-------------|
| `console_status` | Health check: available models and database adapter |
| `console_schema` | Column types, nullability, defaults; optionally includes indexes |
| `console_count` | Record count matching scope conditions |
| `console_sample` | Random sample of records (max 25) |
| `console_find` | Find a record by primary key or unique column |
| `console_pluck` | Extract column values with optional distinct (max 1000 rows) |
| `console_aggregate` | Run `sum`, `average`, `minimum`, `maximum`, or `count` on a column (column optional for `count`) |
| `console_association_count` | Count associated records for a specific record |
| `console_recent` | Recently created/updated records (max 50) |

### Tier 2: Domain-Aware (9 tools) — Bridge only

| Tool | Description |
|------|-------------|
| `console_diagnose_model` | Full model diagnostic: counts, recent records, aggregates |
| `console_data_snapshot` | Record with associations for debugging (depth 1–3) |
| `console_validate_record` | Run validations on an existing record with optional changes |
| `console_validate_with` | Validate attributes against a model without persisting |
| `console_check_setting` | Check a configuration setting value |
| `console_update_setting` | Update a setting (requires confirmation) |
| `console_check_policy` | Check authorization policy for a record and user |
| `console_check_eligibility` | Check feature eligibility for a record |
| `console_decorate` | Invoke a decorator and return computed attributes |

### Tier 3: Analytics (10 tools) — Bridge only

| Tool | Description |
|------|-------------|
| `console_slow_endpoints` | Slowest endpoints by response time |
| `console_error_rates` | Error rates by controller or overall |
| `console_throughput` | Request throughput over time |
| `console_job_queues` | Job queue statistics |
| `console_job_failures` | Recent job failures |
| `console_job_find` | Find a job by ID, optionally retry (requires confirmation) |
| `console_job_schedule` | Scheduled/upcoming jobs |
| `console_redis_info` | Redis server information by section |
| `console_cache_stats` | Cache store statistics |
| `console_channel_status` | ActionCable channel status |

### Tier 4: Guarded (3 tools) — Bridge only

| Tool | Description |
|------|-------------|
| `console_eval` | Execute arbitrary Ruby code (requires confirmation, 10s timeout) |
| `console_sql` | Execute read-only SQL — `SELECT` and `WITH...SELECT` only |
| `console_query` | Enhanced query builder with joins, grouping, and HAVING |

---

## Configuration Options

Set these in your Rails initializer:

```ruby
Woods.configure do |config|
  # Enable HTTP/Rack transport. Default: false.
  # Has no effect on stdio (rake) or bridge transports.
  config.console_mcp_enabled = true

  # URL path for the Rack middleware endpoint. Default: '/mcp/console'.
  config.console_mcp_path = '/mcp/console'

  # Column names to redact from all query results. Default: [].
  # Replaced with "[REDACTED]" in output.
  config.console_redacted_columns = %w[password_digest encrypted_password api_key ssn token]
end
```

### `console_redacted_columns`

Redaction applies to all tool results regardless of transport. When a result hash contains a redacted column, the value is replaced with `"[REDACTED]"` before the MCP response is sent.

```ruby
# Example: redact PII
config.console_redacted_columns = %w[email phone_number date_of_birth ssn]
```

The column names are matched by string, case-sensitive. Use the exact column names from your database schema.

### Unlocking `console_sql` / `console_query` in embedded mode

By default the embedded executor (Options A–C) blocks the Tier 4 read tools `console_sql` and `console_query` — they return an `"unsupported_in_embedded"` error pointing at this section. To enable them, pass `embedded_read_tools: true` when you mount the Rack middleware (Option C):

```ruby
# config/initializers/woods_console.rb
Rails.application.config.middleware.use \
  Woods::Console::RackMiddleware,
  path: '/mcp/console',
  embedded_read_tools: true
```

Security posture with the flag on:

| Layer | What it enforces |
|-------|------------------|
| `SqlValidator` denylist | Rejects INSERT / UPDATE / DELETE / DROP / TRUNCATE / ALTER / CREATE / REPLACE / UNION / multi-statement / comment-hidden injections before any DB interaction. Only `SELECT` and `WITH…SELECT` make it through. |
| `SafeContext` rollback | Every request runs inside a database transaction that is always rolled back, so even side-effecting reads (functions, settings) cannot persist. |
| Per-request connection pooling | Each HTTP request draws a fresh connection from `ActiveRecord::Base`'s pool — no shared mutable state between requests. |

These three layers make `embedded_read_tools: true` safe for read-only workloads. If your threat model requires stricter process isolation, keep the flag off and use the bridge architecture (Option D) instead, which runs the executor in a separate process.

The stdio transports (Options A and B) do not currently accept this flag — they always run with embedded reads disabled. Enable `embedded_read_tools` through the Rack middleware when you need `console_sql`/`console_query` without switching to a bridge.

---

## Safety Model

The embedded console implements multiple defense-in-depth layers. None of them depend on the transport option — they apply equally to stdio, Docker, and HTTP modes.

### Rolled-Back Transactions

Every tool invocation runs inside a database transaction that is **always rolled back**:

```ruby
@connection.transaction do
  set_timeout          # statement timeout before any query
  result = yield       # run the tool
  raise ActiveRecord::Rollback  # always roll back
end
```

This means:

- `console_eval` running `User.create!(...)` silently discards the write
- Any accidental mutation from a validation or callback is rolled back
- The database is left unchanged regardless of what the tool does

### Statement Timeout

Each transaction sets a statement timeout before any query runs. The default is **5000ms** (5 seconds). Timeout enforcement is adapter-specific:

| Adapter | Mechanism | Scope |
|---------|-----------|-------|
| PostgreSQL | `SET statement_timeout = '5000ms'` | All statement types |
| MySQL | `SET max_execution_time = 5000` | SELECT only (MySQL limitation) |
| Other | Best-effort (skipped gracefully) | — |

### SQL Validation (Tier 4 `console_sql`)

`SqlValidator` rejects non-read-only SQL at the string level, before any database interaction:

- **Allowed:** `SELECT`, `WITH...SELECT`, `EXPLAIN`
- **Rejected prefixes:** `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`
- **Rejected anywhere in query:** `UNION`, `INTO`, `COPY`
- **Rejected functions:** `pg_sleep`, `lo_import`, `lo_export`, `pg_read_file`, `pg_write_file`, `load_file`, `sleep`, `benchmark`
- **Rejected patterns:** multiple statements (semicolons), writable CTEs (`WITH ... AS (DELETE/UPDATE/INSERT ...)`), comment-hidden injections

### Model and Column Validation

Before any query runs, the model name is checked against the registry built from `ActiveRecord::Base.descendants`. Unrecognized model names raise `ValidationError` without touching the database. Column names are validated against the model's `column_names` before pluck, aggregate, and recent operations.

Scope hashes accept Ransack-style predicate suffixes (`_eq`, `_not_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`) — see the [cookbook](MCP_TOOL_COOKBOOK.md#scope-predicates) for the full table. Every column name in a suffixed key is validated before an Arel predicate is built, so SQL injection via column names is not possible.

---

## Troubleshooting

### MCP client shows no tools or "connection refused"

- **Rake/Docker:** Check that `cwd` in MCP config points to the Rails app root (where `Rakefile` lives).
- **HTTP:** Check that the Rails server is running and listening on the expected port. Try `curl http://localhost:3000/mcp/console` — a 200 or 405 means the middleware is mounted.
- **All modes:** Run `bundle exec rake woods:console` directly in a terminal. It should hang (waiting for MCP protocol input) rather than exit immediately. If it exits, check the error output.

### Rails boot noise breaks MCP protocol

The rake task redirects stdout to stderr before Rails boots specifically to prevent this. If you see JSON parse errors from the MCP client, check:

1. You are using `bundle exec rake woods:console`, not `rails runner exe/codebase-console` directly (the runner path handles this too, but via a different mechanism).
2. No `puts` or `print` calls run at boot in your initializers before the task can capture stdout.
3. Try running `bundle exec rake woods:console 2>/dev/null` to isolate — the MCP protocol output goes to stdout, Rails noise goes to stderr.

### Models not visible to `console_status`

`console_status` returns the list of models registered at startup. If a model is missing:

1. Check that it inherits from `ActiveRecord::Base` (not from an intermediate abstract class that doesn't itself inherit AR).
2. Check that `model.table_exists?` returns true — models for tables that don't exist are excluded.
3. Check that `eager_load!` succeeds. If your app has a directory that fails to load (e.g., `app/graphql/` requiring an uninstalled gem), Zeitwerk may abort early and skip models defined later alphabetically. Look for `NameError` in the boot output.

### `console_sql` rejects my query

`SqlValidator` is conservative by design. If a valid read-only query is rejected:

- `UNION` in any position is blocked — use `console_query` with joins instead.
- `EXPLAIN` is allowed; `EXPLAIN ANALYZE` runs the query and is also allowed.
- Queries with semicolons are blocked even if the second statement is a comment — strip trailing semicolons.

### Tier 2–4 tools return "unsupported in embedded mode"

The embedded executor (used in Options A–C) implements the 9 Tier 1 tools plus, when opted in, the two Tier 4 read tools `console_sql` and `console_query`.

- For `console_sql` and `console_query`: pass `embedded_read_tools: true` when mounting `Woods::Console::RackMiddleware` (see [Unlocking `console_sql` / `console_query` in embedded mode](#unlocking-console_sql--console_query-in-embedded-mode)).
- For everything else (`console_diagnose_model`, `console_eval`, domain-aware Tier 2 tools, Tier 3 analytics): switch to the bridge architecture (Option D) — the embedded executor does not implement those tools.

### Slow first request on HTTP/Rack middleware

The middleware lazy-initializes the MCP server on the first request, which includes `Rails.application.eager_load!`. This can take several seconds on large apps. Subsequent requests are fast. If you want to pre-warm, call a health check endpoint that touches the middleware path at app startup.

### Timeout errors on large models

The default statement timeout is 5000ms (5 seconds). If you are hitting timeouts on models with millions of rows, use `scope` to narrow the query:

```
console_count(model: "Order", scope: { status: "pending" })
```

The timeout is set per-transaction in `SafeContext` and is not currently configurable via `Woods.configure`. To change it, pass `timeout_ms:` to `SafeContext.new` directly if you are constructing the server programmatically.
