---
name: mcp-optimize
description: Configure Woods' MCP servers optimally for a host app — worktree-safe registration, a token-efficient naming convention, and console tool-catalog gating — and check which MCP/console features are enabled. Use when a user says things like "configure woods/MCP with the best optimization for my app", "set up the woods MCP servers", "my MCP tools keep dropping after a worktree switch", "reduce MCP token bloat", or "I updated the gem — what MCP features are available / enabled?".
---

# MCP Optimize

Operational playbook for setting up and tuning the two Woods MCP servers in a
host app. User-facing references: [`docs/MCP_REGISTRATION.md`](../../../docs/MCP_REGISTRATION.md)
(setup + optimization), [`docs/MCP_FEATURE_STATUS.md`](../../../docs/MCP_FEATURE_STATUS.md)
(what's implemented + how to check), [`docs/MCP_SERVERS.md`](../../../docs/MCP_SERVERS.md)
(full tool catalog). This skill is the agent-facing map; read those docs for detail.

Woods ships two servers: **index** (`woods-mcp`, static read-only, no Rails) and
**console** (`woods-console` / `woods-console-mcp`, live Rails DB, opt-in). Keep
them separate — do not merge them.

## A. "Configure with the best optimization for my app"

Work top to bottom; each step is independent.

1. **Discover the current setup.** Look for an existing `.mcp.json` (repo root,
   parent dirs, `~/.claude.json`) and any `config/initializers/woods.rb`. Note
   how many woods servers are registered and under what keys.

2. **Make registration survive worktree switches.** Commit a project-scoped
   `.mcp.json` at the app's repo root (every git worktree checks out the same
   file, so servers ride along — zero re-enable). Template:
   [`docs/examples/mcp.json`](../../../docs/examples/mcp.json). Pre-approve it in
   `.claude/settings.json` with `"enableAllProjectMcpServers": true` (or the
   explicit `"enabledMcpjsonServers": [...]` allowlist). Do **not** rely on
   `--scope user` for worktrees (documented no-inheritance bug).

3. **Apply the naming convention** `<app>-<surface>`: surface `woods` = index,
   `live` = console. So `app-one-woods`, `app-one-live`. Drop the `-mcp` suffix;
   don't put `console` in the key (console tools already carry `console_`). This
   trims repeated tool-prefix tokens and disambiguates multi-app setups.

4. **Trim the console tool catalog.** Most sessions only need Tier 1. Set the
   tiers the app actually uses:
   ```ruby
   Woods.configure { |c| c.console_enabled_tiers = [1] }      # read-only only
   Woods.configure { |c| c.console_enabled_tiers = %w[read analytics] }
   ```
   or `WOODS_CONSOLE_TIERS=1` / `WOODS_CONSOLE_TIERS=read,analytics`. Default is
   all four tiers. Tiers: 1 `read` (9), 2 `domain` (9), 3 `analytics` (10),
   4 `guarded` (sql/query + opt-in eval).

5. **Leave `console_eval` off** unless the user explicitly wants live Ruby eval.
   It's gated behind `console_unsafe_eval_enabled` + Tier 4 and refuses in
   production.

6. **Index server needs no tuning** — it auto-gates (14 always-on + 15
   wiring-conditional).

Recommend, then apply only what the user confirms — editing a host app's
`.mcp.json`/initializer is their call.

## B. "I updated the gem — what MCP features exist / are enabled?"

1. Read [`docs/MCP_FEATURE_STATUS.md`](../../../docs/MCP_FEATURE_STATUS.md) — the
   gating matrix is the source of truth for what's on by default and how to
   enable each feature.
2. Check `docs/CONFIGURATION_REFERENCE.md` for new config accessors
   (e.g. `console_enabled_tiers`).
3. To see what's live in the running app: `/mcp` (connected tools), `woods_status`
   (index health/wiring), `console_status` (console models/connection).
4. A "missing" tool is almost always gating, not a bug — confirm the relevant
   tier is selected and the collaborator/opt-in is enabled.

## Guardrails

- Two servers, not one. The live-DB console stays isolated from the read-only
  index (privilege isolation). See `docs/design/CONSOLE_SERVER.md`.
- Config knobs that actually exist: `console_enabled_tiers` (+ `WOODS_CONSOLE_TIERS`),
  `console_mcp_enabled`, `console_unsafe_eval_enabled`, `console_embedded_read_tools`.
  Don't invent knobs — verify against `lib/woods.rb` `Configuration`.
- All guidance is database-agnostic (MySQL and PostgreSQL identical here).
