# MCP Servers

CodebaseIndex ships two MCP (Model Context Protocol) servers that integrate with AI development tools like Claude Code, Cursor, and Windsurf.

## Overview

| | Index Server | Console Server |
|---|---|---|
| **Purpose** | Query pre-extracted codebase data | Run live queries against a Rails app |
| **Requires Rails?** | No — reads JSON from disk | Yes — bridges to a Rails process |
| **Tools** | 27 | 31 |
| **Transport** | Stdio (default), HTTP | Stdio |
| **Data source** | `tmp/codebase_index/` output | Live database + application state |
| **Safety** | Read-only (extraction output) | Rolled-back transactions, SQL validation |

## Index Server

The Index Server reads pre-extracted data from disk and serves it via MCP. No Rails boot required — it works with the JSON output from `rake codebase_index:extract`.

### Setup

```bash
# Start with stdio transport (default for MCP clients)
codebase-index-mcp /path/to/rails-app/tmp/codebase_index

# Or use the self-healing wrapper (installs deps, validates index)
codebase-index-mcp-start /path/to/rails-app/tmp/codebase_index

# HTTP transport (for shared/remote access)
codebase-index-mcp-http /path/to/rails-app/tmp/codebase_index
```

### Claude Code Configuration

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["/path/to/rails-app/tmp/codebase_index"]
    }
  }
}
```

### Cursor / Windsurf Configuration

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp",
      "args": ["/path/to/rails-app/tmp/codebase_index"]
    }
  }
}
```

### Tools (27)

#### Core Query (6)

| Tool | Description |
|------|-------------|
| `lookup` | Look up a code unit by exact identifier. Options for including source and selecting metadata sections. |
| `search` | Search units by regex pattern across identifiers, source code, or metadata fields. |
| `dependencies` | Traverse forward dependencies (what a unit depends on) with BFS depth control. |
| `dependents` | Traverse reverse dependencies (what depends on a unit) with BFS depth control. |
| `structure` | Get codebase structure: manifest summary or full unit breakdown by type. |
| `recent_changes` | List recently modified units sorted by git timestamp. |

#### Graph Analysis (3)

| Tool | Description |
|------|-------------|
| `graph_analysis` | Structural analysis: orphans, dead ends, hubs, cycles, bridges. |
| `pagerank` | PageRank importance scores — higher means more structurally central. |
| `framework` | Search Rails/gem framework source by concept keyword (e.g., "has_many", "before_action"). |

#### Flow & Session (2)

| Tool | Description |
|------|-------------|
| `trace_flow` | Trace execution flow from an entry point (e.g., `UsersController#create`) through the codebase. |
| `session_trace` | Assemble context from browser session traces (requires session tracer middleware). |

#### Semantic Search (1)

| Tool | Description |
|------|-------------|
| `codebase_retrieve` | Natural language query with semantic search, ranked by relevance within a token budget. Requires embedding provider configuration. |

#### Pipeline Management (5)

| Tool | Description |
|------|-------------|
| `pipeline_extract` | Trigger extraction pipeline (full or incremental). Rate-limited to 5-minute cooldown. |
| `pipeline_embed` | Trigger embedding generation for extracted units. |
| `pipeline_status` | Current pipeline state: last extraction time, unit counts, staleness indicators. |
| `pipeline_diagnose` | Classify a pipeline error and suggest remediation steps. |
| `pipeline_repair` | Clear stale locks or reset rate limit cooldowns. |

#### Feedback (4)

| Tool | Description |
|------|-------------|
| `retrieval_rate` | Record quality rating (1-5) for a retrieval result. |
| `retrieval_report_gap` | Report a missing unit that should have appeared in results. |
| `retrieval_explain` | Get feedback statistics: average scores, gap counts, trends. |
| `retrieval_suggest` | Analyze feedback to suggest retrieval improvements. |

#### Temporal Snapshots (4)

| Tool | Description |
|------|-------------|
| `list_snapshots` | List past extraction snapshots with timestamps and branch info. |
| `snapshot_diff` | Compare two snapshots — added, modified, deleted units. |
| `unit_history` | Track how a single unit changed across snapshots. |
| `snapshot_detail` | Full metadata for a specific snapshot by git SHA. |

#### Notion (1)

| Tool | Description |
|------|-------------|
| `notion_sync` | Sync models and columns to a Notion database. Requires `notion_api_token` and `notion_database_ids` configuration. |

#### Utility (1)

| Tool | Description |
|------|-------------|
| `reload` | Reload extraction data from disk without restarting the server. |

### Resources

| URI | Description |
|-----|-------------|
| `codebase://manifest` | Extraction manifest with version info, unit counts, git metadata |
| `codebase://graph` | Full dependency graph with nodes, edges, type index |

### Resource Templates

| URI Template | Description |
|--------------|-------------|
| `codebase://unit/{identifier}` | Look up a single unit by identifier |
| `codebase://type/{type}` | List all units of a given type |

---

## Console Server

The Console Server connects to a live Rails application and provides database queries, model diagnostics, job monitoring, and guarded operations — all within rolled-back transactions.

### Setup

```bash
codebase-console-mcp
```

The console server uses a bridge architecture to communicate with a Rails process. Configure the connection in `console.yml`:

```yaml
# console.yml
connection:
  mode: direct           # direct, docker, or ssh
  # For docker mode:
  # mode: docker
  # service: web
  # compose_file: docker-compose.yml
```

### Tools (31)

#### Tier 1: Read-Only (9 tools)

Safe, foundational queries against the live database.

| Tool | Description |
|------|-------------|
| `console_count` | Count records matching scope conditions |
| `console_sample` | Random sample of records (max 25) |
| `console_find` | Find a single record by primary key or unique column |
| `console_pluck` | Extract column values with optional distinct (max 1000 rows) |
| `console_aggregate` | Run sum/avg/min/max on a column |
| `console_association_count` | Count associated records for a specific record |
| `console_schema` | Database schema for a model with optional index info |
| `console_recent` | Recently created/updated records (max 50) |
| `console_status` | System health: available models and connection status |

#### Tier 2: Domain-Aware (9 tools)

Higher-level operations: diagnostics, validation, settings, policies.

| Tool | Description |
|------|-------------|
| `console_diagnose_model` | Full model diagnostic: counts, recent records, aggregates |
| `console_data_snapshot` | Record with associations for debugging (depth 1-3) |
| `console_validate_record` | Run validations on an existing record with optional changes |
| `console_check_setting` | Check a configuration setting value |
| `console_update_setting` | Update a setting (requires confirmation) |
| `console_check_policy` | Check authorization policy for a record and user |
| `console_validate_with` | Validate attributes against a model without persisting |
| `console_check_eligibility` | Check feature eligibility for a record |
| `console_decorate` | Invoke a decorator and return computed attributes |

#### Tier 3: Analytics (10 tools)

Performance metrics, job monitoring, cache stats.

| Tool | Description |
|------|-------------|
| `console_slow_endpoints` | Slowest endpoints by response time |
| `console_error_rates` | Error rates by controller or overall |
| `console_throughput` | Request throughput over time |
| `console_job_queues` | Job queue statistics |
| `console_job_failures` | Recent job failures |
| `console_job_find` | Find a job by ID, optionally retry |
| `console_job_schedule` | Scheduled/upcoming jobs |
| `console_redis_info` | Redis server information by section |
| `console_cache_stats` | Cache store statistics |
| `console_channel_status` | ActionCable channel status |

#### Tier 4: Guarded (3 tools)

Require explicit confirmation or have strict validation.

| Tool | Description |
|------|-------------|
| `console_eval` | Execute Ruby code (requires confirmation, 10s timeout) |
| `console_sql` | Execute read-only SQL (SELECT only, validated) |
| `console_query` | Enhanced query builder with joins and grouping |

### Safety Layers

The Console Server implements defense-in-depth:

1. **SafeContext** — Every operation runs in a database transaction that is always rolled back. Writes are silently discarded.
2. **SqlValidator** — Rejects DML (INSERT/UPDATE/DELETE) and DDL (CREATE/ALTER/DROP) at the string level before any database interaction.
3. **Confirmation** — Tier 4 operations and settings updates require explicit human approval.
4. **AuditLogger** — All operations are logged to a JSONL file for review.
5. **ModelValidator** — Validates model names against `ActiveRecord::Base.descendants` to prevent arbitrary class instantiation.

### Job Backend Adapters

The console server auto-detects your job backend:

| Backend | Adapter | Supported Operations |
|---------|---------|---------------------|
| Sidekiq | SidekiqAdapter | Queue stats, failures, find, retry, schedule |
| Solid Queue | SolidQueueAdapter | Queue stats, failures, find, retry, schedule |
| GoodJob | GoodJobAdapter | Queue stats, failures, find, retry, schedule |
