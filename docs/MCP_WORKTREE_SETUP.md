# MCP Registration in Git Worktrees

When you work in a git worktree — a separate directory checked out from the same repository — your MCP tools may not be available to subagents running in that directory. This page explains why, how to fix it, and how to confirm the registration took effect.

## Why Worktree Subagents May Not See Woods Tools

MCP server registration in Claude Code is controlled by `.mcp.json` files. Claude Code discovers these files by walking up the directory tree from the working directory. It stops at the first `.mcp.json` it finds (or at `~/.claude/settings.json` for global registrations).

A git worktree has its own root directory separate from the main repository checkout. When a subagent starts inside the worktree root, it walks up from that path — not from the main repository root. Unless a `.mcp.json` exists inside the worktree directory tree or in an ancestor shared with both checkouts, the subagent sees no MCP servers.

Example directory layout:

```
~/work/my-app/            ← main checkout — has .mcp.json here
~/work/my-app-feature/    ← worktree — no .mcp.json, so MCP tools are missing
```

A subagent spawned in `~/work/my-app-feature/` will not find the `.mcp.json` from `~/work/my-app/`.

## Fix: Add a `.mcp.json` to the Worktree Root

Create a `.mcp.json` in the worktree's root directory with the same woods server entries you use in the main checkout:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "woods-console": {
      "command": "docker",
      "args": [
        "compose", "exec", "-i", "app",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

Adjust the paths and arguments to match your project's setup. In particular:

- `./tmp/woods` is a relative path — it resolves against the worktree root, which is correct if extraction output is written into each worktree separately.
- If you share a single extraction output directory between checkouts, use the absolute path to the shared output: `"/absolute/path/to/main-checkout/tmp/woods"`.
- For Docker projects, the `docker compose exec` command works the same from any host path.

## How Plugin Discovery Works

Claude Code also discovers MCP servers registered in plugin manifests. A plugin at `~/.claude/plugins/<plugin-name>/admin-tools/.mcp.json` is loaded globally — its servers are available in any session regardless of working directory.

If your team distributes the woods MCP registration through a shared plugin, the worktree problem does not apply. Check whether woods is already registered this way:

```bash
ls ~/.claude/plugins/
# look for a directory containing admin-tools/.mcp.json
cat ~/.claude/plugins/<plugin-name>/admin-tools/.mcp.json
```

If you find the woods servers registered there, subagents in any worktree will have access automatically — you do not need a per-worktree `.mcp.json`.

## Verifying MCP Registration for a Subagent

### Option 1: List tools from a claude session in the worktree

Open a new Claude Code session with the worktree as the working directory and run:

```
/mcp
```

This lists all connected MCP servers and their tools. If `woods` and/or `woods-console` appear, registration is working.

### Option 2: Check via the woods status tool

Ask Claude to call the status tool:

```
Use woods-console console_status to check what models are available.
```

If the tool runs successfully, MCP is registered and the console server is reachable.

### Option 3: Inspect the MCP config that Claude Code loaded

From the worktree directory, run:

```bash
cat .mcp.json
```

If the file exists and contains the woods entries, Claude Code will use it. If the file is missing, check parent directories up to your home directory for any `.mcp.json` that would be discovered.

## Extraction Provenance in Worktrees (`git_branch` / `git_sha`)

`manifest.json` records the `git_branch` and `git_sha` the extraction ran against. In a linked worktree, `.git` is a **file** containing a `gitdir:` pointer to the real git directory — frequently an absolute host path — rather than a `.git` directory.

Woods resolves provenance with worktree-aware git plumbing (`git -C <root> rev-parse`, plus reading the linked `HEAD`), so an ordinary worktree reports the correct branch and SHA. When the pointed-to git directory **cannot be resolved** — most commonly a worktree extracted inside a container where the host path isn't mounted — Woods records `git_branch: "unknown"` / `git_sha: "unknown"` rather than a stale, misleading value (it no longer silently falls back to a baked `GIT_BRANCH`/`GIT_SHA` build arg).

To get correct provenance from a containerized worktree, mount the directory the `gitdir:` pointer references (the parent repository's `.git`) into the container so git can resolve it. Temporal snapshots skip an `"unknown"` SHA, so misleading provenance never keys a snapshot.

## Troubleshooting

**"Unknown tool" or "no MCP server named woods"**

The woods MCP server is not registered for this session. Add a `.mcp.json` to the worktree root as shown above, then restart the session.

**Console server starts but returns "unsupported: Not yet implemented in embedded mode" for console_sql / console_query**

The console server is registered and reachable, but `embedded_read_tools` is disabled (the default). To enable console_sql and console_query in embedded mode, see the [Console MCP Setup guide](CONSOLE_MCP_SETUP.md) — specifically the `embedded_read_tools: true` option for the Rack middleware.

**Extraction output is empty or stale in the worktree**

Extraction writes to `tmp/woods/` relative to the Rails application root (inside the container). If the worktree's volume mount points to a different host path than the main checkout, run extraction again from the worktree:

```bash
docker compose exec app bundle exec rake woods:extract
```

See [DOCKER_SETUP.md](DOCKER_SETUP.md) for the full Docker workflow.

**Worktree `.mcp.json` conflicts with main checkout `.mcp.json`**

Each file is independent — Claude Code loads the one closest to the working directory. There is no inheritance or merging between them. Keep both files in sync manually, or move the shared configuration into a global plugin manifest.
