---
name: woods-mcp-config
description: Use when configuring a Woods Index or Console MCP connection for a Rails project, Docker environment, or authenticated HTTP client.
---

# Woods MCP configuration

## Preflight

```bash
bundle info woods
bin/rails woods:validate
bin/rails woods:stats
```

This skill targets Woods 2.0.0 or later. Detect the MCP client, app root, host vs Docker Rails process, host-visible index path, and whether live-data access is actually required.

Default to Index-only. It reads generated code context and exposes 14 tools. Console MCP boots Rails and reads live data; ask before enabling it.

## Shape 1: Index-only

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/app"
    }
  }
}
```

Use this shape for Claude Code, Cursor, Windsurf, and other stdio clients, adapted to the client's configuration location. `woods-mcp-start` validates and launches; it does not install or auto-restart.

For Docker extraction, use the host side of the mounted `tmp/woods/`, never a container-only path.

## Shape 2: Index plus authorized Console

Add a direct Console process:

```json
"woods-console": {
  "command": "bundle",
  "args": ["exec", "woods-console-mcp"],
  "cwd": "/absolute/path/to/app"
}
```

For Docker/SSH, configure `~/.woods/console.yml` or `WOODS_CONSOLE_CONFIG`; the launcher owns process replacement. Docker stdio requires an interactive stdin (`docker exec -i`) if configured directly.

Console registers nine default tools. `config.console_embedded_read_tools = true` explicitly adds `console_sql` and `console_query` for eleven total. Tier 2, Tier 3, and `console_eval` are inventory-only in supported packaged modes.

## Shape 3: Authenticated Console HTTP

Use only after authorization and server-side setup:

```json
"woods-console": {
  "type": "streamable-http",
  "url": "https://app.example.test/mcp/console",
  "headers": { "Authorization": "Bearer <token>" }
}
```

Require `console_mcp_enabled`, a strong token, allowed origins, TLS, and the Console security controls. Never commit the token or expose an unauthenticated listener.

## Verify

Reconnect through the client so it performs MCP initialization. Call `woods_status`, `search`, and `lookup`. For Console, inspect the registered list and call `console_status` only in the authorized environment.

Do not use initialize-less JSON-RPC pipes as proof of MCP health. Do not claim conditional Index or inventory-only Console schemas are callable.

Canonical guide: [MCP_SERVERS.md](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md).
