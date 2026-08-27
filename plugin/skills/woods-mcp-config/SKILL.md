---
name: woods-mcp-config
description: Generate correct .mcp.json configuration for Woods in any environment
---

# Woods MCP Configuration

Use this guide to produce a correct `.mcp.json` for your environment. Answer the environment detection questions first, then use the matching template.

---

## Version Preflight

Confirm the installed Woods version before generating config. The available MCP executables
and tool tiers depend on it:

```bash
bundle info woods        # installed version + path
```

This guide targets **Woods 2.0.0 or later**.

- Older gem: some commands, tools, or config keys below will not exist. Tell the user to run `bundle update woods` first.
- Newer release on RubyGems: mention it so the user can pick it up.

---

## Environment Detection

**1. Is the Rails app running in Docker?**
- Yes → use the Docker templates below
- No → use the Local Development template

**2. Which AI tool?**
- Claude Code → put `.mcp.json` in your Rails app root (or `claude mcp add --scope user` for a global entry in `~/.claude.json`)
- Cursor → `.cursor/mcp.json`
- Windsurf → `.windsurf/mcp.json`

All three tools use the same JSON format.

**3. Do you need `console_sql` / `console_query` (raw SQL / structured queries)?**
- No → use the Embedded Console template as-is (9 tools)
- Yes → same template, plus `config.console_embedded_read_tools = true` in your initializer (11 tools)

There is no config, transport, or launcher setting that registers Tier 2, Tier 3, or `console_eval`. Those 22 tool schemas are inventory-only in every supported mode. Don't offer a "bridge" template for them; it doesn't exist.

---

## Templates

### Local Development (no Docker)

The Index Server runs as a host process reading local files. The Console Server boots Rails in-process via the rake task.

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
      "cwd": "/absolute/path/to/your/rails-app"
    }
  }
}
```

`woods-mcp-start` is a wrapper that checks the index directory and its manifest (following the `generation.json` pointer) before it execs `woods-mcp`, so a missing extraction fails with a clear message instead of a protocol error. Use it instead of `woods-mcp` for local development.

`cwd` must be an **absolute path** to the Rails app root (where `Rakefile` lives). Relative paths are not supported for `cwd`.

---

### Docker: Embedded Console (Tier 1 tools only)

The Index Server reads volume-mounted output on the host. The Console Server runs inside the container via `docker exec -i`.

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "your_app_web_1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

The `-i` flag is required: it keeps stdin open for the MCP protocol. Without it, the container rejects input immediately.

Find your container name with:

```bash
docker ps --format '{{.Names}}'
```

Docker Compose generates names like `<project>-<service>-<index>` (e.g., `myapp-web-1`). The name in your MCP config must match exactly.

---

### Docker: Launcher Wrapper (same 9/11 tools, centralized config)

`woods-console-mcp` is a process launcher, not a different server. It execs
the identical embedded server used by the templates above, just via a YAML
file instead of MCP-client-specific args. It does not add tool tiers; there
is no JSON-lines bridge in the shipped gem (`Server.build(config:)` always
raises `Woods::ConfigurationError` pointing here). Use this when you want one
`console.yml` to work across multiple MCP clients instead of duplicating the
`docker exec` args in each client's config.

First, create `~/.woods/console.yml`. Keys are flat (`mode`, `container`,
`command`), not nested under a `connection:` key, and there is no `service:`
or `compose_file:` key (the launcher execs `docker exec` against a container
name, not `docker compose`):

```yaml
mode: docker
container: your_app_web_1
command: bundle exec rake woods:console
```

Then configure the MCP client:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "command": "woods-console-mcp",
      "env": {
        "WOODS_CONSOLE_CONFIG": "/Users/yourname/.woods/console.yml"
      }
    }
  }
}
```

---

### Docker Compose (`docker compose exec`)

If you use `docker compose` (v2), use this form instead of `docker exec`:

```json
{
  "mcpServers": {
    "rails-console": {
      "command": "docker",
      "args": [
        "compose", "-f", "/absolute/path/to/docker-compose.yml",
        "exec", "-i", "web",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

Note: `-f` with an absolute path bypasses Docker Compose override files. If your project uses `docker-compose.override.yml`, `cd` to the project directory and use the compose default instead, or run via a wrapper script.

---

### HTTP Transport (shared access)

When the Console Server runs as a Rack middleware endpoint instead of a subprocess:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "type": "streamable-http",
      "url": "http://localhost:3000/mcp/console",
      "headers": {
        "Authorization": "Bearer <same WOODS_CONSOLE_MCP_TOKEN value>"
      }
    }
  }
}
```

Requires `config.console_mcp_enabled = true` and `config.console_mcp_token` set in your initializer. Every request must carry the matching bearer token or the middleware returns `401`. See [CONSOLE_MCP_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md) Option C for full setup.

---

### SSH Launcher

For Rails apps running on a remote server or in a staging environment. Same
flat-key `console.yml` shape as the Docker launcher above:

```yaml
# ~/.woods/console.yml
mode: ssh
host: app.example.com
user: deploy
command: cd /app && bundle exec rake woods:console
```

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["/local/path/to/extracted/tmp/woods"]
    },
    "rails-console": {
      "command": "woods-console-mcp",
      "env": {
        "WOODS_CONSOLE_CONFIG": "/Users/yourname/.woods/console.yml"
      }
    }
  }
}
```

The Index Server always reads local files. For SSH setups, copy the extraction output locally with `rsync` or mount it via SSHFS.

---

## Common Mistakes

**Wrong path for the Index Server**

The Index Server takes a path to the extraction output directory, not the Rails root:

```
# Wrong: points to Rails root
"args": ["/path/to/your/rails-app"]

# Correct: points to extraction output
"args": ["/path/to/your/rails-app/tmp/woods"]
```

**Container path instead of host path**

The Index Server runs on the host and cannot access container paths:

```
# Wrong: container-internal path
"args": ["/app/tmp/woods"]

# Correct: host path to volume-mounted output
"args": ["./tmp/woods"]
```

**Missing `-i` flag for docker exec**

Without `-i`, Docker closes stdin immediately and the MCP protocol breaks:

```
# Wrong
"args": ["exec", "your_app_web_1", "bundle", "exec", "rake", ...]

# Correct
"args": ["exec", "-i", "your_app_web_1", "bundle", "exec", "rake", ...]
```

**Relative `cwd` path**

The `cwd` field in MCP config requires an absolute path on most clients:

```
# Wrong
"cwd": "./my-rails-app"

# Correct
"cwd": "/Users/yourname/work/my-rails-app"
```

**Container name mismatch**

Docker Compose container names include the project name and replica index. Check with `docker ps --format '{{.Names}}'` and copy the exact name shown.
