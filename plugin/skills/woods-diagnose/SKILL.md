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

## Managed configuration availability

`woods-agent-config` (#407) is unreleased after `2.0.0.beta2`. First record the
installed version and test `bundle exec woods-agent-config --help` in the
selected application bundle. When supported, use its saved setup/update/remove
plan and explicit client/scope/root selection; apply the reviewed plan within
the user's existing authorization. Do not infer ownership from a server name
or repair edited managed sections by overwriting them. Plans and recovery
journals contain private configuration bytes. See the canonical
[managed configuration runbook](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md#managed-claude-code-configuration)
for host/Compose preflight, actual Claude file locations, conflict recovery,
and removal. Preserve manual setup for older installed versions.

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

### Session trace reports ambiguous identity

The `session_trace` `ambiguous_identity` error (#213) is unreleased after
`2.0.0.beta2`; check the installed gem before expecting it. It names a dependency
with multiple published extraction types, so no partial session context is
returned. Use `depth: 0` for the timeline or inspect the named candidates with
explicit `lookup` types. Do not choose one by index order or suggest that a full
extraction will remove a legitimate cross-type collision. See the canonical
[session identity contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#index-server).

## 2. Check the published index

For a `same-type identifier collision`, inspect both named source files and the
Rails loader before suggesting source edits. Wrapper-nested class naming needs
Zeitwerk mode and Zeitwerk >= 2.6.9; an older loader or classic mode can produce
the collision even when the namespace wrappers are valid. The expanded error
guidance (B-149) is unreleased after `2.0.0.beta2`; check the installed version
first. Follow the [loader compatibility guidance](https://github.com/lost-in-the/woods/blob/main/docs/UPGRADING_TO_2.md#check-the-loader-for-wrapper-nested-classes).

```bash
bin/rails woods:validate
bin/rails woods:stats
```

If missing or stale, run the narrow maintenance path justified by the evidence: `woods:incremental` for known file changes or `woods:extract` for first run, broad change, upgrade, or drift. Woods tasks understand `generation.json`; do not assume `manifest.json` is at the root.

Semantic graph validation (#413) is unreleased after `2.0.0.beta2`; verify the
installed gem before expecting these errors. Supporting versions check typed
unit identity, graph/index agreement and forward/reverse/file/type memberships
within one pinned generation. Preserve the failing generation and exact error,
then run a fresh full extraction with the intended bundle and validate again.
Do not hand-edit derived graph indexes to silence failures. A repeated error on
a fresh full run is evidence to report as an extraction defect. Unresolved
targets can be valid; validation cannot prove runtime execution or distinguish
an external name from an internal unit omitted everywhere. Follow the
[semantic recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#semantic-graph-validation-errors).

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

For volatile-dependency reports dominated by one target, compare the full
`stats.volatile_dependency_count` with the persisted array and use the
[ratio tuning guidance](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#pipeline-options).
The optional per-target cap (B-188) is unreleased after 2.0.0.beta2; check the
installed gem before suggesting `volatile_dependency_limit_per_target`.
Re-extract to publish configuration changes; the report remains informational.

For a shallow-checkout git-enrichment warning, the shallow guard (B-189) is
unreleased after `2.0.0.beta2`; check the installed version first. Fetch complete
history with `git fetch --unshallow` or `actions/checkout` `fetch-depth: 0`, then
run full extraction. Depth two only enables a two-commit diff; it does not
restore complete churn history. See the
[git metadata recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#git-metadata-is-missing-or-shows-zeros).

For `Git enrichment omitted: history could not be read completely`, first check
whether the installed Woods release documents the new streamed-history policy;
it is unreleased after 2.0.0.beta2. Supporting versions require Git 2.31 or newer.
Check `git --version` in the extraction container and repository/object-store
access with its `WOODS_GIT_DIR` setting. A failed history stream is discarded;
repair git access and run full extraction to refresh retained metadata. See the
[history contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#git-enrichment-history).

After a bundle change or removal of a dynamically defined job, incremental
extraction can retain stale runtime units. Use a fresh process with the updated
bundle for full extraction, then validate. For missing external gem paths,
first distinguish an upgraded bundle from a reader on a different host/mount.
The more explicit `woods:validate` bundle-update remedy (B-166) is unreleased
after `2.0.0.beta2`; the full-extraction recovery works on older versions too.
See [runtime removals and bundle updates](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md#runtime-removals-and-bundle-updates).

### Export identity checks

For Notion or Unblocked exports, typed selection checks (#213) are unreleased
after `2.0.0.beta2`; check the installed gem before expecting them. A missing or
mismatched export identity calls for index validation and a fresh extraction,
not a force flag. An `ambiguous export URI` means two types share an identifier
and source file: preserve existing documents and report the collision; do not
rename public identifiers or force deletion. Follow the canonical
[Notion](https://github.com/lost-in-the/woods/blob/main/docs/NOTION_INTEGRATION.md#sync-manifest-incremental-sync)
and [Unblocked](https://github.com/lost-in-the/woods/blob/main/docs/UNBLOCKED_INTEGRATION.md#uri-scheme)
guides for recovery and current limitations.

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

## Deferred refresh hooks

Expanded hook coverage and `woods:hook_refresh` (#408) are unreleased after
Woods 2.0.0.beta2. Verify the installed task through the configured host/container
command before diagnosing this plugin's queue. Read `<output>/hook.log` and
`hook-pending/`; status 75 means an active daemon deferred work, not that it was
consumed. Fix task availability, boot/publication failures or a stalled command,
then retry with the same output and command prefix. Preserve pending events.
A Docker timeout does not prove the application process stopped. Prefer a
resident watcher for sustained edits and follow the
[canonical retry guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#hooks-for-agent-sessions).

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

Configured retrieval defaults (#446) are unreleased after beta2. For an installed
version that supports them, an omitted tool budget uses the serving retriever's
configured default; an explicit budget overrides it. Standalone MCP does not
inherit the host initializer's token setting from the embedding snapshot.
Do not tune relevance with similarity_threshold: it is inert and deprecated.
Use query/type/scope selection and inspect ranking evidence instead. See
[retrieval tuning](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#tuning).

Only diagnose this layer when structural tools work and `codebase_retrieve` fails. First check `woods_status.retriever.mode`. For lexical mode, validate the published extraction index and follow the capability check below. For semantic mode, check the configured provider/model/vector store, provider reachability, and whether `woods:embed` completed.

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

## Lexical retrieval capability check

This is a development capability. Before proposing it, verify the installed gem
exposes `Woods::Configuration#retrieval_mode` and its matching guide documents
`WOODS_RETRIEVAL_MODE`. Keep the installed-version preflight; do not infer support
from the plugin version or an unreleased checkout.

For lexical errors, inspect the published generation and validate or re-extract
the index; adding provider credentials cannot repair a corrupt lexical index.
Semantic provider failure never switches to lexical automatically.
See the [retrieval guide](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval)
for the supported contract, checked against the installed gem version.

## Explicit package or path scope

Check the connected tool's advertised input schema before sending `packages` or
`source_paths`; older installed gems may not support them. When present, both
`search` and `codebase_retrieve` apply explicit scope before candidate limits.
Use published nearest package names or application-relative directory prefixes,
then inspect `applied_scope` and search completeness. Unknown packages are argument
errors; unsupported custom vector adapters degrade instead of running a global
query. Scoping can hide relevant cross-boundary relationships, so broaden the
request deliberately when the task needs them. See the
[scope contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#explicit-package-and-source-path-scopes).

## Source-content freshness (unreleased #405)

Check installed-version support before using `woods-extract` or the optional
`woods_status.source_check` argument. With support, inspect
`index.source_freshness`: `current`, `drifted` or `unknown`. Repeated edits to an
already-dirty file can leave the porcelain fingerprint unchanged. A quick scan
limit may justify one `source_check: "deep"`; unavailable source/private keys or
unproved boot/consumer coverage remain unknown. A fresh `bundle exec woods-extract full`
inside the application environment establishes preboot evidence. Never publish
`.source-inputs.key`, silently change its permissions, or delete queued edits to
hide diagnostics. Follow [source freshness](https://github.com/lost-in-the/woods/blob/main/docs/SOURCE_FRESHNESS.md).

## Compact evidence capability check

Inspect the connected server's installed tool schemas before using `evidence` on
`lookup` or `codebase_retrieve`; older releases do not provide these controls.
When available, explicit `compact` selects complete published source spans and
`outline` lists declared APIs. Read omission/provenance fields and follow the
returned typed, SHA-guarded `full_evidence` lookup for verification. Published-unit
coordinates are not physical file offsets; unknown generation remains unknown.
Keep full-source access available. See the canonical
[evidence contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines).

## Explicit edit adapters (unreleased #409)

Check the installed gem exposes `woods:hook_refresh` before enabling hooks.
Claude's registered wrapper covers one documented edit path; OpenCode 1.18.27
has a separate native `.js` registration wrapper importing Woods' shipped
adapter. Its verified patch metadata carries all added/updated/deleted/moved
paths. Keep the complete plugin directory available, preserve opt-in/disable
settings and pending events, and inspect the generation and hook log before
claiming refresh. Unsupported tool shapes and symlink paths need watch or an
explicit extraction. Do not install native client registration without the
user's setup request. Follow [client hooks](https://github.com/lost-in-the/woods/blob/main/docs/CLIENT_HOOKS.md).

## Optional context hints

Check installed `bundle exec woods-hook-context --help` before enabling
`WOODS_HOOK_CONTEXT_ENABLED=1`; this capability is unreleased after beta2 and the
plugin does not upgrade the gem. Context and refresh opt-ins are independent;
`WOODS_HOOKS_DISABLED=1` disables both. Native Claude context is synchronous and
bounded, with served-generation and pre-refresh/unknown labels. Verify candidate
dependents and suggested tests manually; silence is not no impact. Do not clear
refresh queues when optional hints time out. See the canonical
[context guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#optional-bounded-context-hints)
for output/time limits, container root mapping and emitted-hint suppression.
