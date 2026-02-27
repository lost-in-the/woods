# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in CodebaseIndex, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, email **info@leah.wtf** with:

1. A description of the vulnerability
2. Steps to reproduce
3. The potential impact
4. Any suggested fix (optional)

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

CodebaseIndex runs inside your Rails application and has access to:

- **Application source code** — extracted and written to the output directory as JSON
- **Database schema** — column names, types, indexes, and foreign keys (no row data)
- **Git metadata** — commit history, contributors, file change frequency
- **Runtime state** (Console MCP Server only) — live database queries within a rolled-back transaction

### Output Directory

Extracted data is written to `tmp/codebase_index/` by default. This directory contains your application's source code and schema in structured JSON format. Treat it with the same sensitivity as your source code — do not expose it to untrusted parties.

### Console Server

The Console MCP Server provides live database access. It includes multiple safety layers:

- **SafeContext** wraps all operations in a rolled-back transaction
- **SqlValidator** rejects DML/DDL statements before execution
- **Confirmation** gates guard destructive operations
- **AuditLogger** records all operations to JSONL

Despite these safeguards, the Console Server should only be used in development/staging environments, never in production.

### MCP Transport

The MCP Index Server supports both stdio and HTTP transports. When using HTTP transport, ensure it is not exposed to untrusted networks. The server has no built-in authentication — secure it at the network level.
