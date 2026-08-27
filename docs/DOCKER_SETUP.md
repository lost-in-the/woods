# Docker Setup Guide

This guide covers running Woods in a Dockerized Rails application, extraction, MCP server configuration, and troubleshooting.

## Architecture Overview

Woods has a split architecture: extraction requires a booted Rails environment (runs inside the container), but the two MCP servers have different runtime needs.

```
HOST                                    CONTAINER
─────────────────────────────           ──────────────────────
Index Server (29 tools)                 Rails App
  reads JSON from disk                    bundle exec rake woods:extract
  no Rails needed                           writes to tmp/woods/
        ▲                                         │
        └──── volume mount ◀──────────────────────┘

Console Server, two launch paths:

  Embedded (9 tools)                    rake woods:console
  MCP client spawns via                   boots Rails, runs MCP in-process
  docker exec -i ────────────────────▶    Tier 1 read-only tools only

  Configured launcher (same tools)
  woods-console-mcp on host          rake woods:console
  execs docker exec -i ──────────────▶  same embedded server
```

**Why the split?** The Index Server reads static JSON files, it doesn't need Rails, ActiveRecord, or any of your app's dependencies. Running it on the host avoids container overhead and makes the extraction output available to any MCP client. The Console Server queries live application state, so it must run inside (or connect to) the Rails environment.

## Installation

### 1. Add the gem

```ruby
# Gemfile
group :development do
  gem 'woods'
end
```

```bash
docker compose exec app bundle install
```

### 2. Run the install generator

```bash
docker compose exec app bundle exec rails generate woods:install
```

This creates `config/initializers/woods.rb` with default configuration.

### 3. Run migrations

```bash
docker compose exec app bundle exec rails db:migrate
```

### 4. Configure

Edit `config/initializers/woods.rb` inside the container (or on the host if the app directory is volume-mounted):

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
end
```

## Extraction

Run extraction inside the container:

```bash
# Full extraction
docker compose exec app bundle exec rake woods:extract

# Incremental (changed files only)
docker compose exec app bundle exec rake woods:incremental

# Framework/gem sources only
docker compose exec app bundle exec rake woods:extract_framework
```

### Volume Mount Requirement

The extraction output must be accessible on the host for the Index Server to read it. Your `docker-compose.yml` should volume-mount the Rails app directory (or at least the output directory):

```yaml
services:
  app:
    volumes:
      - .:/app                    # Full app mount, output lands at ./tmp/woods/
      # OR mount just the output:
      # - ./tmp/woods:/app/tmp/woods
```

### Verify Output on Host

After extraction, confirm the output is visible from the host:

```bash
ls tmp/woods/manifest.json
```

If this file doesn't exist on the host, your volume mount isn't configured correctly.

### Path Translation

When configuring paths, use the **host path** for the Index Server and the **container path** for rake tasks:

| Context | Path | Example |
|---------|------|---------|
| Rake tasks (inside container) | Container path | `/app/tmp/woods` |
| Index Server (on host) | Host path | `./tmp/woods` or `/home/dev/my-app/tmp/woods` |
| `.mcp.json` Index Server arg | Host path | Same as above |

## Index Server Setup

The Index Server runs on the host, it reads JSON files, not Rails. Point it at the volume-mounted extraction output using the **host path**.

### Start manually

```bash
woods-mcp-start ./tmp/woods
```

### `.mcp.json` configuration

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

The `woods-mcp-start` wrapper validates the index directory, checks for `manifest.json`, ensures dependencies are installed, and restarts on failure. Use it instead of `woods-mcp` directly.

> **Common mistake:** Using the container path (`/app/tmp/woods`) in `.mcp.json`. The host-side Index Server needs the host-side path to the volume-mounted output. (The in-container variant below is the opposite, it takes the container path.)

### In-container Index Server (tmpfs / non-host-visible indexes)

The host-side setup above assumes the extraction output is readable from the host. That breaks when `/app/tmp` is mounted as **tmpfs** for speed, or when the index directory lives in a **named Docker volume**: in both cases the index is not host-visible, so the host cannot run `woods-mcp-start ./tmp/woods`.

The alternative is to run the Index Server **inside the container** via `docker exec`, pointing at the **container path**:

```json
{
  "mcpServers": {
    "woods": {
      "command": "docker",
      "args": ["exec", "-i", "my_app_web_1", "bundle", "exec", "woods-mcp", "/app/tmp/woods"]
    }
  }
}
```

(With Compose, `"args": ["compose", "exec", "-i", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"]` works the same way. The `-i` flag is required, exactly as for the embedded Console Server.)

This form is also **cwd-independent**: there is no relative launcher path to resolve, which matters when the same server entry is referenced from multiple project roots or git worktrees.

Two gotchas:

1. **tmpfs wipes the index on container restart.** If `/app/tmp` is tmpfs, re-run `rake woods:extract` after each restart, or persist the index by mounting a named volume at the index path (e.g. `- woods-data:/app/tmp/woods`) or writing the index outside the tmpfs mount.
2. **Container path, not host path.** This is the mirror image of the host-side "common mistake" above: the in-container server needs `/app/tmp/woods` (the container path), while the host-side server needs the host path. Pick the path that matches where the server process actually runs.

| | Host-side (`woods-mcp-start`) | In-container (`docker exec`) |
|---|---|---|
| **Index location** | Host-visible volume mount | Anywhere in the container (tmpfs, named volume) |
| **Path in `.mcp.json`** | Host path (`./tmp/woods`) | Container path (`/app/tmp/woods`) |
| **Survives container restart** | Yes (on host disk) | Only with a named volume |
| **Needs Ruby on host** | Yes | No |

## Console Server Setup

The Console Server queries live Rails state. There are two launch paths for the same embedded server.

### Comparison

| | Direct Docker command | Configured launcher |
|---|---|---|
| **Where it runs** | Inside container via `docker exec -i` | `woods-console-mcp` execs `docker exec -i` |
| **Config needed** | None (just `.mcp.json`) | `console.yml` + `.mcp.json` |
| **Tools available** | 9 by default; 11 with read tools enabled | Same 9 or 11 |
| **Setup complexity** | Minimal | Moderate |
| **Best for** | Quick setup | Reusable launcher config |

### Option 1: Embedded (9 Tier 1 tools)

The MCP client spawns `docker exec -i` directly. The container boots Rails and runs the MCP server in-process. Only Tier 1 read-only tools are available (count, sample, find, pluck, aggregate, association_count, schema, recent, status).

```json
{
  "mcpServers": {
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

> **The `-i` flag is required.** Without it, stdin is not attached and the MCP protocol cannot communicate with the server.

If you use `docker exec` (not `docker compose exec`), provide the exact container name:

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "docker",
      "args": [
        "exec", "-i", "my_app_web_1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

### Option 2: Configured launcher

The `woods-console-mcp` binary runs on the host and replaces itself with
`docker exec -i ... bundle exec rake woods:console`. It exposes the same
embedded tool surface as Option 1.

**Step 1: Create `console.yml`**

```yaml
# ~/.woods/console.yml
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
    "woods-console": {
      "command": "woods-console-mcp"
    }
  }
}
```

The launcher reads `~/.woods/console.yml` by default. To use a different path:

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "woods-console-mcp",
      "env": {
        "WOODS_CONSOLE_CONFIG": "/path/to/console.yml"
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

This uses the embedded console directly. To use the equivalent configured
launcher, replace the `woods-console` entry:

```json
{
  "mcpServers": {
    "woods": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "woods-console": {
      "command": "woods-console-mcp"
    }
  }
}
```

## Task Reference

Which tasks need Docker and which don't:

| Task | Needs Rails? | Run via |
|------|---|---|
| `woods:extract` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:incremental` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:extract_framework` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:embed` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:embed_incremental` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:console` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:flow[EntryPoint]` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:notion_sync` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:validate` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:stats` | Yes | `docker compose exec app bundle exec rake ...` |
| `woods:clean` | Yes | `docker compose exec app bundle exec rake ...` |

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

**Symptom:** `ls tmp/woods/manifest.json` fails on the host after extraction.

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

```text
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
"args": ["/app/tmp/woods"]

# Right (host path):
"args": ["./tmp/woods"]
```

### Rails boot noise breaks MCP protocol

**Symptom:** MCP client shows JSON parse errors.

**Fix:** The `woods:console` rake task redirects stdout to stderr before Rails boots. If you still see issues, check for `puts` or `print` calls in your initializers that run before the task captures stdout.

### A tool from the 31-schema inventory is not listed

**Expected behavior.** Supported servers register 9 Tier 1 tools by default.
Tier 2, Tier 3, and `console_eval` are inventory only.

To register `console_sql` and `console_query`, enable
`console_embedded_read_tools` in Woods configuration or pass
`embedded_read_tools: true` to the Rack middleware. See
[CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for details.

### Woods MCP tools not available in a git worktree

When working in a git worktree, subagents may not find the woods MCP servers because `.mcp.json` discovery is path-based and the worktree has a different root directory. See [MCP_WORKTREE_SETUP.md](MCP_WORKTREE_SETUP.md) for the fix and verification steps.

See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) for detailed console server documentation.
