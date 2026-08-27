# Upgrade from Woods 1.x to 2.0

Woods 2.0 changes observable index identifiers, publication layout, vector-store reconciliation, and the supported MCP surface. Plan a clean re-index. Do not upgrade a shared or durable index in place without a backup and a rollback window.

This guide assumes the last v1 release, 1.6.1, and targets 2.0.0.

## Upgrade outcome

After this runbook you will have:

- Woods 2.0 selected in the application bundle;
- reviewed v2 configuration and migration state;
- a clean v2 extraction with corrected identifiers;
- rebuilt embeddings and exports if you use them;
- an MCP client connected to the v2 packaged tool surface;
- a documented way back to v1 if verification fails.

## What changes

| v2 change | What can break | Required response |
|---|---|---|
| Correct namespaced and constrained-route identifiers | Saved identifiers, external links, retrieval vectors, and exports can miss renamed units | Clean extract; rebuild embeddings and exports |
| Typed graph identity variants | Custom graph consumers may assume one node per identifier | Re-index; update custom consumers to handle type variants |
| Atomic generations via `generation.json` | Custom scripts that read root `manifest.json` may fail | Follow the payload pointer or use Woods readers/tasks |
| `mcp >= 1.2, < 2.0` and protocol negotiation | Old lockfiles or manually pinned protocol versions can fail | Bundle update Woods/MCP; normally leave protocol version unset |
| Index MCP surface aligned to executable wiring | Agents may ask for tools that only exist as conditional schemas | Update agent instructions to the 14-tool default |
| Console surface tightened to 9 or 11 tools | Agents may ask for Tier 2/3 or eval schemas that do not execute | Use registered default/read tools only |
| Durable-store reconciliation and a 30% purge guard | The first v2 embed may refuse a legitimate rename-heavy deletion | Back up, inspect the deletion, then use the one-run override only if correct |
| Embedding dimension preflight | A previously tolerated model/store mismatch now fails before writing | Rebuild into a store with the configured dimension |
| Export reconciliation guards | Obsidian or Unblocked can refuse a rename-heavy stale-document sweep | Back up and use exporter-specific override only after review |
| `config.extractors` and `config.add_gem` warn as unimplemented | Old config may imply filtering that never occurred | Remove or comment the settings; do not rely on them |
| New watch, refresh, and evaluation tasks | New operational options become available | Optional; no migration action |

## Before changing the bundle

### 1. Record the current installation

Run in the same environment that boots Rails:

```bash
git status --short --branch
bundle exec woods --version
bundle exec rails woods:stats
bundle exec rails woods:validate
```

Record the current Woods version, output directory, storage preset/providers, embedding model and dimension, Console configuration, and enabled exports. Save current MCP client configuration and any custom scripts that read `tmp/woods/` directly.

### 2. Back up durable data

The generated structural index can be recreated, but its location may also hold local vector dumps and exporter manifests. Copy or snapshot the complete configured output directory before cleaning it.

Back up external vector stores separately:

| Store | Backup |
|---|---|
| pgvector | Database/schema snapshot or `pg_dump` of the configured vector table |
| Qdrant | Collection snapshot through Qdrant's snapshot API |
| `:local` or `:shared_filesystem` | Copy the configured output directory, including `dumps/` |

Also back up managed Obsidian/Unblocked destinations before allowing a mass stale-document cleanup. Notion does not delete old pages during reconciliation, but save its sync manifest with the output directory.

### 3. Choose a rollback point

Keep the v1 Gemfile/lockfile commit and all durable-store backups until v2 extraction, MCP calls, retrieval, and exports are verified. Downgrading the gem does not translate v2 identifiers back to v1.

## Upgrade the application

### 1. Update Woods without broad dependency churn

Change the development dependency:

```ruby
gem "woods", "~> 2.0"
```

Then update only Woods and the dependencies Bundler requires:

```bash
bundle update woods
bundle exec woods --version
```

Confirm the result is 2.0.0 and the lockfile resolves `mcp` at `>= 1.2, < 2.0`.

### 2. Review configuration

Generate the v2 template only when you can inspect conflicts safely. Do not overwrite an existing initializer blindly. Compare your initializer with the v2 [Configuration reference](CONFIGURATION_REFERENCE.md).

Pay particular attention to:

- `output_dir` and environment overrides;
- storage and embedding provider settings;
- the configured embedding model/dimension;
- Console MCP and embedded read-tool flags;
- snapshot, session, Notion, Obsidian, and Unblocked settings;
- old `config.extractors` or `config.add_gem` calls, which are not implemented selectors.

Review existing Woods migrations and tables before accepting any newly generated migration. Do not create duplicate `woods_units`, `woods_edges`, or `woods_embeddings` tables.

### 3. Clean and re-extract

After the backup is verified:

```bash
bin/rails woods:clean
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

The clean extract is required for corrected identifier shapes. Do not use an incremental run as the first v2 extraction.

An interrupted extraction leaves readers on the last complete generation because Woods publishes `generation.json` only after the payload is complete. Re-run the task; do not delete a partial directory speculatively.

## Rebuild optional systems

### Embeddings

If semantic retrieval is enabled:

```bash
bin/rails woods:embed
```

The first v2 run reconciles durable vectors with the new identifiers. A purge guard refuses deletion of more than 30% of the store or a purge into an empty extraction.

If it refuses:

1. Confirm extraction validation passed and unit counts are plausible.
2. Compare the proposed deletion with the expected identifier rename.
3. Confirm the vector-store backup is restorable.
4. Only then authorize one run:

```bash
WOODS_ALLOW_PURGE=1 bin/rails woods:embed
```

The override permits deletion; it is not a repair command. Do not set it permanently.

If Woods reports a dimension mismatch, verify the configured embedding model. Rebuild into a store created for the new dimension. Vectors cannot be converted in place.

An interrupted embed is safe to re-run; durable checkpoints resume or repair the missing unit.

### Exports

Re-run every export after extraction and embeddings are verified. Renamed identifiers appear as removal of the old document plus addition of the new one.

| Export | v2 behavior |
|---|---|
| Notion | Adds/updates current units and prunes manifest entries; it does not delete old Notion pages |
| Obsidian | Sweeps stale Woods-managed notes; refuses deletion beyond 30% unless `WOODS_OBSIDIAN_FORCE_PURGE` is explicitly set |
| Unblocked | Reconciles its sync manifest; for manifests with 10+ documents, refuses deletion beyond 30% unless `UNBLOCKED_FORCE_PURGE` is explicitly set |

Review the target and backup before any force-purge override. Use `WOODS_NOTION_FORCE=1` only when you intentionally want Notion to re-check unchanged content hashes.

## Update direct index consumers

Woods 2.0 publishes immutable payload directories and atomically points to the active one:

```text
tmp/woods/
├── generation.json
└── payloads/
    └── gen-42/
        ├── manifest.json
        ├── dependency_graph.json
        └── <type>/*.json
```

Woods tasks, readers, exporters, and MCP servers resolve this automatically. Custom tooling must read `generation.json`, resolve its `payload` relative to the index root, reject paths that escape that root, and then read the payload files. A missing payload key represents the legacy flat layout.

Graph consumers must also tolerate multiple typed variants for the same textual identifier. Do not collapse nodes by identifier alone when type is part of identity.

## Reconnect MCP clients

Use the project bundle so the server and application resolve the same Woods version:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/the-rails-app"
    }
  }
}
```

Normally leave `MCP_PROTOCOL_VERSION` unset. The SDK negotiates with legacy clients through `initialize` and supports newer discovery in the same process. Pin only as a temporary workaround for a client known to require one revision; a pin reduces compatibility and is announced on stderr.

Update agent prompts that refer to the old inventory. Standard Index launch provides 14 tools. Standard Console launch provides nine, or eleven with explicitly enabled embedded read tools. See [MCP servers](MCP_SERVERS.md).

## Verify before rollout

Complete every applicable check:

- [ ] `bundle exec woods --version` reports 2.0.0.
- [ ] Rails boots and eager-loads in the extraction environment.
- [ ] `woods:extract`, `woods:validate`, and `woods:stats` succeed.
- [ ] Expected namespaced and constrained identifiers appear.
- [ ] Custom index readers follow `generation.json`.
- [ ] `woods_status` reports the new generation.
- [ ] `search`, `lookup`, and `dependents` work with v2 identifiers.
- [ ] Semantic retrieval works after re-embedding, if enabled.
- [ ] Console exposes only the authorized 9/11 tools, if enabled.
- [ ] Exports were reconciled and stale-document changes reviewed.
- [ ] MCP and automation prompts no longer name inventory-only tools.
- [ ] Backups remain available through the rollout window.

## Roll back

If verification fails:

1. stop v2 MCP, watcher, embedding, and exporter processes;
2. restore the v1 Gemfile and lockfile or deploy the recorded v1 commit;
3. restore the v1 durable vector store and managed export backup when v2 modified them;
4. clean the generated index and extract again with v1;
5. restore v1 MCP configuration and reconnect clients;
6. verify v1 status and representative queries before reopening access.

A v1 gem cannot translate a v2 index or durable vector store back to v1 identifiers. Re-extraction and backup restoration are the rollback.

## Agent-operated upgrade prompt

> Upgrade this Rails application from Woods 1.x to 2.0 using `docs/UPGRADING_TO_2.md`. Start with read-only inventory and preserve unrelated changes. Before cleaning or reconciling anything, identify the output directory, providers, exports, direct index consumers, and restorable backups. Do not use purge overrides, enable Console/read tools, change credentials, or modify shared infrastructure without asking me. Perform a clean v2 extraction, validate it, update MCP instructions to the packaged 14-tool Index and 9/11 Console surfaces, and return the completed verification checklist plus rollback location.

For failures, use [Troubleshooting](TROUBLESHOOTING.md). For current setup, use [Getting started](GETTING_STARTED.md).
