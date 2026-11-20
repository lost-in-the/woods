# Security Policy

## Supported Versions

| Version | Supported | Until |
|---------|-----------|-------|
| 2.1.x   | Yes, all fixes | Current release line |
| 1.6.x   | Vulnerability fixes only | 2027-02-20 |
| < 2.1 (other than 1.6.x) | No | n/a |

Only the newest patch release of a supported line receives fixes. A report
against 1.6.x is assessed against `main` first; if the current release line is
unaffected, the 1.6.x backport is still issued until the date above.
A backport to 1.6.x is issued for a vulnerability, as defined under
[What Counts as a Vulnerability](#what-counts-as-a-vulnerability).

Upgrading from 1.x to 2.0 requires one clean re-index, see the Upgrade Notes in
[CHANGELOG.md](CHANGELOG.md) and [docs/UPGRADING_TO_2.md](docs/UPGRADING_TO_2.md).

## Reporting a Vulnerability

If you discover a security vulnerability in Woods, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Preferred: use GitHub's private vulnerability reporting, the **Report a
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

## What Counts as a Vulnerability

Woods treats a report as a vulnerability when it crosses a boundary Woods itself enforces.
The test is whether Woods let someone do or see something it promises to prevent.
The lists below are examples of that test, not the whole of it.
These get a private fix, a patch release and a published advisory:

- Reaching an MCP server without the authentication it requires, or from a host it refuses to bind.
- On 2.1.x or 1.6.x, reaching the Console when it is disabled, or a Console tool the operator did not opt in to.
- A write, eval or shell capability reachable in a supported packaged mode.
- Code execution, or a file read or write outside the configured output directory.
- One client receiving another client's data.

The Console Server was removed in Woods 2.2.0 instead of being hardened further.
On 2.1.x and 1.6.x, a gap in its best-effort protections is not a vulnerability and gets no fix:
redaction, masking or the credential scanner missing a value, the SQL policy admitting a read, rollback not undoing
something, or a missing limit on result size, time or memory.
Turn the Console off there; see [docs/CONSOLE_REMOVED.md](docs/CONSOLE_REMOVED.md).
A gap that also crosses one of the boundaries above is a vulnerability.
Report privately when you are not sure which it is.

## What to Expect

- **Acknowledgment** within 48 hours of your report
- **Assessment** within 1 week, we'll confirm whether it is a vulnerability, and its severity
- **Fix timeline** for a vulnerability depends on severity:
  - **Critical** (remote code execution, authentication bypass): Patch within 7 days
  - **High** (a write or eval capability, another client's data): Patch within 14 days
  - **Medium/Low**: Patch in the next release

## Disclosure Timeline

- We follow a 90-day coordinated disclosure timeline
- We'll credit you in the release notes (unless you prefer to remain anonymous)
- We'll publish a security advisory on GitHub once the fix is released

## Security Considerations

Woods runs inside your Rails application and has access to:

- **Application source code**: extracted and written to the output directory as JSON
- **Database schema**: column names, types, indexes, and foreign keys (no row data)
- **Git metadata**: commit history, contributors, file change frequency
- **Optional session traces**: session/trace identifiers, request paths and controller/action timelines when session tracing is configured

### Output Directory

Extracted data is written to `tmp/woods/` by default. This directory contains your application's source code and schema in structured JSON format. Source literals, comments and configuration metadata may contain sensitive values. Treat the index with the same sensitivity as your source code; do not expose it to untrusted parties. Optional session stores can be configured under this directory and add request metadata that may be more sensitive than the source itself. Apply the [session tracing access and retention guidance](docs/CONFIGURATION_REFERENCE.md#session-tracer-options) to those stores too.

### Console Server

The Console Server, which gave an agent live database access, was removed in Woods 2.2.0.
On 2.1.x and 1.6.x it is off by default; the
[2.1.0 security policy](https://github.com/lost-in-the/woods/blob/v2.1.0/SECURITY.md#console-server)
describes the limits of its protections.

### MCP Transport

The MCP Index Server supports both stdio and HTTP transports. stdio is the default and has no network exposure. The HTTP transport (`exe/woods-mcp-http`) refuses to bind a non-loopback host unless `WOODS_MCP_HTTP_TOKEN` is set and validates incoming `Authorization: Bearer …` headers. It also enforces a default `Origin` allow-list via `OriginGuard` to mitigate DNS-rebinding attacks. TLS is not terminated in-process, front the HTTP transport with a reverse proxy (nginx, caddy) when exposing it beyond loopback. See [docs/MCP_HTTP_TRANSPORT.md](docs/MCP_HTTP_TRANSPORT.md) for the full deployment guide.

## Blast Radius

If extraction output leaks, what can an attacker do with it?

**What the output contains.** Application source code (inlined concerns, callback-resolved behavior), database schema (column names, types, indexes, foreign keys), route tables, migration history, gem versions, and git metadata (commit history, contributor emails, file change frequency).

**Structural extraction boundaries.** Structural extraction collects schema rather than dumping live database rows, and
does not intentionally collect environment variables or the Rails encrypted credential store.
This is not a guarantee that output is free of secrets or customer information: extracted source can contain hardcoded
values, comments or examples, and Index tools can return that source.
Export-specific scrubbing does not sanitize the structural index.

**Optional session data.** When configured, session tracing records session/trace identifiers, request paths and
controller/action timelines.
Request paths and identifiers can contain sensitive user information.
The configured session store controls where these records live; configured Index session tools can return them.
Session storage and access need their own retention and authorization controls.

| Leak scenario | Attacker gains | Attacker does not gain |
|---|---|---|
| `tmp/woods/` directory exfiltrated | Source code, schema and metadata, including sensitive values present in source; session records if their store is configured here | No additional live database or shell access merely from possessing these files |
| MCP Index Server token leaked (HTTP transport) | Access to published source/metadata and configured session tools, including sensitive content they contain | The packaged default does not boot Rails or provide live database queries or shell execution; custom tool wiring has its own access boundary |
| Notion sync database compromised | Model and column summaries synced to Notion | Anything not mirrored, source code stays local |

**Mitigation.** Treat `tmp/woods/` as source-equivalent, keep it out of world-readable directories and public container
images.
Rotate `WOODS_MCP_HTTP_TOKEN` on compromise.
