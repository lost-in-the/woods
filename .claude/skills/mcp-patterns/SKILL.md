---
name: mcp-patterns
description: Design rules and reference patterns for building MCP servers in CodebaseIndex
disable-model-invocation: true
user-invocable: false
---
# MCP Server Patterns

Design rules and reference implementation for building MCP servers in CodebaseIndex.

## Reference Implementation

Read `lib/codebase_index/mcp/server.rb` before building any new MCP server or tool. It demonstrates the established patterns:

- Server built via `Server.build(...)` class method returning a configured `::MCP::Server`
- Tools defined inline via `define_<name>_tool` private methods with closures over a reader/context object
- All tools return `MCP::Tool::Response` via a shared `text_response` helper
- Resources and resource templates registered alongside tools
- Transport is the caller's concern — server doesn't choose stdio vs. HTTP

## Design Rules

1. **Structured tools over raw eval.** Every tool has a named operation, typed parameters, and bounded output. Never expose `eval` or arbitrary code execution without explicit safety layers (see `docs/design/CONSOLE_SERVER.md` Phase 4).
2. **Read-only by default.** Tools that query data need no special guards. Tools that mutate state require safety layers documented in `docs/design/CONSOLE_SERVER.md` (transaction rollback, statement timeout, human confirmation).
3. **Truncation and budgeting.** All tools that return variable-length data must accept a `limit` parameter and truncate results. Use `truncate_section` pattern from the index server.
4. **Error responses are tool responses.** Return errors as `text_response` with a clear message, not exceptions. The MCP protocol has no error channel — the agent sees the tool result.
5. **No Rails boot in the MCP process.** The index server reads JSON from disk. The console server delegates to a bridge process inside Rails. MCP server processes themselves never call `Rails.application` or `ActiveRecord`.
6. **Backend agnostic.** MySQL and PostgreSQL must both work. If a tool generates SQL, handle dialect differences or delegate to ActiveRecord.
7. **YARD-document every tool definition** — description, parameter types, example responses.

## Adding a New Tool to an Existing Server

1. Add a `define_<name>_tool` private method following the existing pattern in `server.rb`.
2. Call it from `build` in the registration block.
3. Add specs in `spec/mcp/` — test the tool response format, parameter validation, and edge cases.
4. Update `docs/design/AGENTIC_STRATEGY.md` if the tool serves a retrieval pattern defined there.

## Building a New MCP Server

1. Read the relevant design doc first (e.g., `docs/design/CONSOLE_SERVER.md`).
2. Follow the `Server.build` pattern — single entry point, tools as private method definitions.
3. Create an executable in `exe/` (e.g., `exe/codebase-console-mcp`).
4. Spec the server in `spec/mcp/`.
5. Update `docs/MCP_SERVERS.md` and `docs/design/AGENTIC_STRATEGY.md` with the new server's tools and when agents should use them.
