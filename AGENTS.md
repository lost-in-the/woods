# Woods — Agent Instructions

Woods is a Ruby gem that extracts structured data from Rails applications via runtime introspection and serves it to AI tools via MCP (Model Context Protocol). It boots the Rails app, queries `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs, then writes JSON that AI tools read through two MCP servers: an **Index Server** (27 tools, reads pre-extracted JSON, no Rails required) and a **Console Server** (31 tools, bridges to a live Rails process for real data queries).

## Key Documentation

| Document | Purpose |
|----------|---------|
| [CLAUDE.md](CLAUDE.md) | Project conventions, architecture, code style, gotchas |
| [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) | Deep reference for agents using the MCP tools |
| [docs/MCP_SERVERS.md](docs/MCP_SERVERS.md) | Full tool catalog, setup for all clients |
| [docs/MCP_TOOL_COOKBOOK.md](docs/MCP_TOOL_COOKBOOK.md) | Scenario-based tool usage examples |

## MCP Server Setup

**Index Server — Claude Code** (`.mcp.json` in project root):

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

**Index Server — Cursor / Windsurf**:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp",
      "args": ["/path/to/rails-app/tmp/woods"]
    }
  }
}
```

> Use `woods-mcp-start` on Claude Code for automatic restart after crashes. Use `woods-mcp` on Cursor, Windsurf, or other MCP clients.

**Console Server** (optional, requires live Rails):

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "woods-console-mcp"
    }
  }
}
```

Run `bundle exec rake woods:extract` (or `docker compose exec app bundle exec rake woods:extract`) before starting the Index Server.

## Quick Reference: Common Tools

| Tool | Server | What It Does |
|------|--------|-------------|
| `lookup` | Index | Full unit by identifier — source with inlined concerns, schema, callbacks, associations |
| `search` | Index | Regex search across identifiers, source code, or metadata fields |
| `dependencies` | Index | Forward dependency tree — what a unit depends on (BFS with depth control) |
| `dependents` | Index | Reverse dependency tree — what depends on a unit (BFS with depth control) |
| `trace_flow` | Index | Execution flow from an entry point through the dependency graph |
| `graph_analysis` | Index | Structural analysis: orphans, dead ends, hubs, cycles, bridges |
| `pagerank` | Index | Units ranked by structural centrality (higher = wider blast radius) |
| `framework` | Index | Search Rails/gem internals by concept keyword |
| `console_count` | Console | Count records matching scope conditions |
| `console_diagnose_model` | Console | Full model diagnostic: counts, recent records, aggregates |

## Critical Implementation Rules

- **Extraction runs inside Rails; MCP servers run on the host.** Never point the Index Server at a container-internal path like `/app/tmp/woods`. Use the host-side volume mount path.
- **`lookup` returns full units with inlined concerns and prepended schema.** The `source_code` field includes concern source appended inline — this is the key differentiator from file-level tools. Set `include_source: true` to get it.
- **`search` returns identifiers, not full units.** Follow up with `lookup` to get the complete unit for any result that needs its source or metadata.
- **Use the `via` parameter on `dependencies`/`dependents` to filter relationship types.** Pass an array of strings: `["link_to", "form_action"]` for UI navigation edges, `["belongs_to", "has_many"]` for model associations, `["include"]` for concern inclusion.
- **Navigation edges** (`link_to`, `redirect_to`, `form_action`) trace UI user journeys. View templates produce `link_to` edges; controllers produce `redirect_to` edges; forms produce `form_action` edges.
- **`search` accepts a `types` filter** to scope queries by unit type: `["model"]`, `["controller", "route"]`, etc.
- **Graph analysis tools** (`graph_analysis` with `analysis:` set to `"orphans"`, `"hubs"`, `"cycles"`, `"bridges"`, or `"dead_ends"`) are the right tool for dead code detection and architecture analysis — not `search`.
- **Console Server safety model.** Every query runs in a rolled-back transaction — writes appear to succeed but are silently discarded. SQL validation blocks DML/DDL at the string level before any database interaction. Tier 4 tools additionally require confirmation and are recorded in an audit log. See [docs/CONSOLE_MCP_SETUP.md — Safety Model](docs/CONSOLE_MCP_SETUP.md#safety-model) for the full five-layer breakdown.
- **Some unit types require full extraction to update** (routes, middleware, engines, state machines, events, factories). Incremental mode skips these.
