# Task 3 Report: Console MCP Capability And Safety Contracts

## Status

DONE

`V2-CONSOLE-001` is fixed and marked resolved. The supported Console MCP
surface now consists of 9 default embedded tools and 11 embedded-read tools.
The remaining `TOOL_SPECS` entries are inventory only and are not registered.

## Implementation

- Replaced the JSON-lines launcher/bridge path with process replacement. The
  launcher resolves `WOODS_CONSOLE_CONFIG`, then `~/.woods/console.yml`, then
  the direct default command. Direct, Docker, and SSH modes now exec the real
  embedded MCP server so EOF and signals reach the server directly.
- Made the former `StubBridge` impossible to construct. It cannot return zero
  counts or empty collections as fabricated live application data.
- Added a frozen, code-derived 31-row `CONTRACT_MATRIX`. Registration comes
  from its executable modes: Tier 1 in `embedded`, Tier 1 plus SQL/query in
  `embedded_read`, and no registered Tier 2, Tier 3, or eval tools.
- Added `InputContract`, with exact decimal parsing and schema-derived minimum
  and maximum enforcement. Removed supported-path `String#to_i` truncation and
  silent upper-bound capping.
- Updated all integer schemas with bounds. Corrected `console_query.having` to
  accept only non-empty objects or two-element `[template, bind]` arrays, with
  matching executor validation.
- Removed the supported eval-enable path. Legacy eval flags/collaborators fail
  server construction closed instead of printing a false "live" claim.
- Made Console Streamable HTTP stateless by default, strips stale session IDs
  on a copied Rack environment, and retains tested `stateless: false`
  compatibility behavior.
- Corrected current setup/configuration documentation for executable modes,
  launcher YAML, `WOODS_CONSOLE_CONFIG`, read-tool registration, eval
  unavailability, and stateless HTTP.

## RED Evidence

Initial reproductions confirmed:

- launcher startup checked default-disabled global configuration before YAML;
- docs named `CODEBASE_CONSOLE_CONFIG` while the executable used another name;
- schema-valid `console_query.having` strings were not executable safely;
- `"12junk"` became `12` through `String#to_i`;
- the static bridge returned a successful fake count of zero;
- disconnect could block beyond 250 ms.

TDD runs:

- Strict input/schema RED: 120 examples, 9 failures, seed 46737. Failures
  showed missing schema bounds, permissive `having`, malformed integer
  coercion, and oversized limits reaching query code.
- Stateless HTTP RED: 21 examples, 4 failures, seed 61506. Failures showed a
  sessionful transport constructor, stale session IDs reaching the SDK, and no
  compatibility option.
- Real Rails subprocess RED first exposed missing boot harness railties; after
  boot, the live renderer contract was asserted over the MCP response rather
  than bypassed with a mocked JSON payload.

## GREEN Evidence

Verification used the required Ruby 4.0.1 PATH and shared bundle path.

- `bundle exec rspec spec/console --format progress`
  - 883 examples, 0 failures, seed 12021.
- Rails 8.1 real transports with `WOODS_RUN_BOOTED_APP=1` and
  `WOODS_RUN_HTTP_SERVER=1`:
  - `bundle exec rspec spec/console/stdio_e2e_spec.rb spec/console/http_e2e_spec.rb --format progress`
  - 4 examples, 0 failures, seed 40038.
  - Verified default 9-tool stdio mode, 11-tool read stdio mode, a persisted
    SQLite row through `console_count` and `console_query`, malformed-frame
    recovery, EOF, INT status 130, stateless HTTP, stale-session tolerance,
    four concurrent real count calls, and HTTP TERM shutdown.
- Blocker reproduction:
  - `bundle exec rspec spec/console/tool_specs_spec.rb spec/console/bridge_spec.rb spec/console/cli_integration_spec.rb --format progress`
  - 38 examples, 0 failures, seed 4277.
- `bundle exec rubocop exe/woods-console-mcp lib/woods/console spec/console`
  - 78 files inspected, no offenses.
- Findings ledger parsed successfully with `JSON.parse`.

## Commits

- `9e55814` `fix: advertise only executable console tools`
- `2dd487a` `fix: enforce console input and safety contracts`
- `482e68e` `fix: align console transport lifecycle contracts`
- `6b4c81e` `docs: correct console executable setup`
- `35d7859` `test: cover console modes over real transports`

## Changed Files

Runtime and executables:

- `exe/woods-console-mcp`
- `lib/woods/console/bridge.rb`
- `lib/woods/console/bridge_protocol.rb`
- `lib/woods/console/connection_manager.rb`
- `lib/woods/console/dispatch_pipeline.rb`
- `lib/woods/console/embedded_executor.rb`
- `lib/woods/console/input_contract.rb`
- `lib/woods/console/rack_middleware.rb`
- `lib/woods/console/server.rb`
- `lib/woods/console/tool_specs.rb`

Tests and real-process harnesses:

- `spec/console/bridge_protocol_spec.rb`
- `spec/console/bridge_spec.rb`
- `spec/console/cli_integration_spec.rb`
- `spec/console/connection_manager_spec.rb`
- `spec/console/dispatch_pipeline_spec.rb`
- `spec/console/embedded_executor_query_spec.rb`
- `spec/console/embedded_executor_spec.rb`
- `spec/console/eval_opt_in_spec.rb`
- `spec/console/http_e2e_spec.rb`
- `spec/console/rack_middleware_spec.rb`
- `spec/console/server_embedded_spec.rb`
- `spec/console/server_leak_scenarios_spec.rb`
- `spec/console/server_spec.rb`
- `spec/console/stdio_e2e_spec.rb`
- `spec/console/support/booted_console_app.rb`
- `spec/console/support/booted_http_host.rb`
- `spec/console/support/booted_mcp_host.rb`
- `spec/console/tool_specs_spec.rb`

Current setup documentation:

- `README.md`
- `docs/CONFIGURATION_REFERENCE.md`
- `docs/CONSOLE_MCP_SETUP.md`
- `docs/DOCKER_SETUP.md`
- `docs/FAQ.md`
- `docs/GETTING_STARTED.md`
- `docs/MCP_SERVERS.md`
- `docs/TROUBLESHOOTING.md`

Evidence:

- `.Codex/release-v2/findings.json` (`V2-CONSOLE-001` only)
- this report

## Self-Review

- Confirmed `StubBridge` has no supported handler path and raises on
  construction.
- Confirmed `Server.build` fails closed and both embedded builders derive
  registration from the contract matrix.
- Confirmed every integer property in all 31 schemas has an integer minimum
  and maximum and both dispatch paths use the same schema-derived validator.
- Confirmed all registered tools traverse table gating, configured redaction,
  and credential scanning. No registered tool claims confirmation or privileged
  audit behavior.
- Confirmed SQL/query remain absent unless read mode is explicit and eval
  remains absent in every supported mode.
- Confirmed no release workflow/package code, other repository source, tags,
  pushes, or unrelated backlog state were changed.

## Concerns

- Task 9 still owns the full documentation rewrite. Current setup,
  configuration, FAQ, and troubleshooting paths were corrected here, but
  historical architecture/design documents may still describe the 31-schema
  inventory as a previously planned executable surface.
- The Rails 8.1 appraisal dependencies had to be installed into the supplied
  shared bundle path before the required booted integration run; no lockfile or
  package metadata was changed.
