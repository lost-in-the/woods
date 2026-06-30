# MCP Registration, Naming & Tool-Surface Audit

This guide covers how to register Woods' MCP servers so they survive worktree
switches and server drops with **zero re-enable steps**, a concise naming
convention for multi-app setups, and an audit of the tool surface (token cost,
what could be grouped, what could be trimmed).

It complements two existing docs:

- [MCP_SERVERS.md](MCP_SERVERS.md) — the full tool catalog and per-server setup.
- [MCP_WORKTREE_SETUP.md](MCP_WORKTREE_SETUP.md) — why MCP tools go missing in
  git worktrees and the discovery rules behind it.

---

## 1. The re-enable problem (and the cheapest fix)

When the woods MCP servers drop — a worktree switch, a container restart, a
`/mcp` reconnect — you re-approve each server individually. With two servers per
app and multiple apps, that's up to 2×N approvals. The instinct is to *merge the
servers*; the better fix is to change **where the registration lives** so it
travels with you. Merging trades a one-time approval cost for a permanent
security/architecture cost (see the consolidation memo and
[MCP_SERVERS.md](MCP_SERVERS.md)); registration scope solves the actual pain.

Claude Code resolves MCP servers from config by scope, in precedence order
**Local → Project → User → Plugin**. The whole entry from the highest-precedence
source wins — fields are not merged across scopes.

| Scope | Where | Travels into worktrees? | Re-approval needed? |
|---|---|---|---|
| **Project** (`.mcp.json` at repo root) | Committed to the repo | **Yes** — each worktree is a checkout of the same file | Once per machine, then pre-approvable |
| **Plugin manifest** (`~/.claude/plugins/<plugin>/.mcp.json`) | User's plugin dir | **Yes** — loads in every session globally | No (loads on plugin enable) |
| User (`--scope user`) | `~/.claude.json` | **Unreliable** — a sibling/child path with its own `mcpServers` can override with no inheritance (claude-code#16728, closed "not planned") | — |
| Local (default) | Per-project private | No | Yes, every time |

**Recommendation:** commit a **project-scoped `.mcp.json` at each app's repo
root** and pre-approve it. Because every git worktree is its own checkout of that
file, the registration rides along automatically — switching worktrees no longer
drops the servers. For a fleet you manage centrally, a **plugin manifest** gives
the same "register once, available everywhere" property without per-repo files.

### Pre-approval (so you're not prompted per project)

In `.claude/settings.json` (project) or `~/.claude/settings.json` (user):

```json
{ "enableAllProjectMcpServers": true }
```

Or approve specific servers only:

```json
{ "enabledMcpjsonServers": ["app-one-woods", "app-one-live"] }
```

> `enableAllProjectMcpServers` trusts every server listed in a discovered
> `.mcp.json`. Use the explicit `enabledMcpjsonServers` allowlist if you share
> repos with others or don't fully control the committed `.mcp.json`.

---

## 2. Naming convention for multi-app registration

The MCP spec provides **no cross-server namespacing** — tool-name uniqueness is
only guaranteed *within* one server. In Claude Code the server **key** in
`.mcp.json` becomes the tool prefix the model sees:
`mcp__<server-key>__<tool-name>`. So the key *is* your namespace, and its length
is paid on **every** tool, every turn.

A scheme like `app-one-woods-console-mcp` costs a 32-character prefix repeated
across all 31 console tools (~248 tokens for that one server), and
`mcp__app-one-woods-console-mcp__console_count` says "console" twice.

**Recommended convention: `<app>-<surface>`**

| Surface | Key suffix | Server | Why |
|---|---|---|---|
| Static, read-only code index | `woods` | `woods-mcp` (`woods-mcp-start`) | Reads extraction JSON; no Rails |
| Live Rails console / database | `live` | `woods-console` / `woods-console-mcp` | Touches the live DB — the name reminds you which surface is dangerous |

So a two-app setup becomes:

```
app-one-woods   app-one-live   app-two-woods   app-two-live
```

producing clean, self-describing tool ids like
`mcp__app-one-woods__lookup` and `mcp__app-one-live__console_count`.

Rules of thumb:

- **Drop the `-mcp` suffix** — everything in `mcpServers` is an MCP server.
- **Don't put `console` in the key** — the console tools already carry the
  `console_` prefix; `<app>-live` avoids the double-"console".
- **Keep keys short but unambiguous** — the prefix is paid per tool, per turn.

### Prefix cost, measured

| Server key | Prefix chars | × tools | Repeated-prefix cost |
|---|---|---|---|
| `app-one-woods-console-mcp` (current) | 32 | 31 | ~992 chars (~248 tok) |
| `app-one-woods-mcp` (current) | 24 | 29 | ~696 chars (~174 tok) |
| `app-one-live` (recommended) | 19 | 31 | ~589 chars (~147 tok) |
| `app-one-woods` (recommended) | 20 | 29 | ~580 chars (~145 tok) |

Across a four-server (two-app) setup the convention saves roughly **450 tokens**
of pure prefix repetition — small, but free, and it makes the catalog far easier
to read.

A copy-pasteable template lives at [`examples/mcp.json`](examples/mcp.json).

---

## 3. Trimming the tool catalog (token cost on load)

Every registered tool's name + description + JSON schema is sent to the model on
every turn. Two woods servers per app is ~60 tools; several apps multiply that.
Tool-selection accuracy also degrades as the catalog grows, so registering only
what a session needs is both cheaper and more accurate. Woods gives you three
levers, all live today.

### Console tier gating (`console_enabled_tiers`)

The console server's 31 tools fall into four tiers; most sessions only need
Tier 1. Register just the tiers you use:

| Tier | Name | Tools | Typical use |
|---|---|---|---|
| 1 | `read` | 9 read-only (count, sample, find, pluck, aggregate, association_count, schema, recent, status) | Almost every session |
| 2 | `domain` | 9 domain-aware (diagnose_model, validate_*, check_*, decorate, …) | App-specific diagnostics |
| 3 | `analytics` | 10 (slow_endpoints, error_rates, job_*, redis_info, cache_stats, …) | Perf / ops investigations |
| 4 | `guarded` | sql, query (+ opt-in eval) | Raw SQL / custom query building |

```ruby
# config/initializers/woods.rb — read-only sessions only (9 tools instead of ~30)
Woods.configure { |c| c.console_enabled_tiers = [1] }

# By toolset name; equivalent to [1, 3]
Woods.configure { |c| c.console_enabled_tiers = %w[read analytics] }
```

Or set it without touching code — the env var is read at configuration time and
works for both MySQL and PostgreSQL hosts identically:

```bash
WOODS_CONSOLE_TIERS=1          # read-only only
WOODS_CONSOLE_TIERS=read,analytics
WOODS_CONSOLE_TIERS=all        # default
```

The default is all four tiers (no behavior change on upgrade). Restricting to
Tier 1 drops roughly two-thirds of the console catalog.

### `console_eval` is opt-in and off by default

`console_eval` proposes arbitrary Ruby and is a guaranteed refusal unless the
unsafe-eval opt-in is on, so it no longer registers by default — a default
console advertises **30** tools, not 31. It appears only when
`console_unsafe_eval_enabled = true` (or `WOODS_CONSOLE_UNSAFE_EVAL=true`) **and**
Tier 4 is enabled. See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for the full
eval safety contract.

### Index server gating is automatic

The index server already registers only what's wired: 14 tools are always on, and
15 more (operator, feedback, snapshot, session-trace, notion) register only when
their collaborator is configured. A pattern-only extract host sees just the 14 it
can use — nothing to configure.

### Naming (recap)

Apply the `<app>-<surface>` convention from §2 — it removes the redundant
`console` doubling and ~450 tokens of repeated server-key prefix across a two-app
setup.

> **Why not merge the two servers into one?** Keeping the live-database console
> isolated from the always-on read-only index is deliberate — privilege
> isolation and blast-radius containment. The re-enable friction that tempts a
> merge is solved by registration scope (§1), and the token cost by the gating
> above, so a merge buys little. A combined opt-in executable could be added
> later if convenience demand justifies it.
