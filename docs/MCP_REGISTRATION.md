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

## 3. Tool-surface audit

Estimated `tools/list` payload (description + JSON schema), at the repo's own
4.0 chars/token floor (`docs/TOKEN_BENCHMARK.md`). These are conservative
description-and-schema estimates; real payloads include extra JSON structure, so
treat them as a floor.

| Server | Tools | Est. tokens | Conditional gating today? |
|---|---|---|---|
| Index (`woods-mcp`) | 29 | ~3,221 | **Yes** — 14 always-on, 15 register only when their collaborator is wired (operator, feedback, snapshot, session-trace, notion) |
| Console (`woods-console`) | 31 | ~2,402 | **No** — all 31 register unconditionally |
| **Combined, one app** | 60 | **~5,623** | — |
| **Two apps × both servers** | 120 | **~11,250** | — |

For context, Anthropic reports tool-selection accuracy degrading once tool
definitions pass ~10K tokens / 10+ tools, and recommends dynamic discovery past
that point. A single combined 60-tool server lands squarely in that zone, which
is the central argument against merging the two servers into one flat surface.

### A. Could tools be combined into toolsets?

**Group, don't merge.** Collapsing distinct operations into one parameter-overloaded
mega-tool (e.g. a single `console_read` with an `op:` discriminator) trades a
lower tool count for per-call ambiguity — the opposite of what improves
selection accuracy. The prevailing pattern (GitHub MCP's `--toolsets`) is to keep
tools distinct but **gate which groups load**.

- **Index server — already done.** It registers 14 always-on tools and gates the
  other 15 behind wiring (operator/feedback/snapshot/session-trace/notion). A
  pattern-only extract host sees only the 14 it can use. No change needed.
- **Console server — the opportunity.** It registers all 31 tools regardless of
  use. Most sessions touch only **Tier 1** (the 9 read-only tools:
  count/sample/find/pluck/aggregate/association_count/schema/recent/status).
  Tiers 2 (domain, 9), 3 (analytics, 10), and 4 (guarded, 3) are coherent groups
  that many sessions never call. Gating them behind a config/env toolset selector
  — mirroring the index server's conditional registration — would let a typical
  session load ~9 console tools instead of 31, cutting roughly two-thirds of the
  console catalog.

### B. Bloat reduction (token count on load)

Concrete, low-risk trims, in priority order:

1. **Don't register `console_eval` when it's disabled.** In embedded mode
   `console_eval` always returns an instructional refusal, yet it still registers
   and advertises a long four-sentence description. Skipping registration when
   the unsafe-eval opt-in is off removes dead catalog weight (same principle the
   index server already applies to unwired tools).
2. **Add console toolset gating** (see A) — the single largest lever:
   ~9 tools instead of 31 for read-only sessions.
3. **De-duplicate the scope-suffix boilerplate.** The string
   *"Suffixes: _eq _gt _lt _in _null _present. Complex queries: use
   console_query."* is repeated verbatim in ~6 Tier-1 tool descriptions
   (~110 chars each). State it once (server-level guidance) and trim it from the
   per-tool descriptions.
4. **Tighten the longest index descriptions.** Index descriptions average ~291
   chars vs the console server's ~131; a pass over the wordiest ones (`lookup`,
   `search`, `codebase_retrieve`, `domain_clusters`) recovers a few hundred
   tokens without losing meaning.
5. **Apply the naming convention** (§2) — ~450 tokens of repeated prefix across a
   two-app setup.

None of these require merging servers; they're independent, additive cleanups.

### C. Namespacing

Covered in §2. Two structural notes the audit surfaced:

- **Redundant `console` doubling** — `mcp__<app>-console__console_count`. The
  `<app>-live` convention removes it.
- **The server key is the only namespace you get.** Since the spec offers none
  and a future namespacing proposal (SEP-993) is still a closed draft, treat the
  key as a deliberate, short, structured identifier rather than a free-form
  label. If you later front several servers with an aggregator/proxy, it will
  prefix tools as `Server__tool` — another reason to keep the server key concise.

---

## 4. What this does *not* do

This guide deliberately stops at registration + audit. It does **not** merge the
two servers. The consolidation research concluded that the live-database console
surface should stay isolated from the always-on read-only index (privilege
isolation, blast-radius containment, and avoiding a flat 60-tool catalog), and
that the re-enable friction — the thing that motivated the question — is fully
solved by registration scope (§1). The optional, additive combined executable and
the console-toolset gating in §3A remain available as future work if convenience
demand justifies them.
