# Security Policy

## Supported Versions

| Version | Supported | Until |
|---------|-----------|-------|
| 2.0.x   | Yes — all fixes | Current release line |
| 1.6.x   | Security fixes only | 2027-02-20 |
| < 1.6   | No | — |
| 0.x     | No | — |

Only the newest patch release of a supported line receives fixes. A report
against 1.6.x is assessed against `main` first; if the current release line is
unaffected, the 1.6.x backport is still issued until the date above.

Upgrading from 1.x to 2.0 requires one clean re-index — see the Upgrade Notes in
[CHANGELOG.md](CHANGELOG.md) and [docs/UPGRADING_TO_2.md](docs/UPGRADING_TO_2.md).

## Reporting a Vulnerability

If you discover a security vulnerability in Woods, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Preferred: use GitHub's private vulnerability reporting — the **Report a
vulnerability** button under the repository's
[Security tab](https://github.com/lost-in-the/woods/security/advisories/new).
It keeps the report, the discussion and the eventual advisory in one place, and
it does not expose anything publicly until an advisory is published.

If you cannot use GitHub, contact the maintainer privately through the address listed in the gem metadata.

Either way, please include:

1. A description of the vulnerability
2. Steps to reproduce
3. The potential impact
4. The Woods version and Rails version you observed it on
5. Any suggested fix (optional)

## What to Expect

- **Acknowledgment** within 48 hours of your report
- **Assessment** within 1 week — we'll confirm whether it's a valid vulnerability and its severity
- **Fix timeline** depends on severity:
  - **Critical** (remote code execution, data exfiltration): Patch within 7 days
  - **High** (privilege escalation, injection): Patch within 14 days
  - **Medium/Low** (information disclosure, DoS): Patch in the next release

## Disclosure Timeline

- We follow a 90-day coordinated disclosure timeline
- We'll credit you in the release notes (unless you prefer to remain anonymous)
- We'll publish a security advisory on GitHub once the fix is released

## Security Considerations

Woods runs inside your Rails application and has access to:

- **Application source code** — extracted and written to the output directory as JSON
- **Database schema** — column names, types, indexes, and foreign keys (no row data)
- **Git metadata** — commit history, contributors, file change frequency
- **Runtime state** (Console MCP Server only) — live database queries within a rolled-back transaction

### Output Directory

Extracted data is written to `tmp/woods/` by default. This directory contains your application's source code and schema in structured JSON format. Treat it with the same sensitivity as your source code — do not expose it to untrusted parties.

### Console Server

The Console MCP Server provides live database access through a five-layer defense-in-depth stack (feature gate, blocked tables, credential scanner, column redaction, and SqlValidator + rolled-back transactions). Only 9 read-only tools register by default; the optional Tier 4 read tools (`console_sql`, `console_query`) require explicit opt-in via `console_embedded_read_tools` and are constrained by `SqlValidator`'s read-only function allowlist plus rolled-back transactions. No executable tool requires confirmation or writes a privileged audit log — the confirmation/audit contracts belong to Tier 2/3 and `console_eval`, which are inventory-only and never registered. Rolled-back transactions do not undo async side effects (`perform_later`, `deliver_later`, HTTP egress), so treat the Console Server as an admin-trust boundary, not a sandbox: use it in development/staging only, never in production. See [docs/CONSOLE_MCP_SETUP.md — Safety Model](docs/CONSOLE_MCP_SETUP.md#safety-model) for the full breakdown.

### MCP Transport

The MCP Index Server supports both stdio and HTTP transports. stdio is the default and has no network exposure. The HTTP transport (`exe/woods-mcp-http`) refuses to bind a non-loopback host unless `WOODS_MCP_HTTP_TOKEN` is set and validates incoming `Authorization: Bearer …` headers. It also enforces a default `Origin` allow-list via `OriginGuard` to mitigate DNS-rebinding attacks. TLS is not terminated in-process — front the HTTP transport with a reverse proxy (nginx, caddy) when exposing it beyond loopback. See [docs/MCP_HTTP_TRANSPORT.md](docs/MCP_HTTP_TRANSPORT.md) for the full deployment guide.

## Blast Radius

If extraction output leaks, what can an attacker do with it?

**What the output contains.** Application source code (inlined concerns, callback-resolved behavior), database schema (column names, types, indexes, foreign keys), route tables, migration history, gem versions, and git metadata (commit history, contributor emails, file change frequency).

**What the output does not contain.** No row-level data from your database — Woods extracts schema only. No environment variables, no `Rails.application.credentials`, no API keys, no session state, no request logs, no customer data.

| Leak scenario | Attacker gains | Attacker does not gain |
|---|---|---|
| `tmp/woods/` directory exfiltrated | Source code + schema equivalent to a git clone + `rails db:schema:dump` | Database rows, secrets, tokens, customer data |
| MCP Index Server token leaked (HTTP transport) | Read-only query access to the extracted index — no write or execution paths | Shell access, database row data, secrets |
| Notion sync database compromised | Model and column summaries synced to Notion | Anything not mirrored — source code stays local |
| Console MCP Server exposed (dev/staging) | Read-only database access through a rolled-back transaction, bounded by TableGate + Redactor + SqlValidator | Write access (rolled back), full credentials (redacted), blocked tables |

**Mitigation.** Treat `tmp/woods/` as source-equivalent — keep it out of world-readable directories and public container images. Rotate `WOODS_MCP_HTTP_TOKEN` on compromise. Keep `console_mcp_enabled = false` in production regardless of environment, since the console layers are defense-in-depth and not primary controls.
