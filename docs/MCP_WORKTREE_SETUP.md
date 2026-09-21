# MCP Registration in Git Worktrees

> **Claude Code specific.** Other MCP clients manage registration and subagent tool access differently. Use the client's current documentation alongside the Woods [MCP setup guide](MCP_SERVERS.md).

A git worktree is a separate checkout. For Woods, verify both which servers a session can access and which checkout's index those servers serve.

## Separate sessions and inherited subagents

A **new Claude Code session launched in a worktree** can have different MCP registrations from a session in the main checkout:

| Registration scope | Location | Availability |
|---|---|---|
| Local | Project entry in `~/.claude.json` | The project where the server was registered |
| Project | `.mcp.json` in the project root | That project, subject to client approval/settings |
| User | `mcpServers` in `~/.claude.json` | Across the user's projects |

A tracked `.mcp.json` may already be present in another worktree; a local, untracked file will not be copied by Git. User-level registration can make a server available across checkouts, but its configured paths still determine which index it serves.

An **inherited subagent** receives the parent conversation's MCP tools, subject to tool restrictions. Changing the subagent's working directory does not by itself launch another Woods server or switch the served index. Distinguish this from starting an independent client process in that directory.

See Claude Code's [MCP installation scopes](https://code.claude.com/docs/en/mcp#mcp-installation-scopes) and [subagent tool access](https://code.claude.com/docs/en/sub-agents#available-tools). Do not diagnose registration by assuming the client searches ancestor directories for the nearest `.mcp.json`.

## Configure a server for the intended checkout

First check `/mcp` in the session that needs Woods. If a suitable server is already connected, verify its index before adding a duplicate registration.

For a host with the application's Ruby bundle installed, a project-root `.mcp.json` can select the bundle and index explicitly:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "/absolute/path/to/worktree/tmp/woods"],
      "env": {
        "BUNDLE_GEMFILE": "/absolute/path/to/worktree/Gemfile"
      }
    }
  }
}
```

Replace both paths with the intended Rails worktree. Preserve other server entries. These absolute paths are machine-specific; do not commit them as shared team defaults. Follow the client's approval/reconnection steps, then verify the connection below.

For Docker, use the [container-first setup](DOCKER_SETUP.md#default-run-it-through-the-application-container). Select the intended Compose project and service, and verify that its mounted application directory is the worktree you mean to index. `docker compose exec` targets an existing container; running the command from a different checkout does not change that container's mounts. The index path must be visible inside that container.

Keep a separate output directory for each checkout when you need checkout-specific answers. If you intentionally point at another checkout's index, Woods serves that published content; registration alone does not make it describe the current worktree.

## Plugin-provided servers

An enabled plugin can supply MCP server definitions, but installing a plugin does not establish that a Woods server is connected to the intended checkout. Availability depends on the plugin's configuration, enabled scope, and the client's tool restrictions. Check `/mcp` rather than assuming a fixed path under `~/.claude/plugins/` or global availability.

The Woods setup/configuration skills help configure a server; their presence alone is not verification that the Index Server is running. See [agent setup](AGENT_SETUP.md).

## Verify registration and the served index

1. Open `/mcp` in the relevant Claude Code session and inspect the Woods connection and available tools.
2. Call the Index Server's `woods_status`. Check `index_dir`, generation, and available freshness/provenance information against the intended extraction. A successful connection to the wrong index is still the wrong setup.
3. Use `search` and typed `lookup` for a known unit from that checkout. When checking a subagent, verify that it can call the inherited tools and is using the same intended index.

The optional Console Server is a separate connection to a booted Rails application. If deliberately enabled, check it with `console_status` and verify its application/container separately. Console access is not required to verify the Index Server.

## Extraction Provenance in Worktrees (`git_branch` / `git_sha`)

The published payload's `manifest.json` records the extraction's `git_branch` and `git_sha`. In a linked worktree, `.git` is a file containing a `gitdir:` pointer, often to an absolute host path. That private worktree directory also refers to the parent repository's shared Git data.

Woods uses worktree-aware Git commands. If a present `.git` cannot be resolved, provenance is `"unknown"`; stale `GIT_BRANCH`/`GIT_SHA` values are not substituted. Those environment variables are fallbacks only when the root has no `.git` or Git is unavailable. Temporal snapshots skip an unknown SHA.

For extraction in a container, make the canonical Git directory and the worktree's pointer resolvable there. Mounting only the private worktree Git directory can leave its shared object store unreachable. Follow the [Git provenance troubleshooting guide](TROUBLESHOOTING.md) for mount and `WOODS_GIT_DIR` guidance, and the [published index layout](INDEX_LAYOUT.md) when locating the manifest.

## Troubleshooting

**Woods or an expected tool is absent**

Check `/mcp` for connection errors, enabled registration scopes, and project approvals. For a subagent, also check its tool restrictions. Compare the requested tool with the [supported tool surface](MCP_SERVERS.md#conditional-index-capabilities); some tools require optional collaborators and are not registered by the packaged server. Do not add duplicate registrations before establishing which case applies.

**The server connects but shows another checkout**

Inspect its configured bundle, index path, Compose project/service, and container mounts. Re-extract from the intended Rails checkout into its own output directory, then reconnect to that index and repeat `woods_status`. See [Docker setup](DOCKER_SETUP.md).

**Two registrations use the same server name**

Check the client's [scope precedence](https://code.claude.com/docs/en/mcp#scope-hierarchy-and-precedence) and the effective connection shown by `/mcp`. Do not assume the two definitions merge or that a project file overrides every other scope.

**Console SQL/query tools are absent or unsupported**

Console read-tool availability is configured separately from registration. Follow [Console MCP setup](CONSOLE_MCP_SETUP.md) for the supported 9-tool default and optional 11-tool mode.
