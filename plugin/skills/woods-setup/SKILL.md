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

This skill targets Woods 2.0.0 or later. Use the installed version's documentation when older. Determine host vs Docker execution, database adapter, migration policy, existing Woods config/tables, and whether `tmp/woods/` is host-visible.

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

Configure the Index Server with the application bundle, absolute app `cwd`, and host-visible index:

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

Reconnect and call `woods_status`, then `search`, `lookup`, and `dependents` for a known class. The normal Index Server has 14 tools. `codebase_retrieve` requires configured embeddings.

## Ask before expanding scope

Require explicit approval before adding Ollama/OpenAI, pgvector/Qdrant, secrets, Console MCP/live-data access, HTTP transport, or purge overrides. The `:local` preset avoids cloud keys but requires an installed and running Ollama service.

## Handoff

Report the Woods version, branch, files changed, commands/results, index path, MCP calls verified, semantic retrieval status, Console status, and unresolved risks. Never infer availability from source schemas alone.

Canonical runbook: [AGENT_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md).
