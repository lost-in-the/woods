# Docker Setup Guide

This guide covers running CodebaseIndex in a Dockerized Rails application — extraction, MCP server configuration, and troubleshooting.

## Architecture Overview

CodebaseIndex has a split architecture: extraction requires a booted Rails environment (runs inside the container), but the two MCP servers have different runtime needs.

```
HOST                                    CONTAINER
─────────────────────────────           ──────────────────────
Index Server (27 tools)                 Rails App
  reads JSON from disk                    bundle exec rake codebase_index:extract
  no Rails needed                           writes to tmp/codebase_index/
        ▲                                         │
        └──── volume mount ◀──────────────────────┘

Console Server — two modes:

  Embedded (9 tools)                    rake codebase_index:console
  MCP client spawns via                   boots Rails, runs MCP in-process
  docker exec -i ────────────────────▶    Tier 1 read-only tools only

  Bridge (31 tools)
  codebase-console-mcp on host          bridge.rb inside container
  connects via docker exec -i ────────▶  evaluates queries in Rails console
  all 4 tiers                             rolled-back transactions
```

**Why the split?** The Index Server reads static JSON files — it doesn't need Rails, ActiveRecord, or any of your app's dependencies. Running it on the host avoids container overhead and makes the extraction output available to any MCP client. The Console Server queries live application state, so it must run inside (or connect to) the Rails environment.

## Installation

### 1. Add the gem

```ruby
# Gemfile
group :development do
  gem 'codebase_index'
end
```

```bash
docker compose exec app bundle install
```

### 2. Run the install generator

```bash
docker compose exec app bundle exec rails generate codebase_index:install
```

This creates `config/initializers/codebase_index.rb` with default configuration.

### 3. Run migrations

```bash
docker compose exec app bundle exec rails db:migrate
```

### 4. Configure

Edit `config/initializers/codebase_index.rb` inside the container (or on the host if the app directory is volume-mounted):

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
end
```

## Extraction

Run extraction inside the container:

```bash
# Full extraction
docker compose exec app bundle exec rake codebase_index:extract

# Incremental (changed files only)
docker compose exec app bundle exec rake codebase_index:incremental

# Framework/gem sources only
docker compose exec app bundle exec rake codebase_index:extract_framework
```

### Volume Mount Requirement

The extraction output must be accessible on the host for the Index Server to read it. Your `docker-compose.yml` should volume-mount the Rails app directory (or at least the output directory):

```yaml
services:
  app:
    volumes:
      - .:/app                    # Full app mount — output lands at ./tmp/codebase_index/
      # OR mount just the output:
      # - ./tmp/codebase_index:/app/tmp/codebase_index
```

### Verify Output on Host

After extraction, confirm the output is visible from the host:

```bash
ls tmp/codebase_index/manifest.json
```

If this file doesn't exist on the host, your volume mount isn't configured correctly.

### Path Translation

When configuring paths, use the **host path** for the Index Server and the **container path** for rake tasks:

| Context | Path | Example |
|---------|------|---------|
| Rake tasks (inside container) | Container path | `/app/tmp/codebase_index` |
| Index Server (on host) | Host path | `./tmp/codebase_index` or `/home/dev/my-app/tmp/codebase_index` |
| `.mcp.json` Index Server arg | Host path | Same as above |

## Index Server Setup

The Index Server runs on the host — it reads JSON files, not Rails. Point it at the volume-mounted extraction output using the **host path**.

### Start manually

```bash
codebase-index-mcp-start ./tmp/codebase_index
```

### `.mcp.json` configuration

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    }
  }
}
```

The `codebase-index-mcp-start` wrapper validates the index directory, checks for `manifest.json`, ensures dependencies are installed, and restarts on failure. Use it instead of `codebase-index-mcp` directly.

> **Common mistake:** Using the container path (`/app/tmp/codebase_index`) in `.mcp.json`. The Index Server runs on the host — it needs the host-side path to the volume-mounted output.

## Console Server Setup

The Console Server queries live Rails state. There are two modes with different trade-offs.

### Comparison

| | Embedded | Bridge |
|---|---|---|
| **Where it runs** | Inside container via `docker exec -i` | `codebase-console-mcp` on host, bridge inside container |
| **Config needed** | None (just `.mcp.json`) | `console.yml` + `.mcp.json` |
| **Tools available** | 9 (Tier 1 — read-only) | 31 (all 4 tiers) |
| **Setup complexity** | Minimal | Moderate |
| **Best for** | Quick setup, basic queries | Full diagnostics, analytics, guarded operations |

### Option 1: Embedded (9 Tier 1 tools)

The MCP client spawns `docker exec -i` directly. The container boots Rails and runs the MCP server in-process. Only Tier 1 read-only tools are available (count, sample, find, pluck, aggregate, association_count, schema, recent, status).

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": [
        "compose", "exec", "-i", "app",
        "bundle", "exec", "rake", "codebase_index:console"
      ]
    }
  }
}
```

> **The `-i` flag is required.** Without it, stdin is not attached and the MCP protocol cannot communicate with the server.

If you use `docker exec` (not `docker compose exec`), provide the exact container name:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": [
        "exec", "-i", "my_app_web_1",
        "bundle", "exec", "rake", "codebase_index:console"
      ]
    }
  }
}
```

### Option 2: Bridge (all 31 tools)

The `codebase-console-mcp` binary runs on the host and connects to a bridge process inside the container via `docker exec -i`. This enables all 4 tool tiers: read-only, domain-aware, analytics, and guarded operations.

**Step 1: Create `console.yml`**

```yaml
# ~/.codebase_index/console.yml
mode: docker
container: my_app_web_1
```

Find your container name with:

```bash
docker ps --format '{{.Names}}'
```

For Docker Compose, names follow the pattern `<project>-<service>-<number>` (e.g., `my_app-app-1`).

**Step 2: Configure `.mcp.json`**

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "codebase-console-mcp"
    }
  }
}
```

The bridge reads `~/.codebase_index/console.yml` by default. To use a different path:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "codebase-console-mcp",
      "env": {
        "CODEBASE_CONSOLE_CONFIG": "/path/to/console.yml"
      }
    }
  }
}
```

## Complete `.mcp.json` Example

Both servers configured together for a Docker environment:

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "codebase-console": {
      "command": "docker",
      "args": [
        "compose", "exec", "-i", "app",
        "bundle", "exec", "rake", "codebase_index:console"
      ]
    }
  }
}
```

This uses the embedded console (9 tools). To use the bridge (31 tools), replace the `codebase-console` entry:

```json
{
  "mcpServers": {
    "codebase-index": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "codebase-console": {
      "command": "codebase-console-mcp"
    }
  }
}
```

## Task Reference

Which tasks need Docker and which don't:

| Task | Needs Rails? | Run via |
|------|---|---|
| `codebase_index:extract` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:incremental` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:extract_framework` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:embed` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:embed_incremental` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:console` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:flow[EntryPoint]` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:notion_sync` | Yes | `docker compose exec app bundle exec rake ...` |
| `codebase_index:validate` | No | Host or container |
| `codebase_index:stats` | No | Host or container |
| `codebase_index:clean` | No | Host or container |

## Container Name Discovery

Docker Compose generates container names using the pattern `<project>-<service>-<number>`:

```bash
# List all running containers
docker ps --format '{{.Names}}'

# Filter for your app service
docker ps --format '{{.Names}}' | grep app
```

The project name defaults to the directory name of the `docker-compose.yml` file. Override it with `COMPOSE_PROJECT_NAME` or the `name:` key in `docker-compose.yml`.

## Troubleshooting

### Extraction output not visible on host

**Symptom:** `ls tmp/codebase_index/manifest.json` fails on the host after extraction.

**Fix:** Ensure your `docker-compose.yml` volume-mounts the app directory:

```yaml
volumes:
  - .:/app
```

Then re-run extraction.

### MCP client shows "connection refused" or no tools

**Symptom:** The Index or Console server doesn't respond.

**Check:**
1. Container is running: `docker ps`
2. For embedded console, the `-i` flag is present in the `args`
3. For the Index Server, the path in `.mcp.json` is the host path, not the container path

### Missing `-i` flag on `docker exec`

**Symptom:** Console server starts but immediately exits, or MCP client reports "broken pipe."

**Fix:** Add `-i` to keep stdin open:

```json
"args": ["compose", "exec", "-i", "app", ...]
```

### Wrong container name

**Symptom:** `Error response from daemon: No such container: ...`

**Fix:** Check the actual name with `docker ps --format '{{.Names}}'` and update your `.mcp.json` or `console.yml`.

### Path confusion between host and container

**Symptom:** Index Server reports "No manifest.json" even though extraction succeeded.

**Fix:** The Index Server runs on the host. Use the host-side path:

```
# Wrong (container path):
"args": ["/app/tmp/codebase_index"]

# Right (host path):
"args": ["./tmp/codebase_index"]
```

### Rails boot noise breaks MCP protocol

**Symptom:** MCP client shows JSON parse errors.

**Fix:** The `codebase_index:console` rake task redirects stdout to stderr before Rails boots. If you still see issues, check for `puts` or `print` calls in your initializers that run before the task captures stdout.

### Tier 2-4 tools return "unsupported in embedded mode"

**Expected behavior.** The embedded console (Option 1) only supports 9 Tier 1 tools. Switch to the bridge (Option 2) for the full 31 tools.

See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for detailed console server documentation.
