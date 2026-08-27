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

This skill targets Woods 2.0.0 or later. Detect the MCP client, app root, host vs Docker Rails process, the filesystem context that contains the application bundle and index, and whether live-data access is actually required.

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

Use this shape for any stdio-capable MCP client, adapted to the client's configuration location. `woods-mcp-start` validates and launches; it does not install or auto-restart.

When Woods is installed only in Docker, prefer running the server through the application container:

```json
{
  "mcpServers": {
    "woods": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

Use a host-side bundle only after verifying Ruby, the application bundle, and the index are available on the host. Always pass the path visible to the process that runs `woods-mcp`.

## Shape 2: Index plus authorized Console

After explicit authorization, enable the live-data master switch in the Rails initializer. The process exits while it remains false:

```ruby
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_mcp_token = ENV["WOODS_CONSOLE_MCP_TOKEN"]
end
```

The token authenticates HTTP requests and is not sent by a stdio client. Production Rails boot still requires `WOODS_CONSOLE_MCP_TOKEN` to contain at least 32 characters whenever Console is enabled, including for a stdio-only setup. Keep it in the application's secret store. Outside production, omitting it warns and leaves the Console HTTP endpoint guarded with 401.

Then add a direct Console process:

```json
"woods-console": {
  "command": "bundle",
  "args": ["exec", "woods-console-mcp"],
  "cwd": "/absolute/path/to/app"
}
```

For Docker/SSH, configure `~/.woods/console.yml` or `WOODS_CONSOLE_CONFIG`; the launcher owns process replacement. Direct Docker stdio uses `docker exec -i`, or `docker compose exec -T` to disable Compose's pseudo-TTY while retaining stdin.

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

Reconnect through the client so it performs its supported MCP negotiation. Modern MCP 2026-07-28 clients use per-request metadata/discovery; legacy clients initialize first. Call `woods_status`, `search`, and `lookup`. For Console, inspect the registered list and call `console_status` only in the authorized environment.

Do not use an isolated raw JSON-RPC request as proof of MCP health. Do not claim conditional Index or inventory-only Console schemas are callable.

Canonical guide: [MCP_SERVERS.md](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md).
