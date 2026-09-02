---
name: woods-agent-enable
description: Make a repository's coding agents use the Woods index by default — wire the MCP server into project configuration, add index-first guidance to CLAUDE.md/AGENTS.md, and optionally create a project skill. Use when a user wants agents to "know" their Rails codebase, asks to add Woods to a team's agent setup or repository instructions, or wants codebase intelligence available in every session without per-user installs.
---

# Enable Woods for a repository's agents

Installing the gem gives one operator an index; this skill gives every future agent session one. Wiring is three small, reviewable changes to the host repository. Each edits shared, checked-in files, so propose the diff and get approval before writing, match the repository's existing conventions, and leave unrelated content untouched.

## Preflight

Confirm Woods actually works before advertising it to every future session:

```bash
bundle info woods
bin/rails woods:validate
bin/rails woods:stats
```

A missing gem or index means setup comes first (woods-setup). Record the index path and whether the app runs on the host or in Docker — the MCP entry must use the command shape that matches (woods-mcp-config has the shapes).

## 1. Project MCP configuration

Add the Index Server to the repository's checked-in MCP configuration (`.mcp.json` for Claude Code; adapt to the team's client) using the Index-only shape from woods-mcp-config, so every clone gets the server without per-user setup. Do not wire Console MCP at the project level: it is live-data access and stays a per-user, explicitly authorized opt-in.

## 2. Index-first guidance in the agent instructions

Add a short section to the repository's agent instructions (CLAUDE.md, AGENTS.md, or the team's equivalent). Keep it to the contract, not a tool manual — the connected server's own tool list is the manual:

```markdown
## Codebase index (Woods)

A Woods MCP server ("woods") serves a runtime-accurate index of this app.
Call `woods_status` first; for structural questions prefer `search` →
`lookup` → `dependencies`/`dependents`/`trace_flow` over broad file reading
or grep. "Not found" is evidence about the index, not the code — check
generation freshness before concluding. After changing files, refresh with
`bin/rails woods:incremental` (or run the `woods:watch` daemon).
```

Adjust names and commands to the app (Docker prefix, custom index path, task aliases). If the repository already documents agent tooling, extend that section rather than adding a competing one.

## 3. Optional: a project skill

When the team wants stronger triggering than standing instructions provide, create a repository-level skill (for Claude Code: `.claude/skills/<app>-codebase/SKILL.md`) whose description names the application and its domains, and whose body applies the woods-investigate workflow to this codebase specifically: the entry-point identifiers worth knowing, domain cluster names, and local conventions. Seed that content from real `domain_clusters` and `pagerank` output rather than inventing it, and note in the skill that the index — not the skill text — is the source of truth as the app evolves.

## Handoff

Report the files changed, the MCP entry added, and one verified end-to-end call (`woods_status` through the configured client, not a raw JSON-RPC probe). Remind the owner that agent sessions pick up the changes on their next start, and that the index only stays useful if extraction stays current.

Canonical guides: [AGENT_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md), [AGENT_GUIDE.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_GUIDE.md).
