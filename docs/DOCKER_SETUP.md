# Docker Setup Guide

This guide covers running Woods in a Dockerized Rails application, extraction, MCP server configuration, and troubleshooting.

## Architecture Overview

Woods extraction requires a booted Rails environment, so it runs inside the application container. The simplest MCP setup runs the Index Server from that same application bundle through Docker stdio. A host-side Index Server is an optional optimization when the host also has a compatible Ruby bundle and can read the published index.

```
HOST                                    APPLICATION CONTAINER
─────────────────────────────           ───────────────────────────
MCP client                              Rails App + Woods bundle
  docker compose exec -T ────────────▶    woods-mcp /app/tmp/woods
                                          29 schemas; 14 registered
                                          reads the published index

Extraction commands ─────────────────▶   bundle exec rake woods:extract
                                          writes /app/tmp/woods/

Console Server, two launch paths:

  Embedded (9 tools)                    rake woods:console
  MCP client spawns via                   boots Rails, runs MCP in-process
  docker compose exec -T ────────────▶    Tier 1 read-only tools only

  Configured launcher (same tools)
  woods-console-mcp on host          rake woods:console
  execs docker exec -i ──────────────▶  same embedded server
```

The Index Server reads static files and does not boot Rails, even when its process runs in the application container. The Console Server queries live application state and does boot Rails. Treat Console access as a separate security decision.

## Installation

### 1. Add the gem

```ruby
# Gemfile
group :development do
  gem 'woods', '~> 2.0'
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

### 3. Decide whether to keep the legacy application migration

The generator emits `db/migrate/*_create_woods_tables.rb`, but Woods 2's shipped structural index and storage backends do not use those application tables. For a new default installation, remove that generated migration before the next Rails boot. Keep and run it only when deliberately preserving an older/custom integration that uses `woods_units`, `woods_edges`, and `woods_embeddings`, after normal schema-change review.

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

# Automatic structural updates while the container is running
docker compose exec app bundle exec rake woods:watch

# Framework/gem sources only
docker compose exec app bundle exec rake woods:extract_framework
```

Run the watcher as its own development service or process-manager entry, not as a one-off terminal command. Docker Desktop bind mounts may not deliver reliable native filesystem events; set `WOODS_WATCH_POLL=1` for polling when needed. The watcher updates structural generations automatically, while semantic vectors still require `woods:embed_incremental`.

### Index persistence

Persist `tmp/woods/` if the index should survive container replacement. A bind mount also makes it available to optional host-side tools:

```yaml
services:
  app:
    volumes:
      - .:/app                    # Full app mount, output lands at ./tmp/woods/
      # OR mount just the output:
      # - ./tmp/woods:/app/tmp/woods
```

### Verify the published index

Use Woods' generation-aware checks inside the same environment that performed extraction:

```bash
docker compose exec app bundle exec rake woods:validate
docker compose exec app bundle exec rake woods:stats
```

Woods 2 publishes `generation.json`, which points at the active payload manifest. A root-level `manifest.json` is valid only for a legacy layout; do not use its presence as the v2 health check.

### Path Translation

Use the path visible to the process that actually runs the command:

| Context | Path | Example |
|---------|------|---------|
| Rake tasks (inside container) | Container path | `/app/tmp/woods` |
| Index Server through Docker | Container path | `/app/tmp/woods` |
| Optional host-side Index Server | Host path | `./tmp/woods` or `/home/dev/my-app/tmp/woods` |

## Index Server setup

### Default: run it through the application container

This path needs no Ruby, Bundler, Woods executable, or host-visible index on the host. Compose must be able to resolve the project, so set `cwd` to the host application root. `-T` disables Compose's pseudo-TTY while keeping stdin attached for MCP:

```json
{
  "mcpServers": {
    "woods": {
      "command": "docker",
      "args": [
        "compose", "exec", "-T", "app",
        "bundle", "exec", "woods-mcp", "/app/tmp/woods"
      ],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

Replace `app` and `/app` with the Compose service and container path used by the project. The service must already be running. For plain Docker, use the exact container name and interactive stdin:

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

Two persistence gotchas:

1. **tmpfs wipes the index on container restart.** If `/app/tmp` is tmpfs, re-run `rake woods:extract` after each restart, or persist the index by mounting a named volume at the index path (e.g. `- woods-data:/app/tmp/woods`) or writing the index outside the tmpfs mount.
2. **Use the container path.** The Docker-launched server needs `/app/tmp/woods`, not the host's `./tmp/woods`.

### Optional: run the Index Server on the host

Use this only when the application bundle, a supported Ruby, and the Woods executable are installed on the host **and** the index directory is host-visible:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

`woods-mcp-start` validates the directory and active published generation, then replaces itself with `woods-mcp`. It does not install dependencies or restart a failed process.

| | Container process (default) | Host process (optional) |
|---|---|---|
| **Index location** | Anywhere in the container | Host-visible bind mount |
| **Path in `.mcp.json`** | Container path (`/app/tmp/woods`) | Host path (`./tmp/woods`) |
| **Survives container replacement** | Only with a bind/named volume | Yes, on host disk |
| **Needs Ruby/Woods bundle on host** | No | Yes |

## Console Server Setup

The Console Server queries live Rails state. There are two launch paths for the same embedded server.

Before either path can start, deliberately enable live-data access in the Rails initializer:

```ruby
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_mcp_token = ENV["WOODS_CONSOLE_MCP_TOKEN"]
end
```

The process exits with status 1 while this master switch is false. Review [Console MCP setup and security](CONSOLE_MCP_SETUP.md) before enabling it.

Stdio does not send the bearer token, but production Rails boot still requires `WOODS_CONSOLE_MCP_TOKEN` to contain at least 32 characters whenever Console is enabled. Provide it to the container through the application's normal secret mechanism. Outside production, omitting it warns and leaves the Console HTTP endpoint guarded with 401.

### Comparison

| | Direct Docker command | Configured launcher |
|---|---|---|
| **Where it runs** | Inside container via Docker stdio | `woods-console-mcp` execs `docker exec -i` |
| **Config needed** | Rails master switch + `.mcp.json` | Rails master switch + `console.yml` + `.mcp.json` |
| **Tools available** | 9 by default; 11 with read tools enabled | Same 9 or 11 |
| **Setup complexity** | Minimal | Moderate |
| **Best for** | Quick setup | Reusable launcher config |

### Option 1: Embedded (9 Tier 1 tools)

The MCP client spawns a Docker stdio process directly. The container boots Rails and runs the MCP server in-process. Only Tier 1 read-only tools are available (count, sample, find, pluck, aggregate, association_count, schema, recent, status).

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "docker",
      "args": [
        "compose", "exec", "-T", "app",
        "bundle", "exec", "rake", "woods:console"
      ],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

> **Compose uses `-T`; plain Docker uses `-i`.** Compose attaches stdin by default, and `-T` prevents a pseudo-TTY from corrupting MCP framing. Plain `docker exec` needs `-i` to keep stdin attached.

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

This optional path requires Woods and the `woods-console-mcp` executable on
the host. If Woods is installed only in the application container, use the
direct Docker command in Option 1. If the host executable comes from the
application bundle, configure the client with `bundle exec` and an absolute
host `cwd`, as shown in the [launcher guide](CONSOLE_MCP_SETUP.md#option-d-launcher-wrapper).

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

Both servers configured together for a Docker environment, after `config.console_mcp_enabled = true` has been deliberately set:

```json
{
  "mcpServers": {
    "woods": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
    },
    "woods-console": {
      "command": "docker",
      "args": [
        "compose", "exec", "-T", "app",
        "bundle", "exec", "rake", "woods:console"
      ],
      "cwd": "/absolute/host/path/to/app"
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
      "command": "docker",
      "args": ["compose", "exec", "-T", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
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
| `woods:watch` | Yes | Dedicated container/process-manager entry |
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

### Extraction output is not persisted

**Symptom:** The index disappears when the application container is replaced.

**Fix:** Volume-mount the app directory or the Woods output directory:

```yaml
volumes:
  - .:/app
```

Then re-run extraction and verify it inside the container with `woods:validate` and `woods:stats`.

### MCP client shows "connection refused" or no tools

**Symptom:** The Index or Console server doesn't respond.

**Check:**
1. Container is running: `docker ps`
2. For Compose stdio, `-T` is present; for plain `docker exec`, `-i` is present
3. The server path is visible in its execution context: container path for Docker launch, host path for host launch

### Incorrect stdio flags

**Symptom:** Console server starts but immediately exits, or MCP client reports "broken pipe."

**Fix:** Disable Compose's pseudo-TTY, or keep stdin open for plain Docker:

```text
Compose: "args": ["compose", "exec", "-T", "app", ...]
Docker:  "args": ["exec", "-i", "container-name", ...]
```

### Wrong container name

**Symptom:** `Error response from daemon: No such container: ...`

**Fix:** Check the actual name with `docker ps --format '{{.Names}}'` and update your `.mcp.json` or `console.yml`.

### Path confusion between host and container

**Symptom:** Index Server reports "No manifest.json" even though extraction succeeded.

**Fix:** Match the path to the server process:

```
Container launch: /app/tmp/woods
Host launch:      /absolute/host/project/tmp/woods
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
