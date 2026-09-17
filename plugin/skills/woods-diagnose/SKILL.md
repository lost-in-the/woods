---
name: woods-diagnose
description: Diagnose Woods failures layer by layer — Rails boot, published index, MCP process and path, semantic retrieval, Console — changing nothing until the failing layer is identified. Use when Woods extraction, index validation, an MCP connection, retrieval, storage, or Console access fails or looks stale, or when expected tools are missing from a connected server.
---

# Woods diagnosis

Change nothing until the failing layer is identified. Diagnose the installed version:

```bash
bundle info woods
git status --short --branch
```

This skill describes the Woods 2.x line; the authoritative minimum version lives in the marketplace entry. Diagnose against capabilities the recorded installed version actually provides.

## 1. Check Rails

```bash
bundle exec rails runner 'puts Rails.application.class.name'
bundle exec rails runner 'Rails.application.eager_load!; puts "eager load ok"'
```

Use the application's normal Docker command and environment variables when applicable. Fix boot/eager-load failures before Woods.

### Watch repeatedly exits 75

Check the installed version's watch guide. Older releases, including
`2.0.0.beta2`, can rediscover the same restart-trigger paths on every boot. Stop
the supervisor, run one successful full extraction, then restart the standalone
watch task. Do not assume automatic startup reconciliation exists in that release.
For versions documenting environment-boot snapshots, confirm that the command is
`bundle exec rake woods:watch`, with no preceding `environment` task, and check
whether boot inputs keep changing during initialization or catch-up.

## 2. Check the published index

```bash
bin/rails woods:validate
bin/rails woods:stats
```

If missing or stale, run the narrow maintenance path justified by the evidence: `woods:incremental` for known file changes or `woods:extract` for first run, broad change, upgrade, or drift. Woods tasks understand `generation.json`; do not assume `manifest.json` is at the root.

If external targets such as `http_api` lose dependents after incremental
extraction, check whether the installed Woods version includes B-193.
The fix is unreleased; installing this plugin does not upgrade the gem.
Affected indexes need one full extraction after upgrading to a fixed version.
Follow the [recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#external-dependency-targets-lose-dependents-after-incremental-extraction).

For a custom shell/Python reader or upload gate, check its installed-version
assumptions against the [filesystem layout contract](https://github.com/lost-in-the/woods/blob/main/docs/INDEX_LAYOUT.md).
Resolve the pointer once and pin the manifest during a complete read/copy; never
select the highest payload directory or treat a missing root graph as no index.
Confirm the installed release and filesystem support retention locks before
using the pinning examples; flat layouts need writers stopped for a consistent copy.

A host reader can report a container daemon dead because foreign-host records
are rejected by default. Foreign heartbeat trust (#321) is unreleased: first
check the installed Woods version and that version's release notes. Only for a
supporting version, offer `WOODS_WATCH_TRUST_FOREIGN_HOST=1` in every relevant
task/MCP reader and follow [cross-host liveness](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#cross-host-liveness).
Fresh `degraded` still means incremental work is needed; a fresh `running`
record can outlive a crashed foreign daemon by up to 15 minutes. Older versions
need their status check run in the daemon's own container.

Writer-version provenance (#323) is unreleased: verify the installed gem version's
release notes before expecting it. If `index.woods_version` exists, compare it
with `server.version`; missing/null is unknown, not a failure. A validator
major-version warning calls for full extraction and upgrade review, while a match
does not certify retained units were migrated. See [writer provenance](https://github.com/lost-in-the/woods/blob/main/docs/PUBLISHED_INDEX.md#manifest-writer-provenance).

If a one-shot extraction raises `Could not publish generation`, the candidate
payload was written but never made visible; readers still serve the previous
complete generation. Fix the named filesystem, permission, space, or mount
failure and rerun the same task. Never edit `generation.json` or point a reader
at the unreachable payload by hand.

For slow extraction, use `WOODS_PROFILE=1` when supported by the installed
version. Keep process boot and resident-cycle measurements separate. Older
profiles nest payload sync and retention inside `publish`; current source
reports disjoint phases and a separate `[profile total]` line. Do not add
whole-run totals to phase durations or promise the new lines on an older gem.
Use the installed version's tagged guide; the
[canonical profiling guide](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md#profiling-fixed-costs)
tracks current source.

For `Git enrichment omitted: history could not be read completely`, first check
whether the installed Woods release documents the new streamed-history policy;
it is unreleased after 2.0.0.beta2. Supporting versions require Git 2.31 or newer.
Check `git --version` in the extraction container and repository/object-store
access with its `WOODS_GIT_DIR` setting. A failed history stream is discarded;
repair git access and run full extraction to refresh retained metadata. See the
[history contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#git-enrichment-history).

## 3. Check the MCP process and path

Compare the client config with the exact command, absolute `cwd`, bundle, and index path visible to that process. Run the configured executable manually to read stderr. For a host bundle:

```bash
bundle exec woods-mcp-start ./tmp/woods
```

Then reconnect through the MCP client and call `woods_status`. Use client-native tool inspection after initialization. Expect 14 packaged Index tools, not all conditional schemas.

For Docker-only bundles, test the configured container command instead, for example `docker compose exec -T app bundle exec woods-mcp /app/tmp/woods`. Use the container path for a container process and a host path only for a host process.

For corrupt pipeline cooldown state, first confirm this is a custom server
with `pipeline_repair` registered; packaged `woods-mcp` does not wire it.
Recovery through `reset_cooldowns` (B-159) is unreleased after `2.0.0.beta2`.
Check the installed version before attempting it and follow the
[corrupt cooldown recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#corrupt-pipeline-cooldown-state).

## Partial dependency answers

Traversal budgets (`max_nodes`/`max_edges`, #311) are unreleased in Woods
2.0.0.beta2. Check the installed gem version and connected tool schema before
using them; installing this plugin does not upgrade the gem. On a supporting
server, `partial`/`partial_reason` means the walk stopped early, independently
of page truncation. Do not claim an exhaustive blast radius or treat empty
deps as proof of a leaf. Narrow depth/types/via or increase a supported budget;
paging alone only visits the discovered prefix. See the
[budget contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#dependency-traversal-budgets).

## 4. Check semantic retrieval

Only diagnose this layer when structural tools work and `codebase_retrieve` fails. Check `woods_status`, configured provider/model/vector store, provider reachability, and whether `woods:embed` completed.

- OpenAI: verify the key exists without printing it.
- Ollama: verify the service and configured model locally.
- Stale vectors or missing same-name types: follow the installed version's upgrade guide and run the documented embed refresh; do not rename public identifiers or edit vector IDs by hand.
- Dimension mismatch: rebuild into a store matching the configured model; do not suppress the preflight.
- Purge guard: back up and inspect the proposed deletion; never set `WOODS_ALLOW_PURGE` without explicit approval.

For metadata appearing in another index or worktree, compare `WOODS_OUTPUT`,
`config.output_dir`, and any explicit `metadata_store_options[:database]`.
The default SQLite path following `WOODS_OUTPUT` during embedding (B-156) is
unreleased after `2.0.0.beta2`; check the installed version before relying on it.
An explicit database path still wins. See the
[SQLite path contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#sqlite-metadata)
for isolation and upgrade steps.

## 5. Check Console separately

For repeated missing-token boot warnings on a stdio-only host, check whether
its installed version supports `console_mcp_http_enabled = false` before
suggesting it; this option is unreleased in Woods 2.0.0.beta2. The default
preserves HTTP enablement, so selecting stdio as a client alone does not
suppress HTTP token validation. Never disable authentication on an HTTP
endpoint to silence this warning.

Console failures are live Rails/config/security failures, not Index failures. Verify authorized environment, Rails boot, `WOODS_CONSOLE_CONFIG` or direct `cwd`, blocked-table policy, credentials, and stderr.

For MySQL SQL refusals, inspect the executing session's `sql_mode` and the installed version's Console guide. Do not change quote modes to bypass a security refusal.

Nine tools are normal. Eleven appear only with `console_embedded_read_tools`. Do not chase Tier 2/3 or `console_eval`; they do not register in supported packaged modes. Never work around redaction, credential scanning, SQL validation, or a block.

## Report

Return the first failing layer, commands/evidence, root-cause hypothesis, whether any file changed, and the smallest next action. If a fix is requested, change one thing and rerun the failing check before proceeding.

Canonical guide: [TROUBLESHOOTING.md](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md).
