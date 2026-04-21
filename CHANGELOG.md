# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Console MCP re-enabled behind a five-layer defense-in-depth stack.** The feature was previously disabled at its entry points after an audit flagged a Stripe Connect credential leak via the `authorizations` EAV table. It now ships gated on a new `console_mcp_enabled` config flag (default `false`) and runs through five independent safety layers, so a single misconfigured layer cannot leak secrets:
  - **Layer 0 — feature gate.** `exe/woods-console-mcp`, `exe/woods-console`, and `Woods::Console::RackMiddleware` all short-circuit with a helpful "disabled" notice (stderr + exit 1 for stdio, `410 Gone` with JSON body for HTTP) when `Woods.configuration.console_mcp_enabled` is false. Hosts that have mounted the middleware see no change in behavior until they opt in.
  - **Layer 1 — blocked tables (`console_blocked_tables`).** Rejects a tool call at dispatch time — before the executor is invoked — when any `:model`, `:table`, or `:sql` argument resolves to a configured blocked table. Built on `Woods::Console::TableGate`. Embedded transports now pass a `model_tables` registry so model-scoped tools (`console_find`, `console_sample`, etc.) can resolve model names to their tables without a database round-trip.
  - **Layer 2 — credential scanner (`console_credential_scanning_enabled`, default `true`).** `Woods::Console::CredentialScanner` walks the final response tree and replaces credential-shaped substrings (Stripe `sk_live_*` / `sk_test_*`, AWS `AKIA*`, GitHub `ghp_*` / `github_pat_*`, GCP service-account private keys, generic high-entropy tokens) with `[REDACTED]`. This catches leaks regardless of where the value landed in the response shape — a row, a sub-hash, a positional array — and regardless of whether the column name looked sensitive. Individual rules can be disabled per-deployment via `console_disabled_scanner_patterns` (array of pattern symbols).
  - **Layer 3 — column + EAV redaction (`console_redacted_columns`, `console_redacted_key_values`).** Identity-based redaction for columns and key/value rows. Preserved verbatim from the prior release. See the two entries below for the shape-aware descent logic and EAV pattern contract.
  - **Layer 4 — SqlValidator deny-list + SafeContext rollback.** Unchanged from prior releases. `console_sql` still rejects DML/DDL at the string level before any database interaction, and every request runs inside a transaction that is always rolled back.
  - **Observability.** Layer 1 rejections emit a `console.table_gate.rejected` structured log line (level `warn`, includes tool name and model). Layer 2 hits emit `console.credential_scan.hits` with per-pattern counts, so operators can see when the net caught something rather than relying on in-band MCP response metadata. The logger is pluggable through `Woods::Observability::StructuredLogger` — operator logging pipelines can consume it without parsing the MCP wire format.
  - **Upgrade path.** Hosts running on the disabled release that mounted `Woods::Console::RackMiddleware`: set `config.console_mcp_enabled = true` in your Woods initializer once you've configured the layers that apply to your threat model. The flag is opt-in by design — no host automatically re-enables the feature on upgrade. See `docs/CONSOLE_MCP_SETUP.md` for the full posture walkthrough and per-layer tuning guidance.
  - **Scope.** The Index MCP server (`woods-mcp`, `woods-mcp-http`) and every extraction workflow remain unaffected — they were never in scope for the audit and ship unchanged.

- **`console_redacted_columns` now covers every tool that returns row data.** Redaction previously only walked top-level hash keys, so `console_sample`, `console_recent`, `console_find`, `console_pluck`, `console_sql`, and `console_query` returned configured credential columns in the clear — records were nested under `records` / `record`, and rows were positional arrays under `rows` / `values`. The server-level redaction pass is now shape-aware: it descends into `record` / `records` hashes and uses the `columns` header to redact positional rows. `console_pluck` now also includes a `columns` field in its response so positional redaction can key off of it. Affects every transport (stdio, Rack, bridge).
- **`console_redacted_key_values` for EAV (key-value) credential storage.** Column-name redaction cannot protect tables that store sensitive values in a generically named column (e.g. a Stripe Connect `authorizations` row of `{key: "stripe_access_token", value: "sk_live_..."}`): adding `value` to `console_redacted_columns` over-redacts every unrelated row. The new `console_redacted_key_values` config accepts one or more `{key_column:, value_column:, sensitive_keys: []}` patterns — when a row's `key_column` cell matches one of `sensitive_keys`, the same row's `value_column` cell is replaced with `[REDACTED]`. Applies across every response shape (`record`, `records`, positional `rows` / `values`) and every transport. Empty by default — configure it in `Woods.configure` to cover the EAV credential tables specific to your app.
- **TableGate now resolves `joins:` and `association:` arguments through model reflections.** `console_query` (via `joins:`) and `console_association_count` (via `association:`) previously bypassed Layer 1 entirely — an agent could reach `authorizations` rows by joining through a non-blocked model. The gate now accepts a `model_reflections` registry (association name → target table, built at boot from `reflect_on_all_associations`) and rejects any join or association whose target is on `console_blocked_tables`. Polymorphic and reflection-raising associations are skipped gracefully. Exposed via new `TableGate#check_joins!` and `#check_association!` entry points.
- **TableGate now catches ANSI-89 comma-joins.** `SELECT * FROM users, authorizations WHERE …` previously slipped past the gate because the old regex only matched the first identifier after `FROM` and explicit `JOIN` tokens. The gate now walks every `FROM` clause, splits on top-level commas (parenthesis-depth aware, so subqueries don't mislead it), and rejects a blocked table in any position of the list. Case, schema prefix, and quoted identifiers (`"authorizations"`, `` `authorizations` ``) are all handled.
- **TableGate now catches blocked tables inside CTE bodies, UNION branches, and FROM-clause subqueries.** The non-greedy `FROM_CLAUSE` regex previously terminated on `WHERE`/`JOIN`/`;`/`)` — but not on a nested `FROM` — so `SELECT * FROM (SELECT * FROM authorizations) AS a`, `WITH a AS (SELECT * FROM authorizations) SELECT * FROM a`, and `SELECT id FROM users UNION SELECT id FROM authorizations` would consume the outer clause and never re-scan the inner table. Treating `\bFROM\b` as a terminator makes every `FROM` occurrence its own independent `.scan` match, closing the H-3 bypass. Specs cover all three shapes.
- **Safer-by-default column redaction list.** `console_redacted_columns` previously defaulted to `[]`, so a host that enabled Console MCP without configuring Layer 3 got zero column redaction. The gem now seeds `console_redacted_columns` with a curated list of ~30 credential columns that appear across Devise, Doorkeeper, Rodauth, has_secure_password, devise-two-factor, and hand-rolled auth code: `password`, `password_digest`, `encrypted_password`, `crypted_password`, `salt`, `otp_secret`, `encrypted_otp_secret`, `two_factor_secret`, `backup_codes`, `reset_password_token`, `confirmation_token`, `unlock_token`, `remember_token`, `invitation_token`, `access_token`, `refresh_token`, `auth_token`, `api_token`, `api_key`, `bearer_token`, `client_secret`, `webhook_secret`, `signing_secret`, `session_secret`, `private_key`, `encrypted_private_key`, `key_hash`, `token`, `secret`, plus `password_salt`/`consumed_timestep`. Exposed via `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` so hosts can extend (`Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[extra]`) or override (`%w[only these]`). Intentionally excludes `key` (ActiveStorage blob keys, EAV key columns) and PII columns (org-specific compliance).
- **CredentialScanner ships with 8 additional gateway patterns.** The Layer 2 content scanner now catches `github_pat_` fine-grained PATs, SendGrid API keys (`SG.xxx.yyy`), Mailgun API keys (`key-<32 hex>`), Anthropic API keys (`sk-ant-api**-***`), OpenAI API keys (`sk-` and `sk-proj-`), Shopify access tokens (`shpat_`, `shpca_`, `shpss_`, `shppa_`), Square access tokens (`sq0xxx-***`), and PayPal access tokens (`access_token$production$…$…`). Pattern order is specific-before-generic so Anthropic hits increment `:anthropic_api_key` rather than falling through to `:openai_api_key`. Total active patterns: 17.
- **TableGate now strips PostgreSQL dollar-quoted literals before scanning.** `SELECT $tag$FROM authorizations$tag$ …` would previously trigger a false match on the literal's contents; the gate now collapses `$…$…$…$` and `$tag$…$tag$` pairs to an empty string in the same pre-scan pass as SQL comments and single-quoted strings. Stripping order matters: dollar-quotes are removed before single-quotes so a stray apostrophe inside a dollar-quoted literal cannot fool the single-quote scanner.
- **One-time observability warning when the structured logger fails.** `Woods::Console::Server` previously swallowed every `StructuredLogger` exception silently — an operator misconfiguring the log sink would see no signal that Layer 1 rejections and Layer 2 hits were being lost. The first failure now prints a single `[woods-console]` warning to stderr naming the exception class and message; subsequent failures remain silent so a broken sink cannot flood the log. Behavior on a working logger is unchanged.
- **Credential scanner docstring uses an obvious placeholder.** The `@example` block in `Woods::Console::CredentialScanner` previously contained a Stripe-shaped value that matched its own pattern. Replaced with a clearly synthetic example so the doc cannot be mistaken for a real token during audits.
- **TableGate now catches blocked tables written as quoted schema-qualified identifiers.** `SELECT * FROM "public"."authorizations"` and `` SELECT * FROM `app`.`authorizations` `` previously slipped past Layer 1 because the regex captured only the first quoted segment (`"public"`) and the second (`"authorizations"`) was discarded. Both `LEAD_IDENT` and `JOIN_REFERENCE` now capture an optional quoted-schema prefix separately, and the joined `schema.table` form is passed to `#blocked?` so a configured entry of either `"authorizations"` (bare) or `"public.authorizations"` (qualified) matches as the operator expects. Closes a TableGate bypass on PostgreSQL and MySQL.
- **TableGate now recognizes MySQL `STRAIGHT_JOIN` as a join keyword.** `SELECT * FROM users STRAIGHT_JOIN authorizations …` previously slipped past Layer 1 because the `\bJOIN` boundary in `JOIN_REFERENCE` doesn't fire inside the `STRAIGHT_JOIN` token (the `_J` boundary is between two word characters). The join scanner now matches `\b(?:STRAIGHT_)?JOIN`, and `STRAIGHT_JOIN` is added to the `FROM_CLAUSE` terminator alternation so the FROM clause stops before it instead of swallowing the joined table. Closes a TableGate bypass on MySQL.
- **`blocked_tables` now treats schema-qualified entries symmetrically.** Configuring `blocked_tables: ["audit.authorizations"]` previously matched nothing because `#blocked?` schema-stripped *incoming* identifiers but never the configured set. Bare entries (`"authorizations"`) continue to behave as a wildcard across every schema; schema-qualified entries (`"audit.authorizations"`) now match only references that carry the same schema prefix — including quoted variants `"audit"."authorizations"` and `` `audit`.`authorizations` ``. A reference to `public.authorizations` is *not* blocked when only `audit.authorizations` is on the list, so operators can scope blocks to a specific schema.
- **`Woods::Console::EvalGuard` — parse-time refusal layer for `console_eval`.** A new checked-method class that walks the normalized `Woods::Ast::Parser` tree of every proposed eval payload and raises `ForbiddenExpressionError` when the snippet reaches a credential or reflection escape. Hardcoded denials (no DSL) cover `Rails.application.credentials.*`, `Rails.application.secrets.*`, `Rails::Secrets.*`, `Devise.secret_key`, every `ENV` form (`ENV['x']`, `ENV.fetch`, bare `ENV`), reflection escapes (`eval`, `instance_eval`, `class_eval`, `module_eval`, `send`, `public_send`, `const_get`, `binding`), and credential-file reads (`File.read` / `IO.read` / `Pathname.new` whose argument source contains `master.key`, `credentials.yml.enc`, `credentials/`, `secrets.yml`, `secrets.yml.enc`). Refuses on parse failure too — a payload that won't parse can't be reasoned about. Adds `prism ~> 1.4` as a runtime dependency (stdlib on Ruby 3.3+, gem on 3.0–3.2) so the AST path is available across the support matrix.
- **`EvalGuard` is now wired into `console_eval` dispatch.** `Woods::Console::Server.define_eval` instantiates an `EvalGuard` (gated on a new `console_credential_defense_enabled` config flag, default `true`) and passes it to `Tools::Tier4.console_eval` as `guard:`. Forbidden payloads raise `ForbiddenExpressionError` *before* the bridge request is built, and `define_console_tool` now rescues that alongside `SqlValidationError` so the LLM sees a clean MCP error response (`error: true`, message in `text`) instead of a transport-level exception. Hosts can opt out by setting `config.console_credential_defense_enabled = false` in their Woods initializer if the parse-time layer ever interferes with a legitimate workflow — the bridge-side enforcement remains in place either way.
- **`Woods::Console::CredentialIndex` — boot-time index of the host app's actual secrets.** A new value object that walks `Rails.application.credentials.config` once at server boot, collects every string leaf with length ≥ 12, and holds them in a frozen `Set` plus a precompiled `Regexp.union` for one-pass `gsub` substitution. The pattern-based `CredentialScanner` only catches *known credential shapes*; this index closes the gap for hand-rolled HMAC secrets, Twilio auth tokens, third-party webhook signing keys, and any other value whose format the scanner doesn't recognize but whose exact contents Rails already knows. `match?(str)`, `redact(str)`, and `empty?` are the only public API surface. `.build(rails_app:)` catches `ActiveSupport::EncryptedConfiguration::MissingKeyError`, `ActiveSupport::EncryptedFile::MissingKeyError`, and `ActiveSupport::MessageEncryptor::InvalidMessage` *by class name* (no constant references) so apps without `config/master.key` still boot — the index just stays empty and the other defense layers continue to apply. Standalone in this commit; wiring into `CredentialScanner` is the next change.

### Fixed

- **Console MCP middleware boots cleanly on Rails 8.0.** Replaced `ActiveRecord::Base.connection` with `ActiveRecord::Base.connection_pool.with_connection { |conn| … }` in `RackMiddleware#build_embedded_server` and the `EmbeddedExecutor#active_connection` fallback. `ActiveRecord::Base.connection` is deprecated in Rails 7.2 and removed in 8.0; `with_connection` is the supported cross-version API (works 6.1 → 8.x). Single-pool behavior is preserved — converting `SafeContext` to per-request connection acquisition (multi-DB / sharded hosts) is tracked separately as `WOODS-CONSOLE-PERREQ-CONN`.
- **Console renderer no longer collapses row data to `"N items"`.** `ConsoleResponseRenderer#render_hash` was summarizing every Array-valued key to a count, which silently elided the actual data from `console_sql`, `console_query`, `console_pluck`, `console_sample`, `console_recent`, and `console_find` responses — the MCP payload carried the rows, but the rendered text agents see only named the shape. Array values now recurse through `render_array` (Array<Hash> → Markdown table, scalar array → bullet list). When `rows` or `values` appears alongside a sibling `columns` array, the renderer emits a positional Markdown table using the columns as headers so sql / query / pluck output is scannable. Metadata-shaped responses (`count`, `aggregate`, `schema`, etc.) are unchanged.
- **MCP `search` tool no longer destroys regex patterns.** `index_reader` was wrapping queries in `Regexp.escape`, turning `User|Account` into a literal-only match. Now compiles raw with `IGNORECASE` and falls back to the escaped form only on `RegexpError`.
- **Auto-detect Ollama probe reliability.** The bootstrapper now probes `GET /api/tags` (the documented list-models endpoint) instead of `HEAD /`, which returned 404 on some Ollama versions. Any non-5xx response now marks Ollama as reachable.
- **`WOODS_SEARCH_MAX_SCAN=""` no longer disables phase-2 search.** Empty and whitespace-only values fall back to the default cap of 500 instead of coercing to 0.
- **Self-describing error for unsupported tools in embedded mode.** `console_sql` / `console_query` rejections now point at `embedded_read_tools: true` and the setup doc. Other Tier 2–4 rejections still point at the bridge architecture. Replaces the generic "Not yet implemented in embedded mode" message.
- **`console_embedded_read_tools` configuration flag.** Flows through `Woods.configure` to both the Rack middleware (Option C) and the stdio transports (Options A and B) — previously only the Rack mount accepted `embedded_read_tools:` directly, so stdio deployments had no way to unlock `console_sql` / `console_query` without patching the executable.

### Added

- **Ollama auto-detection in the MCP bootstrapper.** When no embedding provider is configured and no `OPENAI_API_KEY` is present, the bootstrapper probes `OLLAMA_BASE_URL` (default `http://localhost:11434`) and auto-enables semantic search if reachable. A one-line STDERR banner at startup reports the active provider.
- **`WOODS_SEARCH_MAX_SCAN` env var.** Caps phase-2 scan volume during `search`. Default 500.
- **Ransack-style scope predicates** for console data tools — `scope` hashes in `console_count`, `console_sample`, `console_pluck`, `console_aggregate`, `console_association_count`, and `console_recent` now accept suffixed keys (`_eq`, `_not_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`). Column names are validated before Arel predicates are built — no string interpolation, no SQL injection surface.
- **`count` function in `console_aggregate`** — the `column` argument is optional when `function: "count"`, making it easy to count rows matching a scope in a single tool call.
- **`embedded_read_tools` flag** on `Woods::Console::RackMiddleware` — opts `console_sql` and `console_query` into the embedded executor, with `SqlValidator` + `SafeContext` rollback + per-request connection pooling enforcing read-only safety.
- **MCP worktree setup guide** (`docs/MCP_WORKTREE_SETUP.md`) — multi-worktree MCP configuration for simultaneous Claude Code sessions across branches.

### Changed

- **MCP `search` response shape.** `search` now returns `{ results: [...], note?: String, partial?: Boolean }` instead of a bare `Array`. `note` flags broad patterns (>50% of a directory matched). `partial: true` indicates the phase-2 scan cap was reached — set `WOODS_SEARCH_MAX_SCAN` to raise it.
- **MCP `search` and `codebase_retrieve` descriptions** rewritten in Figma-MCP style (purpose → example → returns → when to use alternatives → gotchas). Fallback message for `codebase_retrieve` now includes exact fix commands.
- **Scope tool descriptions** updated to reference the supported predicate suffixes, so agents discover the richer filtering surface without reading the cookbook.
- **Tool descriptions for `console_sql` and `console_query`** rewritten in Figma-MCP-style (purpose → safety → requirement → alternatives) so agents understand when to reach for each and how to enable them.
- **Docs:** `docs/CONSOLE_MCP_SETUP.md` now covers `embedded_read_tools: true` as an alternative to switching to the bridge architecture, and the Troubleshooting entry for Tier 2–4 tools distinguishes the two read tools from everything else.

## [1.2.0] - 2026-03-27

### Added

- **Unblocked Documents API exporter** — sync extraction data to an Unblocked collection for code review and Q&A context
  - `Woods::Unblocked::Client` — REST client with retry and daily budget rate limiting
  - `Woods::Unblocked::DocumentBuilder` — type-specific Markdown formatters optimized for review context (blast radius, entry points, associations, side effects)
  - `Woods::Unblocked::Exporter` — full/partial sync orchestrator with priority ordering
  - `Woods::Unblocked::RateLimiter` — daily budget tracking (1000 calls/day)
  - New rake tasks: `woods:unblocked_sync` (alias: `woods:relay`)
  - New config: `unblocked_api_token`, `unblocked_collection_id`, `unblocked_repo_url`
  - Integration guide: `docs/UNBLOCKED_INTEGRATION.md`
- **Domain cluster detection** in `GraphAnalyzer` — groups code units into semantic domains using namespace prefixes and graph connectivity
  - `GraphAnalyzer#domain_clusters` — hybrid namespace + graph clustering with hub identification, entry point detection, and boundary edge mapping
  - New MCP tool: `domain_clusters` with `min_size` and `types` filters
  - New renderer: `render_domain_clusters` in MarkdownRenderer

## [0.3.1] - 2026-03-04

### Fixed

- **Gemspec version** now reads from `version.rb` instead of being hardcoded — prevents version mismatch during gem builds
- **Release workflow** replaced `rake release` (fails on tag-triggered detached HEAD) with `gem build` + `gem push`

## [0.3.0] - 2026-03-04

### Added

- **Redis/SolidCache caching layer** for retrieval pipeline with TTL, namespace isolation, and nil-caching
- **Engine classification** — engines tagged as `:framework` or `:application` based on install path (handles Docker vendor paths)
- **Graph analysis staleness tracking** — `generated_at` timestamp and `graph_sha` for detecting stale analysis
- **Docker setup guide** (`docs/DOCKER_SETUP.md`) — split architecture, volume mounts, bridge mode, troubleshooting
- **Context7 documentation suite** — 10 new user-facing docs optimized for AI retrieval: FAQ, Troubleshooting, Architecture, Extractor Reference, WHY Woods, MCP Tool Cookbook, and 3 Context7 skills
- **`context7.json`** configuration for controlling Context7 indexing scope

### Fixed

- **Vendor path leak** in source file resolution across 9 extractors — framework gems under `vendor/bundle` no longer produce empty source
- **Prism cross-version compatibility** — handle API differences between Prism versions
- **`schema_sha`** now supports `db/structure.sql` fallback (not just `db/schema.rb`)
- **ViewComponent extractor** skips framework-internal components with no resolvable source file
- **HTTP connection reuse** and retry handling in embedding providers
- **DependencyGraph `to_h`** returns a dup to prevent cache pollution
- **MCP tool counts** corrected across all documentation (27 index / 31 console)
- **TROUBLESHOOTING.md** corrected: `config.extractors` controls retrieval scope, not which extractors run

### Changed

- **README streamlined** from 620 to 325 lines — added Quick Start, Documentation table; removed verbose sections in favor of links to dedicated docs
- **Internal rake tasks** (`retrieve`, `self_analyze`) hidden from `rails -T`
- **Estimated tokens memoization** removed to prevent stale values after source changes
- **Simplification sweep** — dead code removal, shared helper extraction, bug fixes across caching and retrieval layers

### Performance

- Critical hotspots fixed across extraction, storage, and retrieval pipelines
- `fetch_key` optimization for falsy value handling in cache layer

## [0.2.1] - 2026-02-19

### Changed

- Switch release workflow to RubyGems trusted publishing

## [0.2.0] - 2026-02-19

### Added

- **Embedded console MCP server** for zero-config Rails querying (no bridge process needed)
- **Console MCP setup guide** (`docs/CONSOLE_MCP_SETUP.md`) — stdio, Docker, HTTP/Rack, SSH bridge options
- **CODEOWNERS** and issue template configuration

### Fixed

- MCP gem compatibility and symbol key handling in embedded executor
- Duplicate URI warning in gemspec

## [0.1.0] - 2026-02-18

### Added

- **Extraction layer** with 13 extractors: Model, Controller, Service, Job, Mailer, Phlex, ViewComponent, GraphQL, Serializer, Manager, Policy, Validator, RailsSource
- **Dependency graph** with PageRank scoring and GraphAnalyzer (orphans, hubs, cycles, bridges)
- **Storage interfaces** with InMemory, SQLite, Pgvector, and Qdrant adapters
- **Embedding pipeline** with OpenAI and Ollama providers, TextPreparer, resumable Indexer
- **Semantic chunking** with type-aware splitting (model sections, controller per-action)
- **Context formatting** adapters for Claude, GPT, generic LLMs, and humans
- **Retrieval pipeline** with QueryClassifier, SearchExecutor, RRF Ranker, ContextAssembler
- **Retriever orchestrator** with degradation tiers and RetrievalTrace
- **Schema management** with versioned migrations and Rails generators
- **Observability** with ActiveSupport::Notifications instrumentation, structured logging, health checks
- **Resilience** with CircuitBreaker, RetryableProvider, IndexValidator
- **MCP Index Server** (21 tools) for AI agent codebase retrieval
- **Console MCP Server** (31 tools across 4 tiers) for live Rails data access
- **AST layer** with Prism adapter for method extraction and call site analysis
- **RubyAnalyzer** for class, method, and data flow analysis
- **Flow extraction** with FlowAssembler, OperationExtractor, FlowDocument
- **Evaluation harness** with Precision@k, Recall, MRR metrics and baseline comparisons
- **Rake tasks** for extraction, incremental indexing, framework source, validation, stats, evaluation
