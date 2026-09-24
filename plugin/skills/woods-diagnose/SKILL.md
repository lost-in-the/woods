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

`woods-agent-config` (#407) is available in Woods `2.0.0.beta3`. First record the
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

### Watcher setup cannot find already installed Rails or dependencies

Compare normal task discovery with installer preflight in the same container and
application environment. Early Git builds of the watcher installer stripped
`BUNDLE_PATH` and `BUNDLE_APP_CONFIG`; Woods `2.0.0` includes the #540 fix.
Record the loaded revision and bundle configuration source before
reinstalling dependencies or writing a local bundle-path workaround. Follow the
[watcher installation guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#managed-development-startup).

### Puma cannot load the Woods plugin after switching branches

Early generated guards checked only whether Woods was activated. An older gem
can satisfy that check without providing `puma/plugin/woods.rb`. The #542 fix is
included in Woods `2.0.0`: verify the loaded revision, then use a supporting
bundle to preview and apply `bin/rails generate woods:watch --operation update
--mode puma`. The updated guard checks the active gem's require paths, so older
gems boot without a watcher. Repeating setup does not upgrade the guard. Follow
the [owned setup runbook](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#ownership-updates-and-removal);
do not change the owned directive or receipt manually.

### Watch repeatedly exits 75

First identify the lifecycle owner. The raw task deliberately exits 75; a bare
Foreman entry then stops all services. Managed `woods-watch`/Puma setup (#538)
is included in Woods `2.0.0`: verify installed executable/generator help and
loaded revision before proposing it. Supporting launchers retry boot failures,
reject idle TTL, and park ownership/protocol conflicts until owner restart.
Inspect separate supervision state rather than treating its parent PID as a
healthy daemon. Before the first resolved index path, use launcher logs.
Do not remove claims or kill PIDs from status to force takeover. See
[startup diagnosis](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#watcher-startup-or-planned-restart-fails).

Check the installed version's watch guide. Older releases, including
`2.0.0.beta2`, can rediscover the same restart-trigger paths on every boot. Stop
the supervisor, run one successful full extraction, then restart the standalone
watch task. Do not assume automatic startup reconciliation exists in that release.
For versions documenting environment-boot snapshots, confirm that the command is
the application's actual `rails woods:watch` or `rake woods:watch` entrypoint,
with no preceding `environment` task, and check
whether boot inputs keep changing during initialization or catch-up.

### Watch retains facts from an initializer deleted while stopped

Record the installed revision. In Woods `2.0.0`, startup preserves
registered deleted boot inputs as full-extraction obligations. On earlier builds,
stop watch, run a successful full extraction in a fresh process, then restart
standalone `woods:watch`. See the installed version's watch guide.

### A cleaned index directory still exists

In Woods `2.0.0`, `woods:clean` retains the output directory and
hidden extraction guard for concurrent writer coordination. Verify published
artifacts are gone; do not remove that guard while writers may be running.

### Watch misses edits under a shared directory alias

Check the installed version: logical alias preservation (#445) is available in Woods `2.0.0.beta3`.
Older polling/catch-up walkers could visit an irrelevant alias first and suppress
`app/models` when both point to the same physical directory. Compare the logical
path with the extraction input path; a running daemon alone does not prove coverage.
Use a manual extraction for recovery until upgrading. The corrected walker keeps
independent aliases and prunes ancestor cycles; do not remove cycle or ignore guards.
See the installed version's watch guide before assuming this behavior.

### Session trace reports ambiguous identity

The `session_trace` `ambiguous_identity` error (#213) is available in Woods `2.0.0.beta3`;
check the installed gem before expecting it. It names a dependency
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
guidance (B-149) is available in Woods `2.0.0.beta3`; check the installed version
first. Follow the [loader compatibility guidance](https://github.com/lost-in-the/woods/blob/main/docs/UPGRADING_TO_2.md#check-the-loader-for-wrapper-nested-classes).

The incremental/refresh collision guard (#561) is unreleased after 2.0.0; verify
the writer revision before relying on it. A refusal preserves the prior
generation. Older writers could already have overwritten ownership: repair the
producer/source issue and perform a successful full extraction to recover.
Woods 2.0.0 can also misidentify Struct/Data classes inside namespace wrappers
(#559). The fix is unreleased after 2.0.0, planned for 2.1: verify the writer's
loaded revision before expecting assigned PORO/library child identities. A full
extraction repairs old identities and establishes reference-cache format 2;
incremental extraction refuses the older cache. Preserve the last generation
until the rebuild succeeds. Do not rename valid application constants or disable
collision checks to bypass an older writer's inference. Follow the
[assigned value-class contract](https://github.com/lost-in-the/woods/blob/main/docs/EXTRACTOR_REFERENCE.md#assigned-value-classes);
constructor blocks and unverified dynamic assignments remain outside reference
coverage. Updating this plugin does not upgrade the writer.

```bash
bin/rails woods:validate
bin/rails woods:stats
```

If missing or stale, run the narrow maintenance path justified by the evidence: `woods:incremental` for known file changes or `woods:extract` for first run, broad change, upgrade, or drift. Woods tasks understand `generation.json`; do not assume `manifest.json` is at the root.

For incremental CI, restore only an index for the selected diff's exact base
commit; a cold or unrelated cache requires full extraction. Fetch the actual
PR base ref and sufficient history before running the task. Nested-app Git
paths, normalization of `./` and contained absolute `CHANGED_FILES`, and blank
CI-variable handling are unreleased after `2.0.0` (#571); check the installed
revision before relying on them. Keep nonempty invalid ranges as failures.
See the [incremental CI contract](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md#github-actions-with-an-exact-baseline).

Semantic graph validation (#413) is available in Woods `2.0.0.beta3`; verify the
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
The fix is available in Woods `2.0.0.beta3`; installing this plugin does not upgrade the gem.
Affected indexes need one full extraction after upgrading to a fixed version.
Follow the [recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#external-dependency-targets-lose-dependents-after-incremental-extraction).

For a custom shell/Python reader or upload gate, check its installed-version
assumptions against the [filesystem layout contract](https://github.com/lost-in-the/woods/blob/main/docs/INDEX_LAYOUT.md).
Resolve the pointer once and pin the manifest during a complete read/copy; never
select the highest payload directory or treat a missing root graph as no index.
Confirm the installed release and filesystem support retention locks before
using the pinning examples; flat layouts need writers stopped for a consistent copy.

A host reader can report a container daemon dead because foreign-host records
are rejected by default. Foreign heartbeat trust (#321) is available in Woods `2.0.0.beta3`: first
check the installed Woods version and that version's release notes. Only for a
supporting version, offer `WOODS_WATCH_TRUST_FOREIGN_HOST=1` in every relevant
task/MCP reader and follow [cross-host liveness](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#cross-host-liveness).
Fresh `degraded` still means incremental work is needed; a fresh `running`
record can outlive a crashed foreign daemon by up to 15 minutes. Older versions
need their status check run in the daemon's own container.

Writer-version provenance (#323) is available in Woods `2.0.0.beta3`: verify the installed
gem version's release notes before expecting it. If `index.woods_version` exists, compare it
with `server.version`; missing/null is unknown, not a failure. A validator
major-version warning calls for full extraction and upgrade review, while a match
does not certify retained units were migrated. See [writer provenance](https://github.com/lost-in-the/woods/blob/main/docs/PUBLISHED_INDEX.md#manifest-writer-provenance).

Included in Woods `2.0.0`: incremental/refresh handled source errors keep
the previous generation active and leave watch batches pending. Repair the
logged source error and retry the complete batch; see
[handled source errors](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md#handled-source-errors-and-retry).
Check the installed revision before relying on this behavior.

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
The optional per-target cap (B-188) is available in Woods `2.0.0.beta3`; check the
installed gem before suggesting `volatile_dependency_limit_per_target`.
Re-extract to publish configuration changes; the report remains informational.

For a shallow-checkout git-enrichment warning, the shallow guard (B-189) is
available in Woods `2.0.0.beta3`; check the installed version first. Fetch complete
history with `git fetch --unshallow` or `actions/checkout` `fetch-depth: 0`, then
run full extraction. Depth two only enables a two-commit diff; it does not
restore complete churn history. See the
[git metadata recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#git-metadata-is-missing-or-shows-zeros).

For `Git enrichment omitted: history could not be read completely`, first check
whether the installed Woods release documents the new streamed-history policy;
it is available in Woods `2.0.0.beta3`. Supporting versions require Git 2.31 or newer.
Check `git --version` in the extraction container and repository/object-store
access with its `WOODS_GIT_DIR` setting. A failed history stream is discarded;
repair git access and run full extraction to refresh retained metadata. See the
[history contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#git-enrichment-history).

If per-unit Git metadata is absent, check `git --version` inside the extraction
process/container as well as repository access. Builds with #551 warn when Git
cannot execute and a repository is expected; older versions may be silent.
Source archives without a Git directory remain supported. `GIT_SHA` and
structural `ready` do not certify history availability. After repairing Git,
run full extraction; see the
[missing-executable diagnostic](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#git-executable-is-missing-from-the-extraction-environment).

For linked-worktree provenance/history mismatches, check the installed version's
`WOODS_GIT_DIR` support and compare the selected branch and exact SHA inside the
extraction environment. Mount the complete shared `.git` at its original path
with no override, or select `/mounted-common/worktrees/<id>` within a relocated
complete mount. Derive `<id>` from Git metadata, not the branch name. Selecting
the shared root uses the primary checkout's HEAD and also changes incremental
ranges. A commit alone may leave the source-file watcher idle; run full
extraction after repair or when current Git history is required. See the
[worktree mount guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#git-directory-mounts-for-linked-worktrees).

After a bundle change or removal of a dynamically defined job, incremental
extraction can retain stale runtime units. Use a fresh process with the updated
bundle for full extraction, then validate. For missing external gem paths,
first distinguish an upgraded bundle from a reader on a different host/mount.
The more explicit `woods:validate` bundle-update remedy (B-166) is available in Woods
`2.0.0.beta3`; the full-extraction recovery works on older versions too.
See [runtime removals and bundle updates](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md#runtime-removals-and-bundle-updates).

### Export identity checks

For Notion or Unblocked exports, typed selection checks (#213) are available in Woods
`2.0.0.beta3`; check the installed gem before expecting them. A missing or
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

If startup says `Could not resolve a published Woods index` (included in Woods
`2.0.0`) or names a missing `manifest.json` on older versions, first check
the selected index path: an atomic index uses `generation.json` to locate its
payload manifest. The new headline does not change index validation or recovery.
Point at an existing index before suggesting a new extraction. Prefer the
explicit path above; `WOODS_DIR` is also supported. Woods `2.0.0` includes
`WOODS_OUTPUT` after those two choices, so verify the installed
version's configuration guide before relying on that fallback.

Then reconnect through the MCP client and call `woods_status`. Use client-native tool inspection after initialization. Expect 14 packaged Index tools, not all conditional schemas.

For Docker-only bundles, test the configured container command instead, for example `docker compose exec -T app bundle exec woods-mcp /app/tmp/woods`. Use the container path for a container process and a host path only for a host process.

For corrupt pipeline cooldown state, first confirm this is a custom server
with `pipeline_repair` registered; packaged `woods-mcp` does not wire it.
Recovery through `reset_cooldowns` (B-159) is available in Woods `2.0.0.beta3`.
Check the installed version before attempting it and follow the
[corrupt cooldown recovery guide](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#corrupt-pipeline-cooldown-state).

## Missing GraphQL units

Woods 2.0.0 can omit schema classes, resolvers inherited through application
superclasses, and runtime types owned by additional schemas (#558, #562, #563).
The fixes are **unreleased after 2.0.0, planned for 2.1**; check the writer's loaded
revision before expecting them. A supporting writer publishes schema classes as
`graphql_type` with `metadata.graphql_kind: "schema"`, and combines the runtime
type inventories of every current application schema. Confirm that the application
boots, then run full extraction and validate to establish a complete upgrade baseline.

A schema introspection failure stops publication and leaves the prior generation
active. Fix the named schema error and retry; do not treat a partial boot or an
empty type inventory as proof that a query root was removed. Missing embeddings
cannot explain an absent structural unit. Follow the
[GraphQL extraction contract](https://github.com/lost-in-the/woods/blob/main/docs/EXTRACTOR_REFERENCE.md#graphqlextractor)
for source fallback, runtime-only removal and reference-coverage limits.

## Deferred refresh hooks

Expanded hook coverage and `woods:hook_refresh` (#408) are available in Woods
`2.0.0.beta3`. Verify the installed task through the configured host/container
command before diagnosing this plugin's queue. Read `<output>/hook.log` and
`hook-pending/`; status 75 means an active daemon deferred work, not that it was
consumed. Fix task availability, boot/publication failures or a stalled command,
then retry with the same output and command prefix. Preserve pending events.
For mkdir fallback locks, inspect the recorded owner PID before manual removal.
The concurrent dead-owner recovery fix is included in plugin `2.3.36`.
If competing hooks leave an empty lock without a drain, preserve the queued
events and follow the canonical recovery guide below.
A Docker timeout does not prove the application process stopped. Prefer a
resident watcher for sustained edits and follow the
[canonical retry guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#hooks-for-agent-sessions).

## Partial dependency answers

Traversal budgets (`max_nodes`/`max_edges`, #311) are available in Woods `2.0.0.beta3`.
Check the installed gem version and connected tool schema before
using them; installing this plugin does not upgrade the gem. On a supporting
server, `partial`/`partial_reason` means the walk stopped early, independently
of page truncation. Do not claim an exhaustive blast radius or treat empty
deps as proof of a leaf. Narrow depth/types/via or increase a supported budget;
paging alone only visits the discovered prefix. See the
[budget contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#dependency-traversal-budgets).

On a reviewed post-2.0 writer containing the unreleased reference expansion,
missing/incompatible reference-cache state requires a full extraction before
incremental maintenance resumes. Check the loaded revision, not VERSION alone.
Increasing `max_nodes` cannot recover edges the writer never recorded. Follow the
[baseline diagnostic](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md#source-reference-baseline-needs-a-full-extraction)
and preserve pending work. This plugin does not add extraction capabilities.

## 4. Check semantic retrieval

Do not treat structural `ready: true` or bootstrap `hydrated` as proof that
embeddings exist. Check the installed reader's capabilities: builds with #549
expose `woods_status.retriever.corpus`, including locally known vector and
metadata record counts by type. Missing fields or `null` counts mean unknown,
not zero. Counts include chunks and do not certify complete unit coverage.
When both stores are known empty, supporting readers return `empty_index` with
embed or explicit lexical-mode guidance. Follow the
[corpus diagnostic contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#semantic-corpus-diagnostics).
Older readers need direct embedding-artifact checks; installing this plugin
does not update the serving gem. Keep reader revision and index writer version
separate when comparing results.

Configured retrieval defaults (#446) are available in Woods `2.0.0.beta3`. For an installed
version that supports them, an omitted tool budget uses the serving retriever's
configured default; an explicit budget overrides it. Standalone MCP does not
inherit the host initializer's token setting from the embedding snapshot.
Do not tune relevance with similarity_threshold: it is inert and deprecated.
Use query/type/scope selection and inspect ranking evidence instead. See
[retrieval tuning](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#tuning).

Native embedding completeness checks (#442/#444) are available in Woods `2.0.0.beta3`;
confirm the installed version first. If embedding reports `Embedding input
incomplete`, repair the named published extraction artifact or rebuild extraction
before retrying. Do not use `WOODS_ALLOW_PURGE=1` to bypass an integrity failure;
it only permits intentional mass deletion. Source-empty units deliberately retain
metadata without vectors. See the canonical
[input-integrity guide](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#input-integrity-and-source-empty-units).

Only diagnose this layer when structural tools work and `codebase_retrieve` fails. If a no-provider message recommends only embeddings or `search`, check the lexical capability below: beta3 supports explicit `WOODS_RETRIEVAL_MODE=lexical` even though that error omits it. Put the setting in the MCP process environment and restart; never silently change retrieval modes. First check `woods_status.retriever.mode`. For lexical mode, validate the published extraction index and follow the capability check below. For semantic mode, check the configured provider/model/vector store, provider reachability, and whether `woods:embed` completed.

- OpenAI: verify the key exists without printing it.
- Ollama: verify the service and configured model locally.
- Stale vectors or missing same-name types: follow the installed version's upgrade guide and run the documented embed refresh; do not rename public identifiers or edit vector IDs by hand.
- Dimension mismatch: rebuild into a store matching the configured model; do not suppress the preflight.
- Purge guard: back up and inspect the proposed deletion; never set `WOODS_ALLOW_PURGE` without explicit approval.

For an unsupported OpenAI `dimensions` option or stale vectors after changing
provider width/endpoint, check the installed revision: the embedding request and
cache consistency fix (#586) is unreleased after Woods `2.0.0`. It distinguishes
stored vector width from explicit reduction, omits unsupported width parameters
for fixed-width ada, and scopes embedding cache entries to provider configuration.
Follow the installed version's [embedding options and cache guidance](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#embedding-options);
never bypass a width refusal or infer this capability from the plugin version.

For metadata appearing in another index or worktree, compare `WOODS_OUTPUT`,
`config.output_dir`, and any explicit `metadata_store_options[:database]`.
The default SQLite path following `WOODS_OUTPUT` during embedding (B-156) is
available in Woods `2.0.0.beta3`; check the installed version before relying on it.
An explicit database path still wins. See the
[SQLite path contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#sqlite-metadata)
for isolation and upgrade steps.

## 5. Check Console separately

For repeated missing-token boot warnings on a stdio-only host, check whether
its installed version supports `console_mcp_http_enabled = false` before
suggesting it; this option is available in Woods `2.0.0.beta3`. The default
preserves HTTP enablement, so selecting stdio as a client alone does not
suppress HTTP token validation. Never disable authentication on an HTTP
endpoint to silence this warning.

Console failures are live Rails/config/security failures, not Index failures. Verify authorized environment, Rails boot, `WOODS_CONSOLE_CONFIG` or direct `cwd`, blocked-table policy, credentials, and stderr.

For stdio parse errors or response mismatches during tool calls, check for Rails
logs on stdout. Through Woods `2.0.0.beta4`, stdout is restored after boot;
configure the Console process's logger to use stderr or a file. Runtime stdout
isolation is included in Woods `2.0.0`: verify a patched installed revision
before relying on it. Prefer `bundle exec rake woods:console`; direct Rails
runner invocation cannot capture output already emitted during Rails boot.
See the [Console logging diagnosis](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md#rails-logs-break-mcp-protocol).

For MySQL SQL refusals, inspect the executing session's `sql_mode` and the installed version's Console guide. Do not change quote modes to bypass a security refusal.

For SQLite SQL refusals on `2.0.0.beta4` or a reviewed revision containing its Console corrections, consult the installed Console guide for supported identifier and table-reference syntax. Simplify the query to supported syntax; never relax the blocked-table or function policy. These builds also check resolved default scopes and scan normalized response values. Confirm a patched gem is published before recommending it, and check the installed version’s canonical Console guide; do not infer release availability from this plugin.

Nine tools are normal. Eleven appear only with `console_embedded_read_tools`. Do not chase Tier 2/3 or `console_eval`; they do not register in supported packaged modes. Never work around redaction, credential scanning, SQL validation, or a block.

## Report

Return the first failing layer, commands/evidence, root-cause hypothesis, whether any file changed, and the smallest next action. If a fix is requested, change one thing and rerun the failing check before proceeding.

Canonical guide: [TROUBLESHOOTING.md](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md).

## SQLite metadata and typed semantic results

If a SQLite-backed index retains deleted units after embedding, or a `:local`
reader returns no type-filtered semantic matches after restart, record the exact
embedding and reader revisions. The SQLite reconciliation and metadata hydration
fix (#572) is unreleased after Woods `2.0.0`. With that fix, a full embed removes
stale SQLite rows; restarting the reader restores vector type filters from the
configured SQLite metadata store. Incremental empty-input and bulk-deletion
guards still apply. See the canonical
[SQLite metadata configuration](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#sqlite-metadata).

## Lexical retrieval capability check

Lexical retrieval is available from `2.0.0.beta3`. Before proposing it, verify the installed gem
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

## Source-content freshness (Woods 2.0.0.beta3; #405)

Check installed-version support before using `woods-extract` or the optional
`woods_status.source_check` argument. With support, inspect
`index.source_freshness`: `current`, `drifted` or `unknown`. Repeated edits to an
already-dirty file can leave the porcelain fingerprint unchanged. A quick scan
limit may justify one `source_check: "deep"`; unavailable source/private keys or
unproved boot/consumer coverage remain unknown. A fresh `bundle exec woods-extract full`
inside the application environment establishes preboot evidence. Never publish
`.source-inputs.key`, silently change its permissions, or delete queued edits to
hide diagnostics. Follow [source freshness](https://github.com/lost-in-the/woods/blob/main/docs/SOURCE_FRESHNESS.md).

### Source paths with invalid filename bytes (unreleased after Woods 2.0.0; #573)

Check the writer revision before relying on this handling. An
`undecodable_source_path` diagnostic means Woods could not represent a filename
as UTF-8; source freshness remains unknown and reference publication preserves
the previous generation. Inspect the escaped path, correct the filename in the
application checkout, and retry extraction. Do not fabricate current freshness
or discard the prior index. Valid Unicode filenames remain supported, including
under a C locale. See [source freshness](https://github.com/lost-in-the/woods/blob/main/docs/SOURCE_FRESHNESS.md).

### Surviving-file ownership moves (unreleased after Woods 2.0.0; #574)

Check the writer revision before relying on this correction. A moved class can
keep its identity when a complete Rails boot proves its unique new owner. For
file-derived identities, submit both changed paths together so extraction can
prove that the surviving old file released the identity. Retry the complete
batch after resolving boot or extraction failures; do not disable collision
checks or delete the previous generation to force a move through. Simultaneous
owners still fail. See [incremental extraction](https://github.com/lost-in-the/woods/blob/main/docs/INCREMENTAL_EXTRACTION.md).

### Once-loader naming (unreleased after Woods 2.0.0; #579)

Check the loaded writer revision when a declared library child is misnamed as
its enclosing wrapper. Writers with this fix use the owning Rails loader,
including `config.autoload_lib_once` naming rules. Run one full extraction after
upgrading an affected index before resuming incremental maintenance. This does
not combine unmanaged files that reopen one namespace or invent a class for a
VERSION-only file. Preserve collision diagnostics for those cases. See
[extractor naming](https://github.com/lost-in-the/woods/blob/main/docs/EXTRACTOR_REFERENCE.md#identifier-naming-source-derived-units).

## Compact evidence capability check

Inspect the connected server's installed tool schemas before using `evidence` on
`lookup` or `codebase_retrieve`; older releases do not provide these controls.
When available, explicit `compact` selects complete published source spans and
`outline` lists declared APIs. Read omission/provenance fields and follow the
returned typed, SHA-guarded `full_evidence` lookup for verification. Published-unit
coordinates are not physical file offsets; unknown generation remains unknown.
Keep full-source access available. See the canonical
[evidence contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines).

## Explicit edit adapters (Woods 2.0.0.beta3; #409)

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
`WOODS_HOOK_CONTEXT_ENABLED=1`; this capability is available in Woods `2.0.0.beta3` and the
plugin does not upgrade the gem. Context and refresh opt-ins are independent;
`WOODS_HOOKS_DISABLED=1` disables both. Native Claude context is synchronous and
bounded, with served-generation and pre-refresh/unknown labels. Verify candidate
dependents and suggested tests manually; silence is not no impact. Do not clear
refresh queues when optional hints time out. See the canonical
[context guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#optional-bounded-context-hints)
for output/time limits, container root mapping and emitted-hint suppression.

### Obsidian destination conflicts

Destination ownership preflight (#441) is available in Woods `2.0.0.beta3`; first check
the installed Woods version and
its matching guide. On versions with this check, `refusing <path>: unmanaged or modified destination`
means the export preserved a conflicting note, setting, or sidecar and skipped the stale-note sweep.
A `.woods-vault` sentinel or force-purge flag does not authorize overwriting it. Inspect and back up
the named file before moving it aside, or choose a new export directory. Older vaults can adopt
byte-identical generated assets into `_woods/ownership.json`; changed legacy sidecars may need this
manual recovery. Never fabricate ownership receipts or remove personal files to silence the error.
See the installed version's `docs/OBSIDIAN_INTEGRATION.md` for the exact safety contract.
