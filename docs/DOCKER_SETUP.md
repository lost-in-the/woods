# Docker Setup Guide

This guide covers running Woods in a Dockerized Rails application, extraction, MCP server configuration, and troubleshooting.

## Architecture Overview

Woods extraction requires a booted Rails environment, so it runs inside the application container. The simplest MCP setup runs the Index Server from that same application bundle through Docker stdio. A host-side Index Server is an optional optimization when the host also has a compatible Ruby bundle and can read the published index.

```
HOST                                    APPLICATION CONTAINER
─────────────────────────────           ───────────────────────────
MCP client                              Rails App + Woods bundle
  docker compose exec -T ────────────▶    woods-mcp /app/tmp/woods
                                          32 schemas; 16 registered
                                          reads the published index

Extraction commands ─────────────────▶   bundle exec rake woods:extract
                                          writes /app/tmp/woods/
```

The Index Server reads static files and does not boot Rails, even when its process runs in the application container.
The Console MCP server was removed in Woods 2.2.0. See [CONSOLE_REMOVED.md](CONSOLE_REMOVED.md).

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

This creates `config/initializers/woods.rb` with default configuration, and nothing else.

### 3. Legacy application migration (opt-in)

Woods 2's shipped structural index and storage backends do not use the `woods_units`, `woods_edges`, and `woods_embeddings` application tables, so a default install writes no migration. Only an older/custom integration that deliberately uses those tables needs `rails generate woods:install --legacy-migration`, after normal schema-change review.

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

Use the application's actual Rails task entrypoint. If its root `Rakefile` wraps
Compose, the container may need `bundle exec rails woods:watch`. Keep the raw
task under one external restart owner: `restart: unless-stopped` recovers after
Docker restarts while respecting an intentional stop; `on-failure` covers failed
process exits but not Docker restart. Leave idle TTL unset for continuous work.

Validate `docker compose config`: explicit YAML anchor keys can replace inherited
mounts/environment, and short `depends_on` does not establish database readiness.
Preserve the existing source/bundle mounts and use the application's healthcheck
convention. With Grove, include the watcher in the applicable shared or isolated
services list and align source/index mounts to the selected worktree. Follow
[Docker and Grove verification](AUTOMATIC_MAINTENANCE.md#docker-verify-the-resolved-service)
instead of copying a generic service that loses required settings.

When host-side tasks or one-off containers read the daemon's shared index,
`WOODS_WATCH_TRUST_FOREIGN_HOST=1` lets those readers trust its recent heartbeat.
Set it in each reader process; Docker does not forward host variables by default.
Ordinary Index MCP reads do not need this trust or the extraction writer lock.
See [cross-host liveness](WATCH_DAEMON.md#cross-host-liveness) for the 15-minute
crash-detection bound and single-supervisor requirement.

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

### Index filesystem performance

Bind mounts backed by virtiofs or FUSE can make each hardlink, rename and
metadata lookup costly. Profile `payload seed`, writes and `payload prune`
before tuning extraction. A container volume can reduce these costs, but it
changes host visibility: use a distinct index location per worktree, run MCP
where that path is visible, and update export/archive paths together. A single
shared volume for every worktree would mix their indexes. See
[incremental profiling](INCREMENTAL_EXTRACTION.md#profiling-fixed-costs).

## Complete `.mcp.json` Example

An application uses one entry, the Index Server:

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

**Symptom:** The Index Server doesn't respond.

**Check:**
1. Container is running: `docker ps`
2. For Compose stdio, `-T` is present; for plain `docker exec`, `-i` is present
3. The server path is visible in its execution context: container path for Docker launch, host path for host launch

### Incorrect stdio flags

**Symptom:** The server starts but immediately exits, or MCP client reports "broken pipe."

**Fix:** Disable Compose's pseudo-TTY, or keep stdin open for plain Docker:

```text
Compose: "args": ["compose", "exec", "-T", "app", ...]
Docker:  "args": ["exec", "-i", "container-name", ...]
```

### Wrong container name

**Symptom:** `Error response from daemon: No such container: ...`

**Fix:** Check the actual name with `docker ps --format '{{.Names}}'` and update your `.mcp.json`.

### Path confusion between host and container

**Symptom:** Index Server reports "No manifest.json" even though extraction succeeded.

**Fix:** Match the path to the server process:

```
Container launch: /app/tmp/woods
Host launch:      /absolute/host/project/tmp/woods
```

### Source freshness is unknown on a host-launched server

**Symptom:** `woods_status` reports `index.source_freshness.state: "unknown"` with reason `source_root_unavailable`
and recommendation `map_source_root`.

**Cause:** Extraction ran in the container, so the index records the container root (`/app`).
A server on the host cannot find that directory.
It checks the application that owns the index directory in its place.
That fails when the index is mounted outside the application checkout, or when the application file does not match.

**Fix:** Launch the Index Server through the container, where `/app` exists.
Or keep the host launch and set `WOODS_SOURCE_ROOT` to the host path of the checkout:

```json
"env": { "WOODS_SOURCE_ROOT": "/absolute/host/path/to/app" }
```

Extracting again does not help: the next index records `/app` again.
See [source freshness](SOURCE_FRESHNESS.md#a-checkout-served-under-another-path).

### Woods MCP tools not available in a git worktree

A separate Claude Code session launched in a worktree may have different project-scoped MCP registrations. Subagents inherit the parent session's MCP tools, subject to tool restrictions; changing their working directory does not select a different Woods index. Check registration, the Compose service's mounted checkout, and the served index using [MCP worktree setup](MCP_WORKTREE_SETUP.md).
