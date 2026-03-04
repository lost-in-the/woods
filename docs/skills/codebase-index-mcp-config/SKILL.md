---
name: codebase-index-mcp-config
description: Generate correct .mcp.json configuration for CodebaseIndex in any environment
---

# CodebaseIndex MCP Configuration

Use this guide to produce a correct `.mcp.json` for your environment. Answer the environment detection questions first, then use the matching template.

---

## Environment Detection

**1. Is the Rails app running in Docker?**
- Yes → use the Docker templates below
- No → use the Local Development template

**2. Which AI tool?**
- Claude Code → put `.mcp.json` in your Rails app root (or `~/.claude/claude_desktop_config.json` for global)
- Cursor → `.cursor/mcp.json`
- Windsurf → `.windsurf/mcp.json`

All three tools use the same JSON format.

**3. Do you need Tier 2–4 console tools?** (diagnostics, SQL, Ruby eval, job control)
- No → use the Embedded Console template (simpler, works with rake or docker exec)
- Yes → use the Bridge Console template (requires Option D setup from CONSOLE_MCP_SETUP.md)

---

## Templates

### Local Development (no Docker)

The Index Server runs as a host process reading local files. The Console Server boots Rails in-process via the rake task.

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "codebase_index:console"],
      "cwd": "/absolute/path/to/your/rails-app"
    }
  }
}
```

`codebase-index-mcp-start` is a self-healing wrapper that validates `manifest.json` before starting and auto-installs missing dependencies. Use it instead of `codebase-index-mcp` for local development.

`cwd` must be an **absolute path** to the Rails app root (where `Rakefile` lives). Relative paths are not supported for `cwd`.

---

### Docker — Embedded Console (Tier 1 tools only)

The Index Server reads volume-mounted output on the host. The Console Server runs inside the container via `docker exec -i`.

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "your_app_web_1",
        "bundle", "exec", "rake", "codebase_index:console"
      ]
    }
  }
}
```

The `-i` flag is required — it keeps stdin open for the MCP protocol. Without it, the container rejects input immediately.

Find your container name with:

```bash
docker ps --format '{{.Names}}'
```

Docker Compose generates names like `<project>-<service>-<index>` (e.g., `myapp-web-1`). The name in your MCP config must match exactly.

---

### Docker — Bridge Console (all 31 tools)

For Tier 2–4 tools, use the bridge architecture. The `codebase-console-mcp` binary runs on the host and communicates with the container via JSON-lines over stdio.

First, create `~/.codebase_index/console.yml`:

```yaml
connection:
  mode: docker
  service: web
  compose_file: /absolute/path/to/docker-compose.yml
```

Then configure the MCP client:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "command": "codebase-console-mcp",
      "env": {
        "CODEBASE_CONSOLE_CONFIG": "/Users/yourname/.codebase_index/console.yml"
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
        "bundle", "exec", "rake", "codebase_index:console"
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
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "type": "streamable-http",
      "url": "http://localhost:3000/mcp/console"
    }
  }
}
```

Requires `config.console_mcp_enabled = true` in your initializer. See [CONSOLE_MCP_SETUP.md](../../CONSOLE_MCP_SETUP.md) Option C for full setup.

---

### SSH Remote Bridge

For Rails apps running on a remote server or in a staging environment:

```yaml
# ~/.codebase_index/console.yml
connection:
  mode: ssh
  host: app.example.com
  user: deploy
  command: cd /app && bundle exec rails runner -
```

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["/local/path/to/extracted/tmp/codebase_index"]
    },
    "rails-console": {
      "command": "codebase-console-mcp",
      "env": {
        "CODEBASE_CONSOLE_CONFIG": "/Users/yourname/.codebase_index/console.yml"
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
# Wrong — points to Rails root
"args": ["/path/to/your/rails-app"]

# Correct — points to extraction output
"args": ["/path/to/your/rails-app/tmp/codebase_index"]
```

**Container path instead of host path**

The Index Server runs on the host and cannot access container paths:

```
# Wrong — container-internal path
"args": ["/app/tmp/codebase_index"]

# Correct — host path to volume-mounted output
"args": ["./tmp/codebase_index"]
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
