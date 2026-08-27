# Console MCP Server Setup

The Console MCP Server gives MCP-capable coding tools and agents live access to your Rails application: real database counts, record lookups, schema inspection, and job monitoring, all inside rolled-back transactions.

## Transport Options at a Glance

| Option | How it works | When to use |
|--------|-------------|-------------|
| [Stdio via rake](#option-a-stdio-via-rake-recommended) | Rake task boots Rails, runs MCP in-process | Local dev, simplest setup |
| [Docker](#option-b-docker) | Same rake task, piped through `docker exec -i` | Docker/Compose environments |
| [HTTP/Rack middleware](#option-c-http-rack-middleware) | Middleware mounts `/mcp/console` endpoint | Shared access, multiple clients |
| [Launcher wrapper](#option-d-launcher-wrapper) | Execs the embedded server directly, through Docker, or through SSH | Centralized process-launch config |

---

## Option A: Stdio via Rake (Recommended)

The simplest setup. The `woods:console` rake task boots Rails, then starts the embedded MCP server using stdio transport. All queries run in-process via ActiveRecord, no separate bridge process needed.

### Prerequisites

1. `gem 'woods'` in your Gemfile
2. `bundle install`
3. Deliberately enable Console MCP in `config/initializers/woods.rb` after reviewing the trust boundary:

```ruby
Woods.configure do |config|
  config.console_mcp_enabled = true
end
```

The stdio and Docker entry points exit with status 1 while this setting is false. Enabling it grants the MCP process live read access under the blocked-table, redaction, and credential-scanning controls described below.

### How It Works

The rake task does two things before starting the MCP server:

1. **Captures stdout before Rails boots.** Rails boot emits OpenTelemetry warnings, gem notices, and other output to stdout. An MCP client cannot parse these as JSON-RPC, they break the protocol. The rake task redirects stdout → stderr immediately, saves the real stdout fd, and restores it after boot completes.
2. **Calls `Rails.application.eager_load!`** to load all application models. Without eager loading, only the models that happen to be autoloaded before the first query appear in the registry.

### MCP Client Configuration

Add this server entry to your MCP client's project configuration:

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
MCP client
  │
  │ spawns via stdio
  │
  ▼
rake woods:console
  │
  ├─ capture $stdout before boot
  ├─ Rake::Task[:environment].invoke  (Rails boots)
  ├─ load exe/woods-console
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

**Plain Docker:**

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
        "compose", "exec", "-T", "web",
        "bundle", "exec", "rake", "woods:console"
      ],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

> **Note:** Compose uses the service name and `-T` to disable its pseudo-TTY. Plain `docker exec` uses the exact container name from `docker ps` and needs `-i` to keep stdin open.

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
  config.console_mcp_token = ENV.fetch('WOODS_CONSOLE_MCP_TOKEN')
  config.console_mcp_allowed_origins = [
    'https://rails.internal.example', # public Rails/MCP Host
    'https://agent.example'           # browser client Origin, when applicable
  ]
  config.console_redacted_columns =
    Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[ssn]
end
```

Set `WOODS_CONSOLE_MCP_TOKEN` to a random value of at least 32 characters in
the Rails server environment. The middleware stack registers automatically via
the gem's Railtie and requires `Authorization: Bearer <token>` on every Console
request. Missing or incorrect tokens receive `401 Unauthorized`.

For non-loopback access, `console_mcp_allowed_origins` must include the public
Rails/MCP host. If a browser-based client sends an `Origin` header from a
different host, include that exact origin too. This allow-list controls both
DNS-rebinding Host checks and browser CORS; keep Rails' own `config.hosts`, TLS,
and proxy rules aligned with it. Server-to-server clients normally omit
`Origin`, but their request `Host` must still be allowed.

Do not mount `Woods::Console::RackMiddleware` by itself. The Railtie composes
`OriginGuard`, `BearerAuth`, and the Console middleware in the supported order.

Streamable HTTP is stateless by default. For a legacy client that still
requires MCP session IDs, a custom guarded mount may pass `stateless: false`;
the default Railtie mount remains stateless.

### MCP Client Configuration

For an MCP client that supports Streamable HTTP:

```json
{
  "mcpServers": {
    "rails-console": {
      "type": "streamable-http",
      "url": "http://localhost:3000/mcp/console",
      "headers": {
        "Authorization": "Bearer <same WOODS_CONSOLE_MCP_TOKEN value>"
      }
    }
  }
}
```

For production or staging, use HTTPS in addition to the mandatory bearer token.

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

## Option D: Launcher Wrapper

`woods-console-mcp` is a process launcher. It replaces itself with the same
embedded server used by Options A-C, either directly or through `docker exec`
or `ssh`. It does not enable additional tool tiers.

This option requires the Woods gem and `woods-console-mcp` executable on the
host that runs the MCP client. If Woods exists only inside a container, use
[Option B](#option-b-docker) instead. When Woods is in a host application
bundle rather than installed as a standalone executable, launch it through
that bundle and set the application directory as `cwd`:

```json
{
  "command": "bundle",
  "args": ["exec", "woods-console-mcp"],
  "cwd": "/absolute/host/path/to/app"
}
```

### How It Works

```
MCP client
  │
  ├─ spawns: woods-console-mcp (reads console.yml)
  │
  ▼
ConnectionManager
  │
  └─ exec direct / docker exec -i / ssh
       └─ bundle exec rake woods:console
```

### Configuration

Create `~/.woods/console.yml` (or point `WOODS_CONSOLE_CONFIG` to any YAML file):

Direct:

```yaml
mode: direct
directory: /path/to/rails-app
command: bundle exec rake woods:console
```

Docker:

```yaml
mode: docker
container: my_app_web_1
command: bundle exec rake woods:console
```

SSH:

```yaml
mode: ssh
host: app.example.com
user: deploy
command: cd /app && bundle exec rake woods:console
```

Override config path with environment variable:

```bash
WOODS_CONSOLE_CONFIG=/path/to/console.yml woods-console-mcp
```

### MCP Client Configuration

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "woods-console-mcp",
      "env": {
        "WOODS_CONSOLE_CONFIG": "/path/to/console.yml"
      }
    }
  }
}
```

> **Tier support:** Every launcher target exposes the embedded surface: 9 Tier 1 tools by default, or 11 tools when `console_sql` and `console_query` are explicitly enabled.

---

## Tool Support by Mode

The codebase keeps schemas for 31 possible tools as an inventory. Supported
servers register only executable tools: the 9 Tier 1 tools by default, plus
`console_sql` and `console_query` when `embedded_read_tools: true` (or
`config.console_embedded_read_tools = true`). Tier 2, Tier 3, and
`console_eval` are not registered in any supported mode.

### Tier 1: Read-Only (9 tools): Supported in all modes

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

### Tier 2: Domain-Aware (9 tools): Inventory only, not executable

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

### Tier 3: Analytics (10 tools): Inventory only, not executable

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

### Tier 4: Guarded (3 tools): Read tools opt-in; eval inventory only

| Tool | Description |
|------|-------------|
| `console_eval` | Inventory schema only; not registered by supported modes |
| `console_sql` | Execute read-only SQL, `SELECT` and `WITH...SELECT` only |
| `console_query` | Enhanced query builder with joins, grouping, and HAVING |

`console_sql` and `console_query` register with `embedded_read_tools: true`.
`console_eval` remains unavailable; legacy unsafe-eval settings fail closed at boot.

---

## Configuration Options

Set these in your Rails initializer:

```ruby
Woods.configure do |config|
  # Master on/off switch for the Console MCP feature (Layer 0). Default: false.
  # Applies to every transport: stdio, launcher wrapper, and Rack.
  # When false, stdio entry points exit with a "disabled" notice and the Rack
  # middleware passes the request through to the host app untouched (the
  # console path is indistinguishable from an unknown route). Set to true only
  # after configuring the layers below that match your threat model.
  config.console_mcp_enabled = true

  # URL path for the Rack middleware endpoint. Default: '/mcp/console'.
  config.console_mcp_path = '/mcp/console'

  # HTTP Origin + Host allow-list. Defaults to loopback only. Non-loopback
  # Rack deployments must include their public MCP host; browser clients from
  # another origin need that exact origin listed too.
  config.console_mcp_allowed_origins = [
    'https://rails.internal.example',
    'https://agent.example'
  ]

  # Layer 1. Table names that must never appear in a response.
  # Default: Woods::DEFAULT_CONSOLE_BLOCKED_TABLES (8 tables, see below).
  # Matched against :model (resolved via ActiveRecord), :table, and :sql args.
  # A blocked table rejects the tool call at dispatch, before the executor runs.
  # Case-insensitive.
  config.console_blocked_tables = Woods::DEFAULT_CONSOLE_BLOCKED_TABLES + %w[authorizations]

  # Layer 2. Content-shape credential scanner. Walks the final response tree
  # and replaces credential-shaped substrings (Stripe sk_*, AWS AKIA*, GCP
  # private keys, GitHub ghp_*, generic high-entropy tokens) with "[REDACTED]".
  # Runs regardless of column naming, so it catches leaks that column-based
  # redaction alone would miss. Default: [] (every pattern active).
  #
  # Accepts a list of pattern symbols to skip. Useful when a rule produces
  # false positives in your data. Pass the :all sentinel to disable the
  # scanner entirely (no layer-2 processing runs).
  config.console_disabled_scanner_patterns = %i[stripe_publishable_key]
  # config.console_disabled_scanner_patterns = %i[all]  # disable scanner entirely

  # Layer 2 augmentation, boot-time credential index. Default: true.
  # Woods::Console::CredentialIndex walks Rails.application.credentials.config
  #     once at server boot and substring-redacts those values from every MCP
  #     response, so credentials whose shape no scanner pattern recognizes
  #     (Twilio auth tokens, hand-rolled HMAC seeds, third-party webhook
  #     signing keys) are still caught when their exact contents appear.
  # See "console_credential_defense_enabled" section below for scope and
  # multi-DB caveats.
  config.console_credential_defense_enabled = true

  # Layer 3. Column names to redact from all query results.
  # Default: Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS (~30 credential-shaped
  # columns, see below). Replaced with "[REDACTED]" in output.
  config.console_redacted_columns = Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[ssn]

  # Layer 3, EAV (key-value) redaction patterns. Default: [].
  # See `console_redacted_key_values` section below for the pattern contract.
  config.console_redacted_key_values = [
    { key_column: 'key', value_column: 'value',
      sensitive_keys: %w[stripe_access_token oauth_token] }
  ]

  # Unlock console_sql / console_query in the embedded executor. Default: false.
  # Flows through to the Rack middleware AND the stdio entry point (rake / rails runner).
  # See "Unlocking console_sql / console_query in embedded mode" below.
  config.console_embedded_read_tools = false
end
```

### `console_mcp_enabled` (Layer 0: feature gate)

Until this flag is `true`, none of the transports route traffic:

- `exe/woods-console` prints a notice to stderr and exits 1. `exe/woods-console-mcp` execs that target, so MCP clients see the same startup failure.
- `Woods::Console::RackMiddleware` passes the request through to the host app (typically its 404), so a disabled console path is indistinguishable from an unknown route. Non-matching paths always pass through untouched.

Keep the flag off in environments where the Console isn't needed (production web tier, CI). Flip it on per-environment, e.g. in `config/environments/development.rb` or a staging-only initializer, once the layers below are configured for that environment's threat model.

### `console_blocked_tables` (Layer 1: table gate)

Entries are lowercased table names. A tool call is rejected at dispatch time when:

- `:model` argument resolves to a model whose `table_name` is blocked
- `:table` argument names a blocked table
- `:sql` argument references a blocked table (matched on identifier tokens, case-insensitive)

**Ships with a curated default list** (`Woods::DEFAULT_CONSOLE_BLOCKED_TABLES`, 8 tables) covering common auth/credential storage across Devise, Doorkeeper, Rodauth, Sorcery, OmniAuth, and hand-rolled token systems: `sessions`, `api_keys`, `credentials`, `oauth_applications`, `oauth_access_tokens`, `oauth_refresh_tokens`, `identities`, `active_storage_blobs`.

`users` / `accounts` are intentionally excluded, many apps expose safe columns from these and should decide explicitly, as are PII-heavy but auth-unrelated tables (`payments`, `addresses`), which are an org-specific compliance concern.

Extend or override rather than reassigning blindly:

```ruby
# Extend: keep all defaults plus app-specific tables
config.console_blocked_tables = Woods::DEFAULT_CONSOLE_BLOCKED_TABLES + %w[authorizations settings]

# Remove a default that over-blocks in your app
config.console_blocked_tables = Woods::DEFAULT_CONSOLE_BLOCKED_TABLES - %w[active_storage_blobs]

# Replace entirely: only do this if you've audited the default list against your schema
config.console_blocked_tables = %w[only_this]

# Disable Layer 1 entirely (other layers still apply)
config.console_blocked_tables = []
```

Use this to wall off tables that shouldn't appear in agent context regardless of redaction posture, EAV credential stores, audit logs with full request bodies, or PII stores with legal access restrictions. Rejection is observable via the `console.table_gate.rejected` structured log line.

### `console_disabled_scanner_patterns` (Layer 2: content scanner)

The scanner runs after Layer 3 redaction, so it catches credential shapes that column and EAV patterns miss, e.g. a Stripe key pasted into a free-text `note` field, a JWT returned from a custom SQL query, or an access token logged by a callback. See `lib/woods/console/credential_scanner.rb` for the full rule list.

Scanner hits emit a `console.credential_scan.hits` warn-level structured log line with per-pattern counts, so you can audit how often the net fires in practice. Prefer fixing the upstream cause (moving the secret out of the leaking column) over disabling a rule, per-pattern opt-outs are an escape hatch, not a primary knob.

Setting `console_disabled_scanner_patterns = %i[all]` disables the entire scanner. No layer-2 processing runs. Layer 3 (column + EAV redaction) and Layer 4 (SqlValidator + SafeContext) continue to fire. Use this only when the pattern scanner interferes with a legitimate workflow and the remaining layers cover the threat model; prefer a per-pattern opt-out otherwise.

### `console_credential_defense_enabled` (boot-time credential index)

`Woods::Console::CredentialIndex` walks `Rails.application.credentials.config`
once at server boot, collects string leaves with length >= 12, and
substring-redacts those values from every MCP response. `console_eval` is not
registered in a supported mode, so this setting does not enable eval.

**Restart required after credential rotation.** The index is built once at process start and held in memory for the lifetime of the MCP process. When a host app rotates Rails credentials (`rails credentials:edit`), the MCP process keeps the pre-rotation secrets in its Set until the process is restarted, new secrets are not picked up automatically. Only the Layer 2 shape-pattern scanner (Stripe `sk_*`, AWS `AKIA*`, etc.) can catch newly-rotated values before restart.

**Rebuild hook for rotation jobs.** If you rotate credentials from a Rake task or a deployment hook and want to avoid a full restart, call:

```ruby
Woods::Console::Server.rebuild_credential_index(rails_app: Rails.application)
```

This rebuilds the index from the current credentials and hot-swaps it into the active scanner. The swap is atomic on MRI, in-flight scans see either the old or the new index, never a partial one. The method is a no-op (returns `nil`) when no server has been built yet or when `console_credential_defense_enabled` is `false`.

**Rotation warning.** At boot time, Woods checks whether any credentials file (`config/credentials.yml.enc`, `config/credentials/<env>.yml.enc`) was modified *after* the process started. When it detects this, it emits a `console.credential_index.stale` warn-level structured log line with the file path, mtime, and a hint to restart or call `rebuild_credential_index`. This check is on by default; disable it with:

```ruby
config.console_credential_rotation_warning = false
```

**Multi-DB / sharded caveat.** The index reflects only the credentials available to the *Rails process* that boots the Console MCP server. A separate database that holds its own secrets (e.g., a vendored CMS app sharing the same Rails host) is not in scope, for those, lean on Layer 3 (`console_redacted_columns` / `console_redacted_key_values`) and Layer 1 (`console_blocked_tables`).

**Missing master key.** In environments without `config/master.key` (CI, fresh checkouts), the index build catches `MissingKeyError` / `InvalidMessage` by class name and returns an empty index. The server still boots and the configured table, scanner, and redaction layers remain in effect.

Set the flag to `false` only when the host intentionally opts out of exact-value credential indexing and the remaining scanner/redaction layers cover its response data.

### `console_redacted_columns`

Redaction replaces matching column values with `"[REDACTED]"` before the MCP response is sent. Column names are matched by string, case-sensitive, use the exact names from your database schema.

Redacted columns are also **refused as query inputs**: as the `column` of `console_aggregate`, as a scope or `by:` key (including `_matches` forms), and as `order_by`. Masking output alone would leave a comparison oracle over the secret.

**Ships with a curated credential default list** (`Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS`, ~30 columns) covering Devise, Doorkeeper, Rodauth, has_secure_password, devise-two-factor, and common hand-rolled auth shapes: `password`, `password_digest`, `encrypted_password`, `crypted_password`, `salt`, `otp_secret`, `encrypted_otp_secret`, `two_factor_secret`, `backup_codes`, `reset_password_token`, `confirmation_token`, `unlock_token`, `remember_token`, `invitation_token`, `access_token`, `refresh_token`, `auth_token`, `api_token`, `api_key`, `bearer_token`, `client_secret`, `webhook_secret`, `signing_secret`, `session_secret`, `private_key`, `encrypted_private_key`, `key_hash`, `token`, `secret`.

Extend or override rather than reassigning blindly:

```ruby
# Extend: keep all defaults plus app-specific columns
config.console_redacted_columns = Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[cart_token share_token]

# Add PII on top of the credential defaults
config.console_redacted_columns = Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[email phone_number ssn]

# Remove a default that over-redacts in your app (e.g., `token` is a non-secret slug)
config.console_redacted_columns = Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS - %w[token]

# Replace entirely: only do this if you've audited the default list against your schema
config.console_redacted_columns = %w[password_digest api_key]
```

Columns intentionally **excluded** from the default list because they cause over-redaction in apps that use them legitimately:

- `key`: ActiveStorage blob keys, EAV key columns, translation keys
- `name`: universal non-secret identifier
- PII columns (`ssn`, `tax_id`, `dob`), org-specific compliance concern, prefer explicit opt-in

Redaction is shape-aware and covers every tool that returns row data:

| Tool                                  | Output shape                                              | How redaction applies |
| ------------------------------------- | --------------------------------------------------------- | --------------------- |
| `console_find`                        | `{record: Hash}`                                          | Redacted column keys are replaced inside the nested record |
| `console_sample`, `console_recent`    | `{records: [Hash, ...]}`                                  | Each record hash is redacted |
| `console_sql`, `console_query`        | `{columns: [...], rows: [[...], ...], count: N}`          | Positional, rows are redacted by matching the `columns` header |
| `console_pluck`                       | `{columns: [...], values: [[...], ...]}` or `{values: [...]}` for a single column | Positional, multi-column rows and flat single-column arrays both covered |
| `console_count`, `console_aggregate`, `console_association_count`, `console_schema` | No row data | Nothing to redact |

Redaction is defense-in-depth, prefer not storing plaintext secrets in database columns in the first place, but it keeps configured credential columns out of the agent's transcript when `console_sample`, `console_find`, or the Tier 4 read tools return matching rows.

### `console_redacted_key_values`

Column-name redaction falls short when credentials are stored in a **key-value (EAV)** table, e.g. a Stripe Connect `authorizations` row of `{key: "stripe_access_token", value: "sk_live_..."}`. The column holding the secret is called `value`, which is generic: adding `value` to `console_redacted_columns` would over-redact every unrelated row in the table.

`console_redacted_key_values` takes one or more patterns that describe "when a row has `key_column` set to one of these names, redact its `value_column`":

```ruby
# Example: an `authorizations` table: pattern works on both MySQL and PostgreSQL.
config.console_redacted_key_values = [
  {
    key_column:     'key',
    value_column:   'value',
    sensitive_keys: %w[stripe_access_token stripe_publishable_key stripe_user_id
                       oauth_token refresh_token client_secret]
  }
]
```

```ruby
# An app with a generic `settings` table on MySQL or PostgreSQL uses a different
# column layout: patterns stack without interfering.
config.console_redacted_key_values = [
  { key_column: 'name', value_column: 'value',
    sensitive_keys: %w[smtp_password slack_webhook_url] },
  { key_column: 'key',  value_column: 'value',
    sensitive_keys: %w[stripe_access_token oauth_token] }
]
```

Behavior:

| Response shape                                                        | EAV redaction applies when                                          |
| --------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `console_find`, `{record: {..., key: ..., value: ...}}`              | `record[key_column]` ∈ `sensitive_keys` → `record[value_column] = "[REDACTED]"` |
| `console_sample`, `console_recent`, `{records: [{key:, value:}, ...]}` | Per-row, each record is evaluated against every configured pattern |
| `console_sql`, `console_query`, `{columns: [...], rows: [[...]]}`    | Positional, `key_column` and `value_column` resolved to indexes once, per row lookup afterwards |
| `console_pluck`, `{columns: [...], values: [[...]]}`                 | Same positional logic as `rows`                                     |

A pattern is skipped silently when its `key_column` or `value_column` is absent from the current `columns` header, so unrelated queries pay nothing for the configuration. Comparison is case-sensitive and coerces the key cell through `to_s` before matching, so `:stripe_access_token` and `"stripe_access_token"` both fire.

`console_redacted_columns` and `console_redacted_key_values` run in a single pass, configure both for apps that store credentials in both dedicated columns (e.g. `crypted_password`) and EAV rows (e.g. `authorizations.value`).

### Unlocking `console_sql` / `console_query`

All three embedded transports (Options A, B, C) and the launcher wrapper
(Option D) start the same embedded server, so they all read one setting:
`console_embedded_read_tools`. Default `false`, `console_sql` and
`console_query` return an `error_type: "unsupported"` refusal without ever
touching ActiveRecord, and neither is registered in `tools/list`.

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.console_mcp_enabled           = true     # mount the Rack middleware via Railtie
  config.console_mcp_token             = ENV.fetch('WOODS_CONSOLE_MCP_TOKEN')
  config.console_embedded_read_tools   = true     # unlock console_sql / console_query
  config.console_redacted_columns      = Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS
end
```

With the flag on, every request through `console_sql` / `console_query` runs
these controls, in order:

1. `SqlValidator` rejects DML/DDL (`INSERT`/`UPDATE`/`DELETE`/`DROP`/`TRUNCATE`/`ALTER`/`CREATE`/`REPLACE`), `UNION`/`INTO`/`COPY`, multi-statement and comment-hidden injections, and most administrative keywords (`DO`, `SET`, `LISTEN`, `NOTIFY`, `CALL`, `LOAD`, `VACUUM`, `PREPARE`, transaction control, `EXPLAIN ANALYZE`) at the string level. Enforces a read-only **function allowlist** (`ALLOWED_FUNCTIONS`), anything not on it is rejected by name, quoted forms (`"pg_terminate_backend"(…)`) included. Only `SELECT`, `WITH…SELECT`, and plain `EXPLAIN` pass.
2. `TableGate` refuses any SQL, model, or join that touches a `console_blocked_tables` entry.
3. `SafeContext` wraps every request in a rolled-back transaction with a short statement timeout. **It does NOT cover async side effects**: ActiveJob `perform_later`, ActionMailer `deliver_later`, direct HTTP egress, `Thread.new`-spawned work, `after_rollback` callbacks, and writes through a different shard all execute as live. Treat the Console MCP as an admin-trust boundary, not a sandbox.
4. `CredentialScanner` + column/EAV redaction scrub results.

Keep the flag off when the host requires a narrower database capability.

---

## Safety Model

The executable Console surface uses the following defense layers in every
supported transport (stdio, Docker/SSH launcher, and HTTP).

| # | Layer | Knob | Fires at | Purpose |
|---|-------|------|----------|---------|
| 0 | Feature gate | `console_mcp_enabled` | Process start / request entry | Master on/off switch, feature is inert until an operator opts in |
| 1 | Blocked tables | `console_blocked_tables` | Tool dispatch, before executor | Reject any tool call that touches a named table (model, table, or sql arg) |
| 2 | Credential scanner | `console_disabled_scanner_patterns` (`[:all]` to disable entirely) | After executor, before render | Content-shape redaction of credential-shaped strings anywhere in the response tree |
| 3 | Column + EAV redaction | `console_redacted_columns`, `console_redacted_key_values` | After executor, before Layer 2 | Identity-based redaction by column name and by key/value row shape |
| 4 | SqlValidator + SafeContext | built-in | Inside executor | SQL deny-list for `console_sql`; transaction-rollback for every request |

Layers 0–3 are configured via `Woods.configure`. Layer 4 is always on and has no knobs. Observability hooks, `console.table_gate.rejected` for Layer 1, `console.credential_scan.hits` for Layer 2, emit structured log lines via `Woods::Observability::StructuredLogger` so operators can audit enforcement without scraping MCP wire traffic.

### Confirmation and Audit Inventory

No currently executable tool claims a confirmation or privileged audit-log
contract. Tier 2, Tier 3, and `console_eval` remain unregistered inventory.

### Current-Connection Rollback

Database work performed through the request's current Active Record connection
runs inside a transaction that is **always rolled back**:

```ruby
def with_rolled_back_transaction
  @connection.transaction do
    set_timeout                   # statement timeout before any query
    yield                         # run the tool
    raise ActiveRecord::Rollback  # always roll back
  end
end
```

This means direct mutations on that connection are discarded. It is a final
guard for ordinary database work, not a sandbox or a universal side-effect
guarantee. It does **not** undo Active Job or mail delivery, HTTP/network calls,
threaded work, `after_rollback` callbacks, or writes through another connection
or shard. The validator, table gate, credential defenses, and operator trust
boundary remain necessary.

- Direct accidental mutation on the wrapped connection is rolled back.
- External, asynchronous, callback, and cross-connection effects may execute live.

### Statement Timeout

Each transaction sets a statement timeout before any query runs. The default is **5000ms** (5 seconds). Timeout enforcement is adapter-specific:

| Adapter | Mechanism | Scope |
|---------|-----------|-------|
| PostgreSQL | `SET statement_timeout = '5000ms'` | All statement types |
| MySQL | `SET max_execution_time = 5000` (session scope; the prior value is restored after the transaction) | SELECT only (MySQL limitation) |
| Other | Best-effort (skipped gracefully) | n/a |

### SQL Validation (Tier 4 `console_sql`)

`SqlValidator` rejects non-read-only SQL at the string level, before any database interaction:

- **Allowed prefixes:** `SELECT`, `WITH...SELECT`, and plain `EXPLAIN`. `EXPLAIN ANALYZE` is rejected, it executes the query rather than just planning it (both the whitespace and `EXPLAIN (ANALYZE, …)` option-list spellings).
- **Rejected prefixes:** `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`
- **Rejected anywhere in query:** `UNION`, `INTO`, `COPY`
- **Function allowlist (the authoritative function control):** every function-call-shaped identifier must appear in `ALLOWED_FUNCTIONS`, a conservative set of pure read-only functions (aggregates, window functions, string/number/date/JSON readers) kept portable across MySQL, PostgreSQL, and SQLite. Anything else is rejected by name, quoted forms (`"pg_terminate_backend"(…)`) included. This is an allowlist because a denylist cannot enumerate every side-effecting function (`nextval`, `pg_advisory_lock`, `pg_terminate_backend`, …). A legacy `DANGEROUS_FUNCTIONS` denylist (`pg_sleep`, `lo_import`, `lo_export`, `pg_read_file`, `pg_write_file`, `load_file`, `sleep`, `benchmark`) still runs first as belt-and-suspenders.
- **Rejected patterns:** multiple statements (semicolons), writable CTEs (`WITH ... AS (DELETE/UPDATE/INSERT ...)`), comment-hidden injections

### Model and Column Validation

Before any query runs, the model name is checked against the registry built from `ActiveRecord::Base.descendants`. Unrecognized model names raise `ValidationError` without touching the database. Column names are validated against the model's `column_names` before pluck, aggregate, and recent operations.

For `console_query`, a schema-qualified column reference such as `orders.total` is validated for **ownership**: the table side is gated through `TableGate` (a blocked table is refused) and the column must actually exist on that table, so a blocked-table column cannot be smuggled through `select`, `order`, or `having`. Bare columns validate against the active model.

Scope hashes accept Ransack-style predicate suffixes (`_eq`, `_not_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`), see the [cookbook](MCP_TOOL_COOKBOOK.md#scope-predicates) for the full table. Every column name in a suffixed key is validated before an Arel predicate is built, so SQL injection via column names is not possible.

---

## Troubleshooting

### MCP client shows no tools or "connection refused"

- **Rake/Docker:** Check that `cwd` in MCP config points to the Rails app root (where `Rakefile` lives).
- **HTTP:** Check that the Rails server is running and listening on the expected port. An unauthenticated `curl http://localhost:3000/mcp/console` should return `401` when the enabled middleware and bearer-auth guard are mounted. A request with the configured bearer token proceeds to MCP protocol handling.
- **All modes:** Run `bundle exec rake woods:console` directly in a terminal. It should hang (waiting for MCP protocol input) rather than exit immediately. If it exits, check the error output.

### Rails boot noise breaks MCP protocol

The rake task redirects stdout to stderr before Rails boots specifically to prevent this. If you see JSON parse errors from the MCP client, check:

1. You are using `bundle exec rake woods:console`, not `rails runner exe/woods-console` directly (the runner path handles this too, but via a different mechanism).
2. No `puts` or `print` calls run at boot in your initializers before the task can capture stdout.
3. Try running `bundle exec rake woods:console 2>/dev/null` to isolate, the MCP protocol output goes to stdout, Rails noise goes to stderr.

### Models not visible to `console_status`

`console_status` returns the list of models registered at startup. If a model is missing:

1. Check that it inherits from `ActiveRecord::Base` (not from an intermediate abstract class that doesn't itself inherit AR).
2. Check that `model.table_exists?` returns true, models for tables that don't exist are excluded.
3. Check that `eager_load!` succeeds. If your app has a directory that fails to load (e.g., `app/graphql/` requiring an uninstalled gem), Zeitwerk may abort early and skip models defined later alphabetically. Look for `NameError` in the boot output.

### `console_sql` rejects my query

`SqlValidator` is conservative by design. If a valid read-only query is rejected:

- `UNION` in any position is blocked, use `console_query` with joins instead.
- Plain `EXPLAIN` is allowed; `EXPLAIN ANALYZE` is **rejected** because it executes the query rather than just planning it.
- A function is rejected unless it is on the read-only allowlist (`ALLOWED_FUNCTIONS`). If a legitimate pure/read function is missing, that is the list to extend, deliberately.
- Queries with semicolons are blocked even if the second statement is a comment, strip trailing semicolons.

### A tool from the 31-schema inventory is not listed

See [Tool Support by Mode](#tool-support-by-mode): only 9 (or 11 with
`console_embedded_read_tools`) are ever registered. For `console_sql` /
`console_query`, see [Unlocking `console_sql` / `console_query`](#unlocking-console_sql--console_query). Tier 2, Tier 3, and `console_eval` are inventory-only in every mode, no flag registers them.

### `console_eval` and `WOODS_CONSOLE_UNSAFE_EVAL`

`console_eval` is not registered by a supported server mode. Setting
`WOODS_CONSOLE_UNSAFE_EVAL=true`, enabling the equivalent configuration flag,
or passing the legacy confirmation/audit options causes server construction to
fail closed with `Woods::ConfigurationError`.

### Slow first request on HTTP/Rack middleware

The middleware lazy-initializes the MCP server on the first request, which includes `Rails.application.eager_load!`. This can take several seconds on large apps. Subsequent requests are fast. If you want to pre-warm, call a health check endpoint that touches the middleware path at app startup.

### Timeout errors on large models

The default statement timeout is 5000ms (5 seconds). If you are hitting timeouts on models with millions of rows, use `scope` to narrow the query:

```
console_count(model: "Order", scope: { status: "pending" })
```

The timeout is set per-transaction in `SafeContext` and is not currently configurable via `Woods.configure`. To change it, pass `timeout_ms:` to `SafeContext.new` directly if you are constructing the server programmatically.
