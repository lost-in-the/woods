# Upgrade from Woods 1.x to 2.0

Woods 2.0 changes observable index identifiers, publication layout, vector-store reconciliation, and the supported MCP surface. Plan a clean re-index. Do not upgrade a shared or durable index in place without a backup and a rollback window.

This guide covers the supported 1.6.x line and targets 2.0.0. Use the latest
published 1.6.x security patch as the rollback version.

<!-- release-state:upgrade-availability -->
<!-- release-state:end -->

## 2.0.1 security maintenance update

This maintenance line adds Console request/output policy corrections and isolates
retrieval contexts between retriever instances. It does not add the graph or
extraction features under development for 2.1. Confirm the installed package
version and use its matching tag documentation.

No index or database schema migration is required. Restart Console/MCP processes
after upgrading. Explicit malformed HTTP origin entries now fail at boot with the
offending entry named; fix the entry rather than weakening authentication.
Automatic and manual Console mounts raise `Woods::ConfigurationError` for these
settings, including invalidly encoded entries. With
no allowlist configured, the existing loopback defaults remain unchanged. See
[HTTP origin matching](MCP_HTTP_TRANSPORT.md#browser-origins-dns-rebinding-defense).

Raw `console_sql` now refuses ambiguous protected results and genuinely unknown
adapter families. PostgreSQL-subclass adapters retain PostgreSQL handling;
structured Console tools remain available with other adapters. Prefer explicit
unaliased scalar projections or structured reads when a query is refused.
[Console setup](CONSOLE_MCP_SETUP.md#maintenance-policy-corrections) describes the
compatibility boundary. Context caches refill after restart; retired entries
follow the configured TTL or backend eviction. See
[retrieval cache options](CONFIGURATION_REFERENCE.md#retrieval-cache-options).
Rolling back restores the affected behavior.

Polymorphic `belongs_to` association counts remain unsupported in 2.0.1 and
1.6.4 and return a generic execution error; the 2.1 functional correction is
not backported.

## Upgrade outcome

After this runbook you will have:

- Woods 2.0 selected in the application bundle;
- reviewed v2 configuration and migration state;
- a clean v2 extraction with corrected identifiers;
- rebuilt embeddings and exports if you use them;
- an MCP client connected to the v2 packaged tool surface;
- a documented way back to v1 if verification fails.

### Console read compatibility

For supporting security-patch revisions, any nonempty column or EAV redaction
policy makes `console_sql` refuse relation and CTE column alias lists, including
lists on base tables, derived tables, parenthesized `VALUES` sources and table
functions, regardless of the selected names. Use explicit, unaliased protected
columns or structured tools.
Typed EAV lookup includes all registered models with a case-insensitive matching
final table name, including across schemas. It can therefore mask extra values;
qualification does not narrow this conservative type set. Sensitive key values
still require their exact stored or cast spelling.

The 1.6.x function denylist becomes a read-only function allowlist in 2.x.
Supply one `console_query` expression per `select` array entry: 2.x refuses
comma-combined entries that 1.6.4 splits. Raw SQL requires a recognized adapter
family; structured tools remain available on other adapters. Configure binary
secret columns explicitly for redaction. See the canonical
[read policy compatibility](CONSOLE_MCP_SETUP.md#read-policy-compatibility) and
[statement timeouts](CONSOLE_MCP_SETUP.md#statement-timeout) for limits.

Supporting Console HTTP revisions deliberately permit allowlisted non-loopback
Hosts through the SDK where 2.0.0 could refuse them. Bearer authentication remains
required. An explicit origin list replaces browser-origin defaults; wildcards
are not supported. Ruby-configured 2.x origins reject surrounding whitespace
that 1.6.4 trims; the HTTP executable trims comma-separated environment entries
on both lines. Review [HTTP origin configuration](MCP_HTTP_TRANSPORT.md#origin-configuration-compatibility).

Context-cache namespace rotation retires entries for normal TTL or backend
eviction; disabling both can retain them indefinitely. See
[retrieval cache options](CONFIGURATION_REFERENCE.md#retrieval-cache-options).

## What changes

| v2 change | What can break | Required response |
|---|---|---|
| Correct namespaced and constrained-route identifiers | Saved identifiers, external links, retrieval vectors, and exports can miss renamed units | Clean extract; rebuild embeddings and exports |
| Wrapper-nested class identifiers resolved to the file's own constant | Files nested in class namespaces (e.g. `app/services/domain/container/parser.rb` defining `module Domain; class Container; class Parser`) gain identifiers like `Domain::Container::Parser` instead of sharing the wrapper's; layouts that still derive one type+identifier from two different files abort extraction naming both files | Clean extract; rebuild embeddings and exports |
| Typed graph identity variants | Custom graph consumers may assume one node per identifier | Re-index; update custom consumers to handle type variants |
| Atomic generations via `generation.json` | Custom scripts that read root `manifest.json` may fail | Follow the payload pointer or use Woods readers/tasks |
| `mcp >= 1.2, < 2.0` and protocol negotiation | Old lockfiles or manually pinned protocol versions can fail | Bundle update Woods/MCP; normally leave protocol version unset |
| Index MCP surface aligned to executable wiring | Agents may ask for tools that only exist as conditional schemas | Update agent instructions to the 14-tool default |
| Console surface tightened to 9 or 11 tools | Agents may ask for Tier 2/3 or eval schemas that do not execute | Use registered default/read tools only |
| Missing-token behavior changed outside production | An enabled Console HTTP endpoint now stays mounted but returns 401 without a valid token; production still refuses to boot without one | Preserve or configure a secret token of at least 32 characters; send it only to the HTTP transport |
| Durable-store reconciliation and a 30% purge guard | The first v2 embed may refuse a legitimate rename-heavy deletion | Back up, inspect the deletion, then use the one-run override only if correct |
| Embedding dimension preflight | A previously tolerated model/store mismatch now fails before writing | Rebuild into a store with the configured dimension |
| Export reconciliation guards | Obsidian or Unblocked can refuse a rename-heavy stale-document sweep | Back up and use exporter-specific override only after review |
| Notion column pages are grouped by physical table | Models sharing a table (STI, a shared `self.table_name`) previously rewrote each other's column pages on every run | Re-sync once after re-extraction; the shared pages settle and the churn stops |
| One-shot extraction tasks fail when the generation marker cannot be published | A run that wrote a payload readers cannot reach used to print success and exit 0 | Fix the write failure and re-run; the previous generation stays active meanwhile |
| `woods:incremental` and `woods:refresh` refuse an output directory with no baseline index | A restored-cache miss, a typo'd `WOODS_OUTPUT`, or a fresh runner now fails instead of publishing a near-empty index | Run a full `woods:extract` first, or point `WOODS_OUTPUT` at the directory holding the existing index |
| `woods:incremental` exits 1 over a git range it cannot resolve | An unresolvable base ref used to read as "nothing changed" and exit 0 | Fetch the base ref, set `CHANGED_FILES`, or accept the stand-down a live watch daemon provides |
| `woods:embed`, `woods:embed_incremental`, and `woods:notion_sync` exit 1 on reported errors | CI jobs that were green while every unit or page failed now fail | Read the printed errors, fix the cause, re-run; completed work is durable |
| The Index MCP `reload` tool needs write access to the index directory | A read-only index mount can serve structural reads but cannot reload in place | Grant write access, or restart the MCP process after publishing |
| `config.extractors` and `config.add_gem` warn as unimplemented | Old config may imply filtering that never occurred | Remove or comment the settings; do not rely on them |
| New watch, refresh, and evaluation tasks | New operational options become available | Optional; no migration action |

## Before changing the bundle

### Check the loader for wrapper-nested classes

File-path-governed naming of classes inside class namespaces requires **Zeitwerk
mode with Zeitwerk 2.6.9 or later** (`cpath_expected_at`, introduced in
[Zeitwerk 2.6.9](https://github.com/fxn/zeitwerk/blob/main/CHANGELOG.md#269-25-july-2023)). This is a requirement
of that naming capability, not a higher Rails minimum. Older Zeitwerk and
classic-mode applications can still extract ordinary declarations, but Woods
cannot use the loader to distinguish a file's class from its enclosing class
wrappers. Two sibling files may then derive the same wrapper identifier and
extraction will abort rather than silently discard one.

For a `same-type identifier collision`, inspect both named files and the
application's loader mode/version before rewriting valid namespace wrappers.
On an older-loader host, move to a compatible Zeitwerk version and Zeitwerk mode,
verify that the application boots and eager-loads, then run a fresh full
extraction. Rebuild embeddings and exports if identifiers change. A genuine
duplicate under a supported loader still needs distinct constants or one source
file. Woods does not provide a classic-mode naming fallback for this case.

### 1. Record the current installation

Run in the same environment that boots Rails:

```bash
git status --short --branch
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
bundle exec rails woods:stats
bundle exec rails woods:validate
```

Record the current Woods version, output directory, storage preset/providers, embedding model and dimension, Console configuration, and enabled exports. For Console, record the transport, token source or presence without recording its value, allowed origins, path, and embedded read-tool setting. Save current MCP client configuration and any custom scripts that read `tmp/woods/` directly.

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

Record and test a Gemfile/lockfile selecting the latest published 1.6.x security
patch as the rollback bundle. If the current installation is older, verify that
patched v1 bundle before beginning the v2 migration. Keep its commit and all
durable-store backups until v2 extraction, MCP calls, retrieval, and exports are
verified. Downgrading the gem does not translate v2 identifiers back to v1.

## Upgrade the application

### 1. Update Woods without broad dependency churn

Change the development dependency:

```ruby
gem "woods", "~> 2.0"
```

Then update only Woods and the dependencies Bundler requires:

```bash
bundle update woods
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
```

Confirm the result is 2.0.0 and the lockfile resolves `mcp` at `>= 1.2, < 2.0`.

### 2. Review configuration

Generate the v2 template only when you can inspect conflicts safely. Do not overwrite an existing initializer blindly. Compare your initializer with the v2 [Configuration reference](CONFIGURATION_REFERENCE.md).

Pay particular attention to:

- `output_dir` and environment overrides;
- storage and embedding provider settings;
- the configured embedding model/dimension;
- `console_mcp_enabled`, `console_mcp_http_enabled`, the HTTP `console_mcp_token` secret source, allowed origins, path, and embedded read-tool flags;
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

Included in Woods `2.0.0`: `woods:clean` removes index artifacts but keeps
the output directory and its hidden extraction guard. This stable guard lets
concurrent writers coordinate safely; its presence does not mean an index remains.

The clean extract is required for corrected identifier shapes. Do not use an incremental run as the first v2 extraction: after `woods:clean` there is no baseline, and v2 `woods:incremental` refuses that state rather than publishing a near-empty index as the application's complete truth.

An interrupted extraction leaves readers on the last complete generation because Woods publishes `generation.json` only after the payload is complete. Re-run the task; do not delete a partial directory speculatively. A run that completes its payload but cannot publish the marker now fails loudly instead of reporting success, so treat a non-zero exit as work to redo rather than as a partial success.

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

**Notion needs one settling re-sync.** v2 groups column pages by physical table instead of by model, so models that share a table write one page per physical column, with the `Table` relation listing every owning model and their validations unioned. The page titles, and therefore the manifest keys, are unchanged, but the content hash of every shared-table column changes once. Expect the first post-upgrade `woods:notion_sync` to update those pages; subsequent runs skip them. This also ends the v1 behavior where two models sharing a table rewrote the same column page back and forth on every run. See [Notion integration](NOTION_INTEGRATION.md).

## Update CI and scheduled automation

v2 tasks fail instead of printing an error and exiting 0. Review any pipeline that runs Woods unattended before the first v2 run:

| Task | v2 exit behavior |
|---|---|
| `woods:extract`, `woods:incremental`, `woods:refresh` | Raise when the payload cannot be published as a generation; the previous generation stays active |
| `woods:incremental` | Refuses an output directory with no baseline index, and exits 1 over a git range it cannot resolve unless a live watch daemon maintains the tree. See [Incremental extraction](INCREMENTAL_EXTRACTION.md) |
| `woods:embed`, `woods:embed_incremental`, `woods:notion_sync` | Exit 1 when the run reports errors, matching `woods:unblocked_sync` and `woods:obsidian` |

A job that restores the index directory from a cache must restore the whole thing. A missing or empty restore is exactly the state the baseline guard refuses, and the fix is a full `woods:extract` on that runner, not an override.

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

Use the [filesystem layout contract](INDEX_LAYOUT.md) for Bash/jq and Python
examples. Multi-file reads and uploads must keep the selected payload pinned
against retention for the complete read/copy; pointer resolution alone does not
protect a directory from being pruned.

The optional manifest `woods_version` records its last publisher. A matching
major version after an incremental run does not establish that older units were
migrated; keep the full re-extraction requirement. See [writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance).

Graph consumers must also tolerate multiple typed variants for the same textual identifier. Do not collapse nodes by identifier alone when type is part of identity.

The bundle requires patched MessagePack >=1.8.2 and JSON >=2.19.9, <3.
JSON 3 removes an encoder option used by older supported Rails versions; keep the
compatible JSON 2.x dependency when resolving the v2 bundle.

Embedding preserves coexisting types with internal `@woods-unit:` storage keys
(Base64-encoded JSON `[identifier, type]`, with the existing chunk suffix appended
when needed). Public identifiers and source attribution stay unchanged. Unique
ordinary names retain their previous keys; names beginning with this reserved
prefix are escaped too. An incremental embed migrates an ambiguous legacy key only
after storing its replacement vectors. Existing typed keys stay stable when one
variant disappears. Normal mass-deletion guards still apply to vanished units.
Custom vector consumers must treat storage IDs as opaque and use metadata for
public identifiers. Evaluation baselines normalize storage keys back to public
names and count same-named typed variants once, matching name-based ground truth.
Older dumps remain readable; re-embed to recover variants
that an older writer had already overwritten.

SQLite migration 007 preserves snapshot rows and permits one row per
`(snapshot_id, identifier, unit_type)`. JSON snapshot readers accept older untyped
records, while new records preserve both names and types. Lost historical variants
cannot be reconstructed from old snapshots. Back up `woods.sqlite3` and the whole
index before upgrading: reverting code alone does not reverse this migration.
Restore the matching backup or rebuild in a separate store when rolling back.

Flow documents for identifiers containing literal underscores now use a digest to
avoid collisions with namespaced controllers and combined action names. Read the
published flow index instead of constructing filenames. A full extraction rebuilds
precomputed flows consistently; use it when upgrading an index with existing flow
artifacts.

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

Structural reads still work from a read-only index mount, but the `reload` tool does not: its transactional refresh takes the same on-disk writer lock as extraction and embedding, so the MCP process needs write access to the index directory. Without it, `reload` returns a typed degraded error and keeps serving the previous aligned generation rather than swapping in a partial one. Grant write access, or restart the MCP process after publishing. [MCP servers](MCP_SERVERS.md) owns the detail.

### Console users: preserve or configure the HTTP token

If HTTP Console is enabled, preserve or configure a secret token of at least
32 characters. Missing tokens warn outside production and HTTP requests fail
closed with 401; production boot refuses them. Configured short tokens raise
while HTTP Console is enabled. Keep token values in the application's normal
secret store, never in committed configuration.

Stdio does not use a bearer token. On versions supporting
`console_mcp_http_enabled`, set it to `false` for stdio-only use without HTTP
boot validation, while keeping the master `console_mcp_enabled` flag on.
The HTTP flag defaults to `true` to preserve existing deployments; choosing a
stdio client alone does not turn HTTP off. Older versions without this flag
still require a token at production boot whenever Console is enabled.

Follow [Console MCP setup](CONSOLE_MCP_SETUP.md) for transport-specific setup
and the [Configuration reference](CONFIGURATION_REFERENCE.md) for defaults.


## Verify before rollout

Complete every applicable check:

- [ ] `bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'` reports 2.0.0.
- [ ] Rails boots and eager-loads in the extraction environment.
- [ ] `woods:extract`, `woods:validate`, and `woods:stats` succeed.
- [ ] Expected namespaced and constrained identifiers appear.
- [ ] Custom index readers follow `generation.json`.
- [ ] `woods_status` reports the new generation.
- [ ] `search`, `lookup`, and `dependents` work with v2 identifiers.
- [ ] Semantic retrieval works after re-embedding, if enabled.
- [ ] Console exposes only the authorized 9/11 tools, if enabled.
- [ ] An enabled Console reads a token of at least 32 characters from a secret source; its value was not printed or committed.
- [ ] Console HTTP rejects a request without the bearer token with 401 and accepts the configured client, if HTTP is used.
- [ ] Console stdio starts through the application bundle, if stdio is used.
- [ ] Exports were reconciled and stale-document changes reviewed.
- [ ] A second `woods:notion_sync` reports the shared-table column pages as skipped, if Notion is enabled.
- [ ] Unattended pipelines were reviewed against the new exit behavior, and any job that restores the index directory restores a complete baseline.
- [ ] The MCP process has write access to the index directory, if agents call `reload`.
- [ ] MCP and automation prompts no longer name inventory-only tools.
- [ ] Backups remain available through the rollout window.

## Roll back

If verification fails:

1. stop v2 MCP, watcher, embedding, and exporter processes;
2. restore the tested, patched v1 Gemfile and lockfile or deploy its recorded commit;
3. run the v1 `woods:clean` before restoring anything under the configured output directory;
4. either restore the complete pre-upgrade v1 output-directory backup, or run a fresh v1 extraction and then restore its v1 `dumps/` and configuration artifacts;
5. restore external vector-store and managed export backups when v2 modified them;
6. restore v1 MCP configuration and reconnect clients;
7. verify v1 status and representative queries before reopening access.

A v1 gem cannot translate a v2 index or durable vector store back to v1 identifiers. Re-extraction and backup restoration are the rollback. Do not run `woods:clean` after restoring local or shared-filesystem dumps; v1 removes the entire output directory.

## Agent-operated upgrade prompt

> Upgrade this Rails application from Woods 1.x to 2.0 using `docs/UPGRADING_TO_2.md`. Start with read-only inventory and preserve unrelated changes. Before cleaning or reconciling anything, identify the output directory, providers, exports, direct index consumers, and restorable backups. Report only whether a Console token exists and where it comes from, never its value. Do not use purge overrides, enable Console/read tools, create or rotate tokens, change credentials, or modify shared infrastructure without asking me. Perform a clean v2 extraction, validate it, update MCP instructions to the packaged 14-tool Index and 9/11 Console surfaces, and return the completed verification checklist plus rollback location.

For failures, use [Troubleshooting](TROUBLESHOOTING.md). For current setup, use [Getting started](GETTING_STARTED.md).
