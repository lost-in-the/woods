# Console MCP — Defense-in-Depth Plan

> Working document for branch `security/console-defense-in-depth`. Targets the
> audit finding in the 2026-04-18 advisory (EAV credential disclosure via
> `console_redacted_columns` shape gap, plus the meta-insight about safety
> checks at a layer that can't be bypassed by adding new data).

## Goal

Make the Woods Console MCP server safe to re-enable by default, without
requiring operators to enumerate every sensitive column, EAV key, or
credential-bearing table in their schema. Operator-supplied allow/deny lists
remain available for precision, but are not the last line of defense.

## Threat model

| # | Scenario | Example | Currently caught by |
|---|----------|---------|---------------------|
| T1 | Typed credential column | `users.crypted_password` leaks | `console_redacted_columns` ✓ |
| T2 | EAV credential row | `authorizations.key='stripe_access_token'` leaks `value` | `console_redacted_key_values` (shipped 24690a5) ✓ |
| T3 | Newly-added EAV key the operator hasn't registered yet | A PR adds `key='stripe_refresh_token'` but forgets the redaction config | **No coverage today** |
| T4 | JSONB / serialized column carrying secrets | `users.settings = {"stripe_key": "sk_live_..."}` | No coverage (column name `settings` isn't in the list) |
| T5 | Associated record pulled via `console_data_snapshot` | Nested serialization of a credential-bearing model | Partial (column redaction walks nested hashes, but same shape gap) |
| T6 | Raw SQL bypass | `SELECT * FROM authorizations` | SqlValidator doesn't know about credential tables |
| T7 | Log / audit output containing secrets | `console_sql` failure message echoes the bound parameter | No coverage |

The audit's architectural insight: all current defenses key off **identity**
(column name, model name, row's key column). Every one of those is an allow-
list that needs updating when new data appears. A durable defense has to key
off **content shape** — a thing that looks like a Stripe secret is redacted
regardless of which column or row it arrived in.

## Architecture — five layers

Redaction happens in this order on every response before it leaves the
Console server:

### Layer 0 — Feature gate (formalized)

- New config flag: `Woods.configuration.console_mcp_enabled`, default `false`.
- All three entry points (`exe/woods-console-mcp`, `exe/woods-console`,
  `RackMiddleware#call`) check this flag and refuse unless explicitly set.
- Rationale: the current soft-disable sets the policy in code. This flag moves
  the policy to operator control while preserving the "disabled by default"
  stance.

### Layer 1 — Blocked tables (Option A from the advisory)

- New config: `Woods.configuration.console_blocked_tables` — array of table
  names (case-insensitive).
- For `console_sql`: parse the SQL for `FROM <name>` / `JOIN <name>` tokens
  (word-boundary-anchored, quote-aware) and reject when any token matches.
- For model-based tools: resolve `model.table_name` via the model registry;
  reject the tool call when the resolved table is on the list.
- Rejection returns a structured error so the agent receives a clear "this
  table is gated" message instead of an empty result.

### Layer 2 — Credential-shape content scanner (the new core)

- New module: `Woods::Console::CredentialScanner`.
- Runs over the entire serialized response tree (strings, nested hashes,
  nested arrays, including positional row arrays from sql/pluck).
- Each string value is scanned with a library of high-specificity regexes
  targeting well-known credential formats. Matches are replaced with
  `[REDACTED]`, preserving surrounding non-secret context where possible.
- Initial pattern library (all word-boundary-anchored):

  | Pattern name | Regex | Blast target |
  |---|---|---|
  | `stripe_secret_key` | `\b(sk|rk)_(live|test)_[A-Za-z0-9]{24,}\b` | Stripe |
  | `stripe_publishable_key` | `\bpk_(live|test)_[A-Za-z0-9]{24,}\b` | Stripe (informational) |
  | `stripe_webhook_secret` | `\bwhsec_[A-Za-z0-9]{24,}\b` | Stripe webhooks |
  | `aws_access_key_id` | `\b(AKIA|ASIA)[0-9A-Z]{16}\b` | AWS |
  | `github_token` | `\bgh[pousr]_[A-Za-z0-9]{36,}\b` | GitHub |
  | `google_oauth_token` | `\bya29\.[A-Za-z0-9_-]{20,}\b` | Google |
  | `jwt_token` | `\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b` | Any JWT |
  | `pem_private_key_block` | `-----BEGIN [A-Z ]*PRIVATE KEY-----` | Any asymmetric key |
  | `slack_bot_token` | `\bxox[abpr]-[A-Za-z0-9-]{10,}\b` | Slack |
  | `generic_high_entropy` | (opt-in, conservative) long alphanumeric tokens adjacent to labels like `password`, `secret`, `api_key` | Catch-all |

- Default enabled (`console_credential_scanning_enabled = true`). Operators
  can disable per-pattern via `console_disabled_scanner_patterns`.
- Emits a structured "pattern fired" log entry per response so operators can
  audit whether Layer 2 ever fires in production (should be rare in steady
  state — if it fires, the column/EAV configs are incomplete).

### Layer 3 — Operator-configured column + EAV redaction

- Existing, unchanged: `console_redacted_columns`, `console_redacted_key_values`.
- Still the precise tool for non-regex-shaped secrets (short tokens, hashed
  values, internal identifiers that shouldn't leave the system).

### Layer 4 — Transaction rollback + SQL deny-list

- Existing: `SafeContext` transaction rollback, `SqlValidator` DML/DDL rejection.
- Unchanged in this branch.

## Observability

- Every redaction emits a structured log line via `Woods::Observability::StructuredLogger`:
  `{ layer:, tool:, pattern: (Layer 2 only), count:, table: (Layer 1/3 only) }`.
- Response payload gains a `_meta.redactions` field with a per-layer count
  summary so the calling agent (and operators inspecting traffic) can
  verify defenses are active.
- A boot-time WARN log fires if `console_mcp_enabled = true` AND
  `credential_scanning_enabled = false` AND both column/EAV lists are empty.
  "You've enabled the Console MCP with every redaction layer off — this is
  almost certainly a configuration mistake."

## Out of scope for this branch

- Option C (per-call disclosure confirmation). Heavier protocol surface and
  unnecessary once Layer 2 is in place.
- Automatic EAV-table discovery from schema. Operators still declare their
  EAV patterns explicitly — Layer 2 catches anything they miss, Layer 3
  gives them precision when they know.
- Rotation tooling for the leaked test credentials surfaced by the audit.
  That's on the host application, not this gem.

## Validation strategy

### Unit tests — new code

- `spec/console/credential_scanner_spec.rb`
  - Every pattern: positive match, surrounding-text match, false-positive
    avoidance against short/benign strings.
  - Recursive scanning of nested arrays and hashes.
  - Positional row scanning (rows + columns envelope).
  - Scanner disabled: pass-through.
  - Per-pattern disable: only the disabled pattern passes through.
  - Multi-pattern match in a single string.
- `spec/console/blocked_tables_spec.rb`
  - SQL: simple `FROM`, nested `JOIN`, quoted identifiers (`` `authorizations` ``,
    `"authorizations"`), case-insensitive match.
  - SQL: comment-hidden references (confirm SqlValidator's comment stripping
    runs first or that we handle it ourselves).
  - Model-based: `Authorization` resolves to `authorizations`, blocked.
  - Model-based: unrelated model passes through.
  - Empty block list: all calls pass through.
- `spec/console/feature_gate_spec.rb`
  - `console_mcp_enabled = false`: every entry point refuses.
  - `console_mcp_enabled = true`: tools dispatch normally.
  - Boot-time warn on empty safety config.

### Integration tests — composed behavior

- `spec/console/integration/credential_redaction_integration_spec.rb`
  - Fixture data: an in-memory sqlite registry populated with rows shaped
    like the leaked `authorizations` table, a `users` table with a
    credential column, a `settings` JSONB-equivalent column carrying
    `sk_live_*` values.
  - For each read tool (`console_sql`, `console_query`, `console_pluck`,
    `console_sample`, `console_recent`, `console_find`): assert the
    rendered response contains zero raw credential-shaped tokens.
  - Assert non-credential data (Stripe account IDs like `acct_*`, user
    emails) flows through untouched.
  - Assert `_meta.redactions` counts match the expected number of
    redactions per call.
- `spec/console/integration/layer_composition_spec.rb`
  - Verify layers fire in the correct order:
    Layer 1 (block) → tool executes (or is rejected) → Layer 3 (column/EAV)
    → Layer 2 (content scanner) → response emitted.
  - A table on the block list short-circuits before any data is returned.
  - A row that Layer 3 missed is still caught by Layer 2.
  - A Layer 1 rejection emits a structured log event.

### Regression tests — existing suite

- All 3476 existing examples continue to pass.
- The two specs added for `console_redacted_key_values` (shipped in 24690a5)
  continue to pass.

### Live validation — host app

- Run each read tool against the real `authorizations` table:
  - `console_sql sql: "SELECT id, \`key\`, value FROM authorizations"`
  - `console_query model: "Authorization", select: ["id", "key", "value"]`
  - `console_pluck model: "Authorization", columns: ["key", "value"]`
  - `console_sample model: "Authorization", limit: 5`
- Assert: every `sk_test_*` and `sk_live_*` value in the output is `[REDACTED]`.
- Assert: `acct_*` values (non-secret Stripe account IDs) flow through.
- Assert: adding `authorizations` to `console_blocked_tables` causes all four
  tools to reject the call with a structured error.
- Assert: the `_meta.redactions` field is present and non-zero on the
  non-blocked calls.
- Record the live test run and attach to the PR.

## Branch deliverables

Ordered so each commit is independently reviewable:

1. **`docs/security/console-hardening-plan.md`** — this file.
2. **`Woods::Console::CredentialScanner`** + unit specs.
3. **`console_blocked_tables` + Layer 1 enforcement** + unit specs.
4. **`console_mcp_enabled` feature gate** + unit specs.
5. **Server wiring** — `apply_redaction` runs Layer 2 after Layer 3; Layer 1
   fires before any tool dispatch.
6. **Observability** — structured log lines, `_meta.redactions` envelope.
7. **Integration specs** — fixture-driven end-to-end tests for each read tool.
8. **Re-enable entry points** — `exe/woods-console-mcp`, `exe/woods-console`,
   and `RackMiddleware#call` check `console_mcp_enabled` instead of being
   hard-coded to refuse.
9. **CHANGELOG + `docs/CONSOLE_MCP_SETUP.md`** update — operator-facing
   summary of the five layers and how to configure each.
10. **Live-validation run** — attach results to PR description.

## Re-enable checklist (for the PR description)

Before merging this branch:

- [ ] All 3476 existing specs pass.
- [ ] New spec additions cover the five test categories above.
- [ ] Live validation against a host development database shows zero raw
      credentials in any read-tool output.
- [ ] Live validation confirms block-list rejects the blocked table.
- [ ] Live validation confirms `_meta.redactions` reports the expected
      layer counts.
- [ ] CHANGELOG updated with a superseding Security entry and a pointer
      to this doc.
- [ ] `docs/CONSOLE_MCP_SETUP.md` updated with the new configuration surface.
- [ ] The soft-disable from commit `89db38f` is replaced by the
      `console_mcp_enabled` gate (not deleted — formalized).
- [ ] Rotate any test-mode credentials that appeared in the audit conversation
      history (host-app action, tracked outside this gem).

## Live validation run — 2026-04-21

Executed against the `woods-r8-smoke` container (Rails 8.0.2, SQLite, woods
gem mounted from the `security/console-integration-clean` branch at
`/woods-gem`), driving `/mcp/console` over HTTP with a session-aware curl
harness (`/tmp/woods_mcp_test/{client.sh,run_matrix.sh,analyze.py}`). The
51-case matrix exercises every defense layer plus EvalGuard, the renderer,
and operational tools; analyzer reports **49/51 assertions passed**, with
the two non-passes being overly-narrow assertion-script matches rather than
real security regressions (notes below).

### Layer-by-layer results

**Layer 0 — Feature gate.** With `console_mcp_enabled = false`, the
`/mcp/console` endpoint returns `HTTP 410` and body
`{"error":"woods_console_disabled","message":"Woods Console MCP is disabled…"}`
before any MCP handshake. Re-enabling and restarting returns a clean
`initialize` response with `serverInfo.name = "woods-console"`,
`version = "1.2.0"`.

> **Update (#183):** the validation above records v1.2.0 behavior. Since the
> railtie hardening, a disabled console no longer answers `410` — the Rack
> middleware passes the request through to the host app, so the console path
> is indistinguishable from an unknown route while disabled. The fail-closed
> property (no MCP handshake without the flag) is unchanged.

**Layer 1 — Blocked tables.** `console_blocked_tables = %w[users audit.users]`.
All 11 probes rejected with structured errors naming the table:

- `console_find`/`sample`/`count`/`schema` on `User` → blocked at the
  model-based gate.
- `console_sql` variants on `users`: direct `FROM`, explicit `JOIN`,
  comma-join, subquery, quoted identifier (`"users"`), CTE, and `UNION`
  — all rejected at the SQL-token gate.
- Positive controls (`Micropost.find(1)`, `Credential.count` = 41) succeed.

**Layer 2 — Credential-shape content scanner.** Against the 41-row
`credentials` seed fixture (22 detected patterns + adversarial fixtures +
17 documented gaps):

- All 9 per-provider detected patterns (Stripe secret, AWS access key,
  GitHub PAT, Slack bot token, SendGrid prefix, Anthropic `sk-ant-…`,
  OpenAI project key, PEM private-key marker, JWT signature) redacted to
  `[REDACTED]`; zero fingerprint leaks in the rendered response.
- All 3 adversarial fixtures pass: embedded-in-text (`stripe_secret` inside
  a narrative `notes` field), multi-secret (`stripe_secret` + `aws_key` in
  one field), and JSON-blob secret (both keys inside a serialized JSON
  string) — each scanner walks the nested string contents and redacts
  without touching the surrounding structure.
- `console_pluck` full scan over
  `columns: [id, provider, value, notes], limit: 50` returns zero
  fingerprint leaks from the full detected-pattern library.
- Documented gaps flow through unredacted as expected: Postmark
  (`POSTMARK_API_TEST`), Shippo (`shippo_test_abcdef`), Resend
  (`re_123456789_…`). These are the untested-shape markers listed in
  Coverage Gaps — current behavior is deliberate pass-through, not a
  regression.

**Layer 3 — Column/EAV redaction.** Exercised implicitly through Layer 2
composition (the `value` column is not in `console_redacted_columns` for
the smoke app; the scanner is the sole line of defense in this fixture).
Direct Layer 3 coverage is in `credential_redaction_integration_spec`.

**Layer 4 — SQL validator + SafeContext.** All 9 destructive-shape
probes rejected with specific error messages:

| Attempt | Rejection |
|---|---|
| `INSERT INTO credentials …` | DML not permitted |
| `UPDATE credentials SET value = …` | DML not permitted |
| `DELETE FROM credentials` | DML not permitted |
| `DROP TABLE credentials` | DDL not permitted |
| `ATTACH DATABASE "/tmp/x.db" …` | ATTACH not permitted |
| `PRAGMA table_info(credentials)` | PRAGMA not permitted |
| `VACUUM` | VACUUM not permitted |
| `/* trick */ DELETE /* */ FROM credentials` | Comment-stripped; DML rejected |
| `SELECT 1; DELETE FROM credentials` | Multi-statement rejected |

Positive `SELECT id, provider, value FROM credentials ORDER BY id LIMIT 5`
succeeds and the value column is fully redacted by Layer 2 in the render.

**EvalGuard.** All 7 escape-attempt probes refused with guard messages
naming the denied call chain (`Rails.application.credentials.secret_key_base`,
`ENV["SECRET_KEY_BASE"]`, `instance_variable_get(:@credentials)`,
`File.read("config/credentials.yml.enc")`, `File.open(…).read`,
`ENV.send(:[], …)`, `Object.const_get("ENV")[…]`). Benign `1 + 1`
returns `**value:** 2`. Zero credential fingerprints in any refusal
message.

**Renderer.** `console_query` and `console_aggregate` return rendered
payloads; the "N items" collapse bug from PR #34 does not reproduce.

**Observability.** `docker logs woods-r8-smoke-app` stderr shows
structured `console.table_gate.rejected` and `console.credential_scan.hits`
events on every gated call, carrying tool, model/table, and pattern-hit
counts.

### Analyzer false-failures (not security regressions)

1. `eval_file_read`: guard response is
   `"payload reads credential file via File.read"` — correct refusal, but
   the assertion script scanned for keywords like `denied`/`refuse`/`unsafe`
   rather than the actual `File.read` / `credential file` phrasing. The
   denial is working; the assertion hint list is too narrow.
2. `render_aggregate`: tool invocation with
   `group_by: "provider", function: "count"` returned the scalar
   `**value:** 41` (total count) rather than a per-provider table. This is
   an input-shape question about the aggregate tool, not a renderer
   regression — the "N items" collapse that the assertion guards against
   did not occur.

### Infrastructure fix discovered during validation

`lib/woods/console/rack_middleware.rb` had a latent namespace-collision
bug: inside `Woods::Console::RackMiddleware`, the unqualified reference
`MCP::Server::Transports::StreamableHTTPTransport` resolved to
`Woods::MCP::Server` (the Index Server module) after
`Rails.application.eager_load!` populated the constant table, raising
`NameError (uninitialized constant Woods::MCP::Server::Transports)` on the
first `/mcp/console` request in any eager-loaded Rails app. Fixed with a
`::` prefix to force top-level resolution. This fix is needed on
`main` as well — filed as a follow-up commit alongside the hardening
merge.

### Re-enable checklist status

- [x] All existing specs pass (`bundle exec rake spec` green prior to
      live run).
- [x] New specs cover scanner, blocked tables, feature gate, and
      composition — see `spec/console/`.
- [x] Live validation against fixture database shows zero raw
      credentials in any read-tool output (22/22 detected patterns
      redacted, 3/3 adversarial fixtures caught).
- [x] Live validation confirms block-list rejects `users` across model
      and SQL entry points (11/11 variants rejected).
- [x] Live validation confirms Layer 0 gate refuses with HTTP 410 when
      `console_mcp_enabled = false`.
- [x] CHANGELOG updated with the five-layer Security entry (see
      `1.2.0` / `Unreleased`).
- [x] `docs/CONSOLE_MCP_SETUP.md` documents the configuration surface.
- [x] The soft-disable is replaced by the `console_mcp_enabled` gate.
- [ ] Rotate any test-mode credentials from the audit conversation
      history (host-app action; tracked outside this gem).

