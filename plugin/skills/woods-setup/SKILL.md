---
name: woods-setup
description: Use when installing or performing first-run configuration of Woods in a Rails application.
---

# Woods setup

Install a structural Index Server first. Embeddings and Console MCP are separate opt-ins.

## Preflight

Read repository instructions and preserve unrelated changes. Record:

```bash
git status --short --branch
ruby --version
bundle exec rails --version
bundle info woods 2>/dev/null || true
bundle exec rails runner 'puts Rails.application.class.name'
```

This skill targets Woods 2.0.0 or later. Use the installed version's documentation when older. Determine host vs Docker execution, database adapter, migration policy, existing Woods config/tables, and which filesystem context contains the application bundle and `tmp/woods/`.

## Install and inspect

Add `gem "woods", "~> 2.0"` to the development group, then:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
bin/rails generate woods:install
git diff -- config/initializers/woods.rb db/migrate
```

The generator creates an initializer and a migration for `woods_units`, `woods_edges`, and `woods_embeddings`. Check for conflicts before:

```bash
bin/rails db:migrate
```

Do not broadly update gems or overwrite existing configuration.

## Extract and verify

Structural setup needs no embedding provider:

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

If extraction fails, reproduce Rails boot and eager loading first. Do not inspect internal payload files when Woods tasks provide the check.

Configure the Index Server with the application bundle, absolute app `cwd`, and an index path visible to that process. For a host-installed bundle:

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

When Woods is installed only in Docker, launch it through the application service instead:

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

Reconnect and call `woods_status`, then `search`, `lookup`, and `dependents` for a known class. The normal Index Server has 14 tools. `codebase_retrieve` requires configured embeddings.

Offer to add `bundle exec rake woods:watch` to the existing development process manager. When authorized, it catches up missed changes and automatically maintains the structural index; the Index Server refreshes on its next call, so ordinary edits need no manual extraction or MCP restart. State that boot-captured changes require supervisor restart, Docker may need `WOODS_WATCH_POLL=1`, and semantic vectors still need `woods:embed_incremental`.

## Ask before expanding scope

Require explicit approval before adding Ollama/OpenAI, pgvector/Qdrant, secrets, Console MCP/live-data access, HTTP transport, or purge overrides. The `:local` preset avoids cloud keys but requires the `sqlite3` gem and an installed, running Ollama service; `:shared_filesystem` avoids sqlite3 but still uses Ollama.

## Handoff

Report the Woods version, branch, files changed, commands/results, index path, MCP calls verified, semantic retrieval status, Console status, and unresolved risks. Never infer availability from source schemas alone.

Canonical runbook: [AGENT_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md).
