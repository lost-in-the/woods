# Audit Follow-ups Plan

Branch: `security/audit-followups`
Base: `main` @ `89db38f` ("Disable Console MCP at entry points pending security review")
Sister branch: `security/console-defense-in-depth` (Console MCP five-layer stack — merged plan at `docs/security/console-hardening-plan.md` on that branch)

## Scope

Five findings surfaced by subagent audits during the defense-in-depth review
that are **out of scope** for the Console MCP defense stack. They span other
parts of the Woods codebase (Index MCP retrieval, session tracing, MetadataStore)
and deserve their own branch so the Console MCP PR can ship on its own.

## Findings

### M-3 — `console_association_count` response leak

**Where:** `lib/woods/console/server.rb` — the `console_association_count` tool
handler.

**Symptom:** the tool returns record counts broken down by a user-supplied
`scope:` and a **second grouping column** (or the raw `group_by:` arg, depending
on the server implementation at the time of the audit). If the grouping column
names PII (email, IP, access_token) or a credential-shaped value, those values
land in the rendered response — they are keys of the returned aggregation hash
and the CredentialScanner only matches shapes, not arbitrary identifiers.

**Action:** re-read the current `console_association_count` handler end-to-end,
decide whether to (a) disallow `group_by:` against columns on
`console_redacted_columns` or (b) pass the response through a key-sanitisation
pass before serialization. Choose after reading, not before. Write a failing
spec that feeds a blocked column as the group key and asserts it either raises
or returns `[REDACTED]` keys.

### M-4 — `CredentialScanner` pattern gaps

**Where:** `lib/woods/console/credential_scanner.rb` — the `PATTERNS` constant.

**Symptom:** the scanner covers Stripe, AWS, GitHub, GCP service-account private
keys, and generic high-entropy tokens, but misses:
  - PayPal credentials (live/sandbox `client_id` + `client_secret` pairs)
  - Postmark / SendGrid API keys
  - Twilio auth tokens (32-hex with `SK` / `AC` prefixes)
  - PEM-encoded RSA keys without the exact `-----BEGIN PRIVATE KEY-----` header
    (e.g. `-----BEGIN RSA PRIVATE KEY-----`)
  - Possibly: Slack app tokens (`xoxa-`/`xoxp-`/`xoxb-` — verify current set)

**Action:** re-enumerate the credential pattern coverage against the patterns
that show up in representative host-app databases. Every new pattern needs a
positive fixture (matches the shape) **and** a negative fixture (string that
looks superficially similar but should not match). Fixtures live alongside the
existing ones in `spec/console/credential_scanner_spec.rb`.

### L-8 — `Woods::Console::RackMiddleware` has no auth hook

**Where:** `lib/woods/console/rack_middleware.rb`.

**Symptom:** the middleware mounts the Console MCP server on an HTTP endpoint
but delegates authentication entirely to the host app. There is no
`before_request:` proc argument, so a host that forgets to wrap the mount in
`authenticate!` exposes the full Console surface unauthenticated. The feature
gate (Layer 0) protects against accidentally-enabled-in-prod deployments but
is silent on the auth question.

**Action:** add an optional `auth:` kwarg accepting a callable
`(env) -> truthy|falsy`. When the callable is present and returns falsy,
respond with `401 Unauthorized` and a JSON body explaining the missing auth.
Leave unset-callable behavior as "host is responsible" (don't add fake
default-deny — the current behavior is intentional for local development).

### X-1 — `MetadataStore` field-name injection

**Where:** `lib/woods/storage/metadata_store.rb` and the Pgvector /
Qdrant / SQLite adapter backends underneath it.

**Symptom:** several MetadataStore query methods (the audit flagged `filter:` /
`order_by:` / similar — verify current names) accept user-provided field names
and interpolate them into SQL or into a Qdrant filter payload without a
whitelist check. The immediate caller is always Woods internal code, but
retrieval tooling accepts agent-provided filter arguments, so the injection
surface is not purely internal.

**Action:** audit every MetadataStore public method that accepts a field-name
argument. Build a per-adapter whitelist sourced from the actual schema
(`SchemaVersion` + column list for Pgvector, the point payload schema for
Qdrant, the table definition for SQLite). Reject anything not on the list with
a specific error, not a silent fall-through. Tests should include: an
injection payload that tries to escape the identifier quoting, a reserved-word
identifier, and a field name with a dot or space.

### X-2 — ReDoS in `compile_search_pattern`

**Where:** `lib/woods/mcp/index_reader.rb` (or wherever `compile_search_pattern`
now lives — search by name) in the Index MCP server.

**Symptom:** `search` lets agents pass a raw regex. The compile path wraps the
query in `(?i:…)` and falls back to `Regexp.escape` only on `RegexpError`, but
does not reject catastrophically-backtracking patterns like `(a+)+b` before
they run. Risk is bounded to the MCP host (one agent hanging its own Ruby
process), but the MCP host is trusted and the fix is small.

**Action:** reject patterns with nested unbounded quantifiers before compile —
either via an explicit heuristic pre-check, or by running the compile inside a
`Timeout.timeout` wrapper with a small budget (e.g. 200ms). Decide between the
two based on false-positive tolerance: the heuristic is strict, the timeout is
lenient. Tests should pass a known evil regex and assert the reject path
triggers without the test itself hanging.

## Working order

Suggested order (cheapest first, so if the branch stalls the most-visible wins
still ship):

1. X-2 (ReDoS) — single file, bounded test surface
2. L-8 (auth hook) — single file, pure addition
3. M-4 (pattern gaps) — additive, pure regex + fixtures
4. M-3 (association-count leak) — needs design decision first
5. X-1 (MetadataStore injection) — largest scope; touches three adapters

Each should be one commit. Match the commit style from
`security/console-defense-in-depth` — descriptive subject, body explaining the
gap and the fix, test summary in the trailer.

## Out of scope

- Console MCP defense-in-depth (separate branch)
- Any refactor of the Console executor or retrieval pipeline that doesn't fix
  one of the five findings
- Adding new MCP tools
- Touching the extraction pipeline
