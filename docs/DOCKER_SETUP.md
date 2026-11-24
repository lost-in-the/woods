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

# Raw watcher task; run it under one owner, as described below
docker compose exec app bundle exec rake woods:watch

# Framework/gem sources only
docker compose exec app bundle exec rake woods:extract_framework
```

Run the watcher under one owner, not as a one-off terminal command.
If the container runs `bin/rails server`,
the Puma mode of the [watcher generator](WATCH_DAEMON.md#managed-development-startup) works inside it.
Puma in the container then starts the watcher, and no separate service is needed.
Otherwise run it as its own development service or process-manager entry.

Docker Desktop bind mounts may not deliver reliable native filesystem events, so the watcher polls by default
inside a container (it looks for `/.dockerenv` or `/run/.containerenv`) and whenever the `listen` gem is absent.
Its startup line in the Rails log names the choice:
`[Woods] watch: polling every 1.0s` or `[Woods] watch: using native FS events (listen)`.
Set `WOODS_WATCH_POLL=1` when it chose native events and edits made on the host do not reach it.
The watcher updates structural generations automatically.
Semantic vectors still require `woods:embed_incremental`.

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

The server process needs no Ruby, Bundler, Woods executable, or host-visible index on the host.
From Woods `2.2.0`, Claude Code users write it with the managed setup, where the host can run the application bundle
and reach Docker Compose:

```bash
bundle exec woods-agent-config setup --client claude --scope project --root "$PWD" \
  --mode compose --service app --container-root /app --plan "$woods_plan_dir/setup.json" --diff
bundle exec woods-agent-config apply "$woods_plan_dir/setup.json" --client claude --scope project --root "$PWD"
```

When Woods is installed only in the container, the install generator prints the same entry:
`docker compose exec app bundle exec rails generate woods:install --mcp-service app`
(add `--mcp-config` to write `.mcp.json`, and `--skip` in an application installed earlier, so an edited
initializer is kept).
Either way the entry names no absolute path, so one committed `.mcp.json` works in every checkout and on every
machine. See [managed configuration](AGENT_SETUP.md#managed-claude-code-configuration) and its entry forms:

```json
{
  "mcpServers": {
    "woods": {
      "type": "stdio",
      "command": "sh",
      "args": ["-c", "if [ -n \"$CLAUDE_PROJECT_DIR\" ]; then cd \"$CLAUDE_PROJECT_DIR\" || exit 1; fi; exec docker compose exec -T -e WOODS_MCP_CLIENT_ROOT_MAP=\"$WOODS_MCP_CLIENT_ROOT_MAP\" app bundle exec woods-mcp-start --checkout --await-index --client-root \"$PWD\""]
    }
  }
}
```

- `sh -c` turns `$PWD` into the session's directory, handed to the server as the client root.
  The server refuses an index that belongs to another checkout instead of answering from it.
- A host path does not exist inside the container, so without a mount map every launch starts with one warning
  that the client's checkout cannot be determined.
  Each developer can export their own map, for example `WOODS_MCP_CLIENT_ROOT_MAP=/host/src=/app`;
  the entry passes it through and stays free of host paths.
  See [the Docker process and path rule](MCP_SERVERS.md#docker-process-and-path-rule).
- Compose finds the project from the session's directory and names it after that directory.
  A session in a linked worktree reaches the running service only when the project name is pinned,
  with a top-level `name:` in the Compose file or `COMPOSE_PROJECT_NAME`.
- `--checkout` needs the checkout's `.git` entry inside the container.
  A service that mounts only the application directory has none, and the launch is refused.
- The entry passes no `-w`, so the server starts in the service's `working_dir`.
  That must be the application root inside the container, in a mount of the whole checkout.
  For an application below its checkout root, it is the application directory (for example `/app/apps/web` with
  the checkout at `/app`), not the checkout root: Bundler looks for the Gemfile up from there, never down.
  `woods-agent-config setup` runs its preflight the same way, and refuses a service whose working directory is not
  the `--container-root` application, or where Bundler resolves another application, naming both directories.
  The generator only prints the entry and does not check the service.

**A `BUNDLE_BIN` directory on the image's `PATH`.**
With `BUNDLE_BIN` set, `bundle install` writes a binstub for every executable, `bundle` itself included.
Each binstub fixes the Gemfile at its install-time path (`ENV["BUNDLE_GEMFILE"] ||= ...`).
With that directory first on `PATH`, `bundle exec` uses that one Gemfile from any working directory.
The setup preflight compares the service's working directory itself, so a wrong `working_dir` is still refused.
A bundle volume installed for another application path makes every `bundle exec` fail with
`Bundler::GemfileNotFound`, naming the install-time Gemfile path.
Either remedy works: remove the `BUNDLE_BIN` directory from `PATH` in the service's environment,
or use one bundle volume per application layout.

The generated entry was run with a stand-in `docker` that runs the inner command in place, or in a given service
working directory (`spec/integration/generated_mcp_entry_spec.rb`).
A real `docker compose exec` with this entry was not run.

Before Woods `2.2.0`, or without the checkout's `.git` in the container, name the host application root.
Compose must be able to resolve the project, so set `cwd` to the host application root.
`-T` disables Compose's pseudo-TTY while keeping stdin attached for MCP:

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

`woods-mcp-start` also works in these commands in place of `woods-mcp`.
It checks the index path and its published generation first, then starts `woods-mcp`.

Two persistence gotchas:

1. **tmpfs wipes the index on container restart.** If `/app/tmp` is tmpfs, re-run `rake woods:extract` after each restart, or persist the index by mounting a named volume at the index path (e.g. `- woods-data:/app/tmp/woods`) or writing the index outside the tmpfs mount.
2. **Use the container path.** With an explicit index path, the Docker-launched server needs `/app/tmp/woods`,
   not the host's `./tmp/woods`. `--checkout` takes no path.

### Optional: run the Index Server on the host

Use this only when the application bundle, a supported Ruby, and the Woods executable are installed on the host
**and** the index directory is host-visible.
From Woods `2.2.0`, `woods-agent-config setup --scope project` (host mode) writes the path-free form, and
`rails generate woods:install` prints it (`--mcp-config` writes it):

```json
{
  "mcpServers": {
    "woods": {
      "type": "stdio",
      "command": "sh",
      "args": ["-c", "if [ -n \"$CLAUDE_PROJECT_DIR\" ]; then cd \"$CLAUDE_PROJECT_DIR\" || exit 1; fi; exec bundle exec woods-mcp-start --checkout --await-index"]
    }
  }
}
```

Before Woods `2.2.0`, name the host application root (machine-specific; do not commit it):

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
| **Path in `.mcp.json`** | None from Woods `2.2.0` (`--checkout`); before that, the container path (`/app/tmp/woods`) | None from Woods `2.2.0`; before that, the host path (`./tmp/woods`) and an absolute `cwd` |
| **Needs `sh` where the client runs** | Yes, for the path-free form | Yes, for the path-free form |
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

An application uses one entry, the Index Server.
It is the path-free form from Woods `2.2.0` (before that, use the container form with `cwd` above):

```json
{
  "mcpServers": {
    "woods": {
      "type": "stdio",
      "command": "sh",
      "args": ["-c", "if [ -n \"$CLAUDE_PROJECT_DIR\" ]; then cd \"$CLAUDE_PROJECT_DIR\" || exit 1; fi; exec docker compose exec -T -e WOODS_MCP_CLIENT_ROOT_MAP=\"$WOODS_MCP_CLIENT_ROOT_MAP\" app bundle exec woods-mcp-start --checkout --await-index --client-root \"$PWD\""]
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

**Symptom:** The Index Server exits 1 with `Index directory does not exist: <path>` even though extraction succeeded.
Woods 1.x reported this as "No manifest.json".

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
