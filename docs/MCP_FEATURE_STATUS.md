# MCP & Console Feature Status

A single place to answer two questions agents and users ask often:

1. **What MCP/console features and config knobs exist, and are they on by default?**
2. **How do I check what's actually active in *my* app right now?**

For setup and optimization steps, see [MCP_REGISTRATION.md](MCP_REGISTRATION.md).
For the full tool catalog, see [MCP_SERVERS.md](MCP_SERVERS.md).

## Feature & gating matrix

| Feature | Default | How to enable / control | Notes |
|---|---|---|---|
| Index server core tools (14) | **On** | none | Always registered; no Rails needed |
| Index semantic search (`codebase_retrieve`) | Off until embedded | configure an embedding provider + run `woods:embed` | Activates automatically once a provider is set |
| Index operator tools (5) | Off | wire operator (StatusReporter/ErrorEscalator/PipelineGuard) | Registers only when wired |
| Index feedback tools (4) | Off | configure a feedback store | Registers only when wired |
| Index snapshot tools (4) | Off | `enable_snapshots = true` + snapshot store (migrations 004/005) | Registers only when wired |
| Index `session_trace` | Off | `session_tracer_enabled = true` + a session store | Registers only when wired |
| Index `notion_sync` | Off | `notion_api_token` + `notion_database_ids` | Registers only when wired |
| Console server | **Off** | `console_mcp_enabled = true` | Touches the live DB — opt-in by design |
| **Console tier gating** | All 4 tiers | `console_enabled_tiers` / `WOODS_CONSOLE_TIERS` | Restrict to e.g. `[1]` to cut ~⅔ of the catalog |
| **`console_eval`** | **Off (not registered)** | `console_unsafe_eval_enabled = true` (or `WOODS_CONSOLE_UNSAFE_EVAL=true`) **and** Tier 4 enabled | Opt-in; refuses in `Rails.env.production?` |
| Console raw SQL/query (`console_sql`/`console_query`) | Registered; execution off in embedded | `console_embedded_read_tools = true` | SqlValidator + rolled-back transaction still apply |
| Console blocked tables (Layer 1) | On (sensible defaults) | `console_blocked_tables` | See `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` |
| Console credential defense (Layer 2) | On | `console_credential_defense_enabled` | Scans output for live credentials |
| Console column/EAV redaction (Layer 3) | Off until configured | `console_redacted_columns`, `console_redacted_key_values` | |

A "default console" therefore advertises **30** tools (all tiers except the
opt-in `console_eval`); restricting `console_enabled_tiers` lowers that further.

## How to check what's active in your app

| Question | Do this |
|---|---|
| Which MCP servers/tools are connected in my client? | Run `/mcp` in Claude Code |
| Is the index healthy, and what's wired? | Call the `woods_status` index tool |
| Pipeline/extraction state | Call the `pipeline_status` index tool |
| Which models/connection does the console see? | Call the `console_status` console tool |
| What config is loaded? | Inspect `config/initializers/woods.rb` (or wherever `Woods.configure` runs) |

## "I updated the gem — what's new for MCP?"

1. Read this matrix and [MCP_REGISTRATION.md](MCP_REGISTRATION.md) — both track
   the current gating knobs.
2. Check `docs/CONFIGURATION_REFERENCE.md` for any new config accessors
   (e.g. `console_enabled_tiers`).
3. Diff your registered catalog: run `/mcp` and compare the tool list against the
   tables in [MCP_SERVERS.md](MCP_SERVERS.md).
4. If a tool you expect is missing, it's almost always gating — confirm the
   relevant row above is enabled (tier selected, collaborator wired, opt-in set).
