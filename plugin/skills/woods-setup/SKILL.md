---
name: woods-setup
description: Install, upgrade, and first-run-configure the Woods Rails code-intelligence gem — Gemfile entry, generator, extraction, index verification, MCP registration, and the 1.x-to-2.x upgrade path. Use whenever a user wants Woods added to or upgraded in a Rails app, or asks for a runtime-accurate codebase index for AI tools, even without naming Woods' components.
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

This skill describes the Woods 2.x line; the authoritative minimum version lives in the marketplace entry. Operate only against capabilities the recorded installed version provides, and for an older gem use the documentation on that version's tag. Determine host vs Docker execution, database adapter, migration policy, existing Woods config/tables, and which filesystem context contains the application bundle and `tmp/woods/`.

## Install and inspect

Add `gem "woods", "~> 2.0"` to the development group, then:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
bin/rails generate woods:install
git diff -- config/initializers/woods.rb db/migrate
```

The generator creates an initializer and a legacy application migration for `woods_units`, `woods_edges`, and `woods_embeddings`. Woods 2's shipped structural index and storage backends do not use those application tables. For a new default installation, propose removing the generated migration and obtain approval first. Keep or run it only when repository history proves an older/custom integration uses those tables, after normal migration authorization and conflict checks.

Do not broadly update gems or overwrite existing configuration.

## Upgrading from 1.x

When the preflight records an installed 1.x version, this is an upgrade, not an install. Woods 2.0 changes observable index identifiers, the publication layout, vector-store reconciliation, and the supported MCP surface, so plan a clean re-index and follow the canonical runbook: [UPGRADING_TO_2.md](https://github.com/lost-in-the/woods/blob/main/docs/UPGRADING_TO_2.md).

Before changing the Gemfile: back up any shared or durable index and agree on a rollback window — never upgrade one in place. After `bundle update woods`, run a full `bin/rails woods:extract` (not incremental; the old index is not a valid baseline across the major), then `woods:validate`. With embeddings configured, re-embed from scratch into a store matching the configured model; expect identifier-level churn in anything that consumed 1.x identifiers (exports, saved queries, downstream tooling). Verify MCP clients against the new surface rather than assuming 1.x tool behavior.

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

Require explicit approval before adding Ollama/OpenAI, pgvector/Qdrant, secrets, Console MCP/live-data access, HTTP transport, or purge overrides. The `:local` preset avoids cloud keys but requires the `sqlite3` gem, an installed/running Ollama service, and a pulled model (`ollama pull nomic-embed-text` by default); `:shared_filesystem` avoids sqlite3 but still uses Ollama. Recommend `gem "tokenizers", "~> 0.5"` for exact counting on dense Ruby source, while stating that it is optional.

## Handoff

Report the Woods version, branch, files changed, commands/results, index path, MCP calls verified, semantic retrieval status, Console status, and unresolved risks. Never infer availability from source schemas alone.

Canonical runbook: [AGENT_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md).
