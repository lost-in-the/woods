# Troubleshooting Woods

This guide covers the most common problems encountered when installing, extracting, and using Woods. Each section follows the pattern: **symptom → cause → fix**.

---

## Quick Reference

| Error message | Cause | Fix |
|---------------|-------|-----|
| `Could not resolve a published Woods index` (older versions: `No manifest.json found`) | Wrong index path or unresolved published generation | Select the existing index using a path visible to the server process; see [startup diagnostics](#index-cannot-be-resolved-at-startup) |
| `uninitialized constant Rails` | Not running inside Rails app | Run via `bundle exec rake` in Rails root |
| `type "vector" does not exist` | pgvector not installed | `CREATE EXTENSION vector` in PostgreSQL |
| `Connection refused (localhost:11434)` | Ollama not running | `ollama serve` |
| `Connection refused (localhost:6333)` | Qdrant not running | Start Qdrant container |
| Qdrant private/loopback URL rejected | SSRF guard is working | Add `allow_private_hosts: true` only for a deliberately trusted endpoint |
| Missing `console_sql` / `console_query` | Read tools disabled | Enable `console_embedded_read_tools` |
| `database is locked` | SQLite concurrent access | Run one extraction at a time |
| `Dimension mismatch` | Embedding model changed | Full re-index: extract + embed |
| `401 Unauthorized` (Notion) | Invalid API token | Check `NOTION_API_TOKEN` env var |
| `404 Not Found` (Notion) | Wrong database ID | Verify ID + integration access |
| `broken pipe` (Docker console) | Missing `-i` flag | Add `-i` to docker exec args |
| `No such container` | Wrong container name | Check with `docker ps --format '{{.Names}}'` |
| `JSON parse errors` (MCP) | Rails boot noise on stdout | Remove `puts` calls from initializers |
| Query timeout | Large table, no scope | Add scope conditions to narrow results |
| `Extraction failed for …; the previous generation remains active` | A consumer handled a source error during incremental extraction or refresh (included in Woods `2.0.0`) | Fix the logged source error and retry the [complete batch](INCREMENTAL_EXTRACTION.md#handled-source-errors-and-retry); watch keeps it pending |
| Empty extraction output | `eager_load!` failure | Check for `NameError` in boot output |
| Git metadata missing | Shallow clone in CI | Use `fetch-depth: 0` for complete history |
| Parallel tool calls all fail | MCP client batches calls | Send calls sequentially, validate params first |
| HTTP transport refuses to start on `0.0.0.0` | Missing bearer token | Set `WOODS_MCP_HTTP_TOKEN=…` or bind loopback only |
| HTTP transport returns `403 Origin not allowed` | Origin header not in allow-list | Set `WOODS_MCP_HTTP_ALLOWED_ORIGINS="https://example.com"` (comma-separated; default is loopback-only) |
| Tool returns `error_code: :not_configured` | Feature flag or credential not set | Check `config_key` in `_meta` and the linked `doc_link` |
| Tool returns `error_code: :rate_limited` | `PipelineGuard` 5-min cooldown hit | Wait `retry_after_seconds` from `_meta`, then retry |

### Source-reference baseline needs a full extraction

**Unreleased after 2.0.0; planned for 2.1.** The related initial diagnostic is
`Source-reference baseline is missing or incompatible`. Both mean the writer
cannot safely reuse its reference cache or verify the source consumed by retained
units. It can follow an older-index upgrade, missing cache artifacts, or source
changes omitted from the refresh batch. Confirm the loaded gem revision and
output directory, then follow the [full baseline rebuild](INCREMENTAL_EXTRACTION.md#source-reference-baseline-and-upgrades).
The failed operation leaves the published generation unchanged. Preserve pending
watcher work; increasing traversal budgets cannot repair extraction coverage.

### First-Pass Diagnostics

For a single-call health snapshot, call the Index Server's `woods_status` tool. It reports:

- Extraction freshness (last run time, unit count, index version)
- Overall readiness plus index, watch, retriever, and bootstrap state (`ready`, `index`, `watch`, `retriever`, `bootstrap` sections)
- Which optional features are configured (embedding provider, Notion, session tracer)
- Per-feature config-key hints for anything missing
- `server.update`: the installed gem version, the newest version the process knows about (the latest published release, or the installed version itself when the install is ahead of the registry or the check could not run), and an `update_available` flag (a best-effort RubyGems check, cached 24h; disable with `WOODS_NO_UPDATE_CHECK=1`)

Agents cold-connecting to a server should call `woods_status` before any other tool, it eliminates most "why is this empty?" guesswork.

If `woods:validate` warns that the manifest writer and reader major versions
differ, run full extraction using the intended gem and follow the upgrade guide.
An invalid `woods_version` warns without failing structural validation; a missing
or null value is normal for older indexes. Compare `index.woods_version` with
`server.version` in MCP status; never infer an unknown writer from the reader's
version. See [manifest writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance).

If a tool call fails with **"Tool not found: … not available in the installed Woods v…"**, the client is asking for a tool a newer gem provides. Run `bundle update woods` and reconnect the MCP server, then retry.

### Watcher startup or planned restart fails

Managed `woods-watch` startup is **included in Woods `2.0.0`**; record the
loaded version/path and revision, then verify executable and generator help.
If changing an initializer stops every Foreman process, replace a bare
`woods:watch` entry with the [managed setup](WATCH_DAEMON.md#managed-development-startup).

Read launcher logs and `woods_status` supervision records separately from daemon
liveness and index freshness. `retrying` means the last generation remains usable
while boot is retried. A parked ownership/protocol conflict requires correcting
the selected owner or installed command and restarting that owner; do not delete
claim files or kill PIDs taken from status. No index-visible record exists before
the first boot resolves the application's output directory.

Unset `WOODS_WATCH_IDLE_TIMEOUT` in managed modes. If the boot deadline is reached,
diagnose Bundler/initializer startup before increasing `--boot-timeout`; a valid
long extraction has a separate readiness state and is not bounded by that clock.
If setup created a Procfile but normal `bin/dev` still only launches Rails, choose
Puma or explicitly run the selected Foreman command. The generator never rewrites
`bin/dev` or starts services during preview.

If installation reports a pending transaction, use `woods:watch --operation
recover` through the Rails generator, initially with `--pretend`; see
[owned setup recovery](WATCH_DAEMON.md#ownership-updates-and-removal). That Rails
command boots the application first. For broken initializers use the documented
direct bundled Ruby helper, which does not boot Rails or require task discovery.
Both refuse to overwrite intervening edits. A Puma setup refusal for
`config/puma/development.rb` means the default
configuration would bypass the generated plugin; select an external/Foreman
arrangement instead of installing an inactive directive.

### Semantic graph validation errors

In development versions containing #413, `woods:validate` rejects graphs that
parse as JSON but disagree with their indexes. Errors name the section and
identity, for example `reverse["http_api"]: missing "Order"`, a duplicate typed
variant, or an indexed unit absent from `nodes`. This is included in Woods
`2.0.0`; check the installed gem before expecting these diagnostics.

Keep the failing generation and report the exact errors. Run a full extraction
in a fresh application process with the intended bundle, then validate again.
Do not edit derived reverse/file/type indexes to silence the check. If a fresh
full run still fails, report the invariant and source units as an extraction bug.
The checker never repairs or republishes the index itself.

An unresolved target is legal; missing both a node and its unit cannot be
classified as external versus accidentally omitted from current metadata alone.
A green report also does not prove that an indexed relationship executes at
runtime. See [the checked invariants and limitations](INDEX_LAYOUT.md#semantic-graph-validation).

### Corrupt pipeline cooldown state

In a custom Index MCP server configured with an `operator` and
`pipeline_guard`, a corrupt `pipeline_guard.json` denies full pipeline runs
until repaired. The packaged `woods-mcp` executable does not expose pipeline
operations; confirm the connected server's tools before using this recovery.

For versions containing B-159, call `pipeline_repair` with
`{"action":"reset_cooldowns"}` to replace malformed JSON, non-object JSON, or an
empty guard file with an empty state object under the guard's file lock. This
explicit action clears the extraction and embedding cooldowns; subsequent runs
can start immediately. The direct Ruby equivalent is `guard.reset!(:all)`.
Scoped resets leave corrupt state untouched. Valid state keeps any unrelated
operation entries, and missing state remains a no-op without creating a file.
A permission failure must be corrected before repair can succeed.

This recovery is included in Woods `2.0.0`; check the installed version.
Older versions report corrupt state as nothing to repair. Stop pipeline writers,
back up the configured guard state's `pipeline_guard.json`, and remove only that
file before restarting, or upgrade to a version containing the fix.

## Extraction Problems

### Extraction produces empty or incomplete output

**Symptom:** Running `rake woods:extract` completes without errors but produces fewer units than expected, or only some model types appear.

**Cause:** `eager_load!` failed silently partway through loading your application. Zeitwerk processes directories alphabetically, if a directory early in the alphabet (e.g., `app/graphql/`) fails to load due to a missing gem, Zeitwerk aborts that pass and never reaches `app/models/`. Woods detects this and falls back to per-directory loading, but some units may still be missing.

**Fix:**

1. Check for `NameError` or `LoadError` in the extraction output:

```bash
bundle exec rake woods:extract 2>&1 | grep -i "error\|uninitialized"
```

2. Either install the missing gem(s) referenced in the error, or exclude the problem directory from eager loading:

```ruby
# config/application.rb
config.eager_load_paths -= [Rails.root.join('app/graphql')]
```

3. Re-run extraction after resolving the load issue.

---

### Extraction fails with "Cannot find Rails" or "uninitialized constant"

**Symptom:** Running a rake task fails immediately with `NameError: uninitialized constant Rails` or a similar error about ActiveRecord, ApplicationRecord, or other Rails constants.

**Cause:** Extraction requires a booted Rails environment. Woods uses runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs), these APIs do not exist outside a running Rails app.

**Fix:** Always run extraction rake tasks inside your Rails app:

```bash
# Correct: run from Rails app root
bundle exec rake woods:extract

# Docker: run inside container
docker compose exec app bundle exec rake woods:extract
```

Woods cannot extract from source files alone. It is not a static analysis tool.

---

### Extraction is very slow

**Symptom:** A full extraction is much slower than this application's established baseline.

**Cause:** Two common causes, a very large codebase (500+ models), or framework source extraction enabled on an app with many gems.

**Fix:**

Disable framework source extraction if you don't need Rails/gem internals:

```ruby
config.include_framework_sources = false
```

For subsequent runs, use incremental mode instead of full extraction:

```bash
bundle exec rake woods:incremental
```

Incremental extraction dispatches the selected changed paths, including affected
concern consumers and whole-app extractors whose trigger paths changed. The default
Git range is `HEAD~1`; pass an explicit range or `CHANGED_FILES` for other batches.
It can reduce extraction work, but Rails boot, graph rebuilding, and publication
still contribute to runtime. Measure the improvement in your application; Woods
does not guarantee a speedup. See the [incremental contract](INCREMENTAL_EXTRACTION.md).

---

### Some extractor types are not appearing in output

**Symptom:** You expect state machines, events, decorators, or other unit types but they don't appear in the output directory.

**Cause:** All 35 extractors always run during extraction, there is no opt-in/opt-out mechanism. If a unit type is missing, it means the extractor found nothing to extract. Common reasons:

- The expected directory doesn't exist (e.g., no `app/decorators/` for decorators)
- The required gem isn't installed (e.g., `aasm` or `state_machines` for state machine extraction)
- The code doesn't match the extractor's expected patterns

**Fix:** Verify the code exists and matches what the extractor looks for:

```bash
# Check if the directory exists
ls app/decorators/ app/state_machines/ 2>/dev/null

# Check extraction output for that type
ls tmp/woods/decorators/ tmp/woods/state_machines/ 2>/dev/null
```

Note: `config.extractors` does not control anything today, it's accepted for forward compatibility only and is not consulted by extraction or retrieval. See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for what each extractor looks for.

---

### Incremental extraction doesn't seem to update routes, middleware, or engines

**Symptom:** After changing your routes file or adding a middleware, `rake woods:incremental` doesn't seem to update those units.

**Cause:** Nine unit types don't map to individual files, so they can't be diffed per file: `route`, `middleware`, `engine`, `scheduled_job`, `state_machine`, `factory`, `event`, `database_view`, and `rails_source`. Incremental mode still updates them, it re-runs the whole extractor when a specific trigger path changes, instead of skipping the type:

| Type | Trigger path |
|------|--------------|
| `route` | `config/routes.rb` |
| `engine` | `config/routes.rb`, `Gemfile.lock` |
| `middleware` | `config/application.rb`, `Gemfile.lock`, any file under `config/initializers`/`config/environments` |
| `scheduled_job` | `config/recurring.yml`, `config/sidekiq_cron.yml`, `config/schedule.rb` |
| `state_machine` | any `.rb` change under the scanned model directories |
| `factory` | any `.rb` change under `spec/factories`/`test/factories` |
| `event` | any `.rb` change under `app/` |
| `database_view` | any `.sql` change under `db/views` |
| `rails_source` | `Gemfile.lock` (only when `include_framework_sources` is enabled) |

If your change doesn't match one of these trigger paths, the type genuinely wasn't updated, that's the actual bug to chase, not a documented limitation.

**Fix:** Route and event changes that match the triggers above need no manual
full extraction; `woods:incremental` and `woods:watch` rerun their whole-app
extractors. If `woods:validate` still reports drift outside the trigger
contract, use a full extraction as the recovery step:

```bash
bundle exec rake woods:extract
```

---

### External dependency targets lose dependents after incremental extraction

**Symptom:** An external target such as `http_api` loses previously indexed
dependents after an incremental run.

**Cause:** Versions affected by B-193 can split symbolic and string target
identities when restoring and updating the graph.

**Fix:** Check whether the installed version includes B-193; this fix is
included in Woods `2.0.0`. After upgrading to a version containing the fix, run
`bundle exec rake woods:extract` once to rebuild lost reverse dependencies.
Loading an already damaged graph does not restore discarded entries. See the
[incremental graph contract](INCREMENTAL_EXTRACTION.md#the-contract).

### Git metadata is missing or shows zeros

**Symptom:** Per-unit `metadata.git` is absent, or an older Woods version reports
most files as `change_frequency: new` in a shallow CI checkout.

**Cause:** A shallow clone truncates HEAD ancestry. The shallow-checkout guard is
included in Woods `2.0.0`: Woods omits git enrichment and warns once,
rather than treating the truncated history as complete. If repository depth
cannot be verified, enrichment is also omitted; check git access and version.

**Fix:** Fetch complete history (`git fetch --unshallow` for an existing shallow
clone), then run full extraction to replace retained metadata:

```yaml
# .github/workflows/index.yml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

Two commits can suffice for an incremental diff, but do not establish the full
ancestry needed for churn metadata.

### Git executable is missing from the extraction environment

**Symptom:** Extraction logs `Git history unavailable: git executable was not
found in PATH`, and newly extracted units have no `metadata.git`. Older builds
can omit this enrichment silently when the executable is missing.

**Fix:** Run `git --version` in the same container and environment that runs
extraction. Install Git 2.31 or newer there, ensure its executable is on `PATH`,
then run full `woods:extract` to refresh every unit's history. A working Git
installation on the host does not provide Git inside an application container.

Extraction continues without inventing zero-commit history. The warning appears
once per extractor instance when the application has a `.git` entry or an
explicit `WOODS_GIT_DIR`/`GIT_DIR` setting. A source archive with neither remains
supported and quiet. `GIT_BRANCH`/`GIT_SHA` provenance fallback is unchanged;
those values identify a build but cannot supply per-file history.

This diagnostic is emitted during extraction. `woods_status.ready` and a
manifest Git SHA do not establish that per-unit history was available, and
`recent_changes` returning no results does not prove no files changed.

---

### Git enrichment warns that history could not be read completely

Woods 2.0 uses an explicit merge-diff mode requiring **Git 2.31 or newer**.
First confirm the installed Woods version.
Check `git --version` inside the same container/process environment as extraction,
and upgrade git if it is older. On a supported version, check that the application's
`HEAD` and object store can be read using the same `WOODS_GIT_DIR` setting.

A failed or incomplete history stream is discarded as a whole; extraction continues
without that enrichment, rather than publishing partial or zero-count history.
Previously retained incremental units can still carry older metadata. After fixing
git, run a full extraction to refresh every unit. See the
[history contract](CONFIGURATION_REFERENCE.md#git-enrichment-history) for merge
counting and upgrade compatibility.

---

### Every unit reports `commit_count: 0` and `change_frequency: "new"`

**Symptom:** Not a few units, all of them, in an application whose files clearly
have history. `volatile_dependencies` comes back empty at the same time.

**Cause:** git ran but could not resolve any ref. The usual shape is a
containerized linked worktree: `GIT_DIR` points at the worktree's *private*
git directory, `git rev-parse --git-dir` succeeds, and every ref lookup fails,
because that private directory reaches the shared object store through a
relative `commondir` pointer that resolves outside the mount. `git log` then
exits 0 with no output, and zero commits is indistinguishable from a file that
was never committed.

Woods now requires `git rev-parse HEAD` to succeed before enriching anything.
When it does not, the git keys are omitted from every unit, provenance records
`"unknown"`, and one warning names git's own reason. Absent keys mean "not
known"; they never mean "brand new".

**Fix:** Restore access to both the worktree-specific Git directory and the
shared objects and refs using the mount layouts below, then run a full
`woods:extract` to replace retained metadata.

### Git directory mounts for linked worktrees

`WOODS_GIT_DIR` is passed directly to Git's `--git-dir`. It selects that
directory's `HEAD` for manifest provenance, per-file history, and incremental
diff ranges. **For a linked worktree, pointing it at the shared `.git` root
selects the primary checkout's HEAD.** A successful Git command alone does
not prove Woods is reading the intended branch.

First inspect Git metadata on the host, from the intended worktree:

```bash
git -C /path/to/worktree rev-parse --absolute-git-dir
# Example: /path/to/repo/.git/worktrees/wt
git -C /path/to/worktree rev-parse --path-format=absolute --git-common-dir
# Example: /path/to/repo/.git
git -C /path/to/worktree rev-parse --abbrev-ref HEAD
git -C /path/to/worktree rev-parse HEAD
```

The worktree ID in this example is `wt`. Use the ID returned by Git metadata;
it need not match the branch name. Choose one of these layouts:

- **Same-path mount:** mount the complete shared directory read-only at its
  original absolute path (`/path/to/repo/.git:/path/to/repo/.git:ro`). With the
  application's existing `.git` pointer resolvable, leave `WOODS_GIT_DIR`
  unset and remove conflicting Git-directory overrides from the environment.
- **Relocated mount:** mount that complete directory read-only at a new path
  (`/path/to/repo/.git:/mounted-common:ro`), including `objects`, `refs`, and
  `worktrees`. Select the worktree-specific directory inside it:

  ```bash
  WOODS_GIT_DIR=/mounted-common/worktrees/wt bundle exec rake woods:extract
  ```

Mounting only the private worktree directory can leave its `commondir` pointer
without access to shared objects and refs. Git's own environment variables are
inherited by the subprocess; check any existing `GIT_DIR` and `GIT_COMMON_DIR`
settings when diagnosing the effective layout. The complete layouts above
preserve both worktree identity and shared storage.

In the extraction container, verify the relocated selection against the host
branch and exact SHA before extracting (replace `/app` and `wt` as needed):

```bash
git --git-dir=/mounted-common/worktrees/wt --work-tree=/app -C /app rev-parse --abbrev-ref HEAD
git --git-dir=/mounted-common/worktrees/wt --work-tree=/app -C /app rev-parse HEAD
```

After fixing the selection, run full `woods:extract` and verify the published
manifest. Incremental extraction can retain older per-file Git metadata.
A commit alone does not necessarily trigger the source-file watcher; run a
full extraction when current history and provenance are required.

---

### `woods:incremental` exits 1 with "could not resolve the git diff range"

**Symptom:** A CI job fails with `ERROR: could not resolve the git diff range "..."` instead of indexing.

**Cause:** The range git was asked to diff does not resolve in the checkout: a GitLab `CI_COMMIT_BEFORE_SHA` of all zeros (new branch), a GitHub base ref that was never fetched, a shallow clone with no `HEAD~1`, or a typo'd revision. This used to read as "no relevant files changed" and the task exited 0 while the sync never ran; it now fails closed, because a green job hiding a skipped sync lets index drift grow unbounded. The one stand-down: a *running* watch daemon maintaining the same index exits 0 with a printed reason, since its start-up catch-up covers the changes. A degraded daemon covers nothing and still exits 1.

**Fix:** Repair or provide the range (fetch the base ref, e.g. `fetch-depth: 2` or more, or correct the CI environment variables), set `CHANGED_FILES` explicitly to bypass range resolution, or run a full extraction:

```bash
bundle exec rake woods:extract
```

Note `WOODS_IGNORE_WATCH=1` removes daemon coverage rather than bypassing the failure — an unresolved range then exits 1. The full exit-behavior table lives in [Incremental Extraction](./INCREMENTAL_EXTRACTION.md#exit-behavior-in-ci-chains).

An image with no `git` binary at all reports `git unavailable: …` and takes the same decision — install git in the image, or set `CHANGED_FILES` so git is never consulted.

---

### `woods:embed`, `woods:embed_incremental`, or `woods:notion_sync` exits 1 after printing `Errors: N`

**Symptom:** The task prints its normal summary, reports a non-zero error count, and the job fails.

**Cause:** Per-item failures accumulated during the run — a revoked or rate-limited API key that kept failing after the resilience stack exhausted its retries, a full or unreachable vector store, or a Notion 401/400 on every page. These tasks used to print the count and exit 0, which left CI green while the embedding index or the Notion database drifted stale indefinitely. They now fail like their siblings `woods:unblocked_sync` and `woods:obsidian`, and like the extraction family.

**Fix:** Read the first five errors the task prints — they name the failing units or pages. Then:

- Embedding: check `OPENAI_API_KEY` (or the Ollama endpoint), the provider's rate limits, and free space in the vector store. Re-run `woods:embed_incremental`; the checkpoint means already-embedded units are not paid for twice.
- Notion: check `NOTION_API_TOKEN` and that every database ID in `notion_database_ids` is shared with the integration.

A partial run is not rolled back: whatever succeeded is durable, and re-running after the fix converges.

---

### Extraction exits non-zero after "Could not publish generation"

**Symptom:** `woods:extract`, `woods:incremental`, `woods:refresh`, or
`woods:extract_framework` raises `Woods::ExtractionError` after writing its
payload, with a message saying that the previous generation remains active.

**Cause:** Woods writes a complete candidate payload first and commits it by
atomically updating `generation.json` last. The marker write failed (commonly
permissions, a read-only mount, no free space, or an unhealthy filesystem), so
readers cannot safely discover the candidate payload. One-shot tasks fail
instead of printing a false success; existing readers continue serving the
previous complete generation.

**Fix:** Correct the filesystem or mount problem named in the exception, then
rerun the same task. Do not edit `generation.json` by hand or point readers at
the unreachable payload. A resident `woods:watch` process handles the same
failure differently: it reports `degraded`, carries the changed paths, and
retries after a later filesystem event.

For the optional embedded `pipeline_extract` tool, a client using the Tasks
extension sees the task become `failed` for this publication refusal on a
revision containing #584 (unreleased after `2.0.0`). A background-start response
alone does not mean extraction completed. The packaged Index Server does not
register this tool.

### Incremental extraction or refresh reports "Extraction failed for ..."

A selected whole-app extractor raised before returning a complete result, or
its initialization failed. On revisions containing #584 (unreleased after
`2.0.0`), a successful sibling extractor cannot turn that failed batch into a
successful publication. Readers retain the prior generation. Inspect the
earlier log line naming the failed extractor, fix its cause, then retry the
complete changed-file list or refresh selection. Preserve the published index;
deleting it does not repair the failing extractor.

---

### `manifest.json` shows the wrong branch (or `git_branch: "unknown"`) in a worktree

**Symptom:** `git_branch` / `git_sha` in `manifest.json` name a different
branch or SHA than the intended worktree, or report `"unknown"`.

**Cause:** An unreachable `.git` file's `gitdir:` pointer prevents Git from
resolving the worktree's HEAD. An override selecting the shared `.git` root
instead resolves the primary checkout's HEAD successfully. That wrong selection
also affects per-file history and HEAD-based incremental ranges.

**Fix:** Follow [Git directory mounts for linked worktrees](#git-directory-mounts-for-linked-worktrees),
compare the selected branch and exact SHA in the extraction environment, then
run a full extraction. Compare the newly published manifest, not a retained
generation. A commit without a source edit may leave the watcher idle.

For a checkout legitimately shipped without `.git` (such as a source tarball),
`GIT_BRANCH` / `GIT_SHA` can supply provenance. They are fallbacks only when
`.git` is absent or Git is unavailable; a present but unresolvable `.git`
reports `"unknown"` instead of substituting stale build arguments.

---

## MCP Server Problems

<a id="no-manifestjson-error-when-starting-the-index-server"></a>

### Index cannot be resolved at startup

**Symptom:** An Index MCP executable exits with `Could not resolve a published Woods index in: /path/to/...` even though extraction completed. This headline is included in Woods `2.0.0`; older versions say `No manifest.json found`. Both mean the selected index could not resolve its manifest, not that an atomic index needs a root manifest.

Embedded Index MCP startup through `IndexReader` also raises an `ArgumentError` with the selected directory and layout guidance when the marker cannot resolve a manifest, including malformed marker shapes such as `[]` or a numeric `payload` (included in Woods `2.0.0`). Earlier builds may expose a raw `TypeError` or `NoMethodError` for those shapes. Inspect the marker and preserve the failing index before attempting recovery.

**Cause:** The selected directory is not the published index root, the published generation cannot be resolved, or the path is not visible to the MCP process. A container path is appropriate for a container process; a host process needs the host-visible path.

**Fix:** Point at the existing index before extracting again. Check the examined directory in the error and the [MCP path precedence](CONFIGURATION_REFERENCE.md#environment-variables). For a host-side launch whose working directory contains `tmp/woods`, for example:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

**Since Woods 2.0, a healthy index may not have `manifest.json` at the output root at all.** Extraction publishes each generation into an immutable `payloads/gen-<N>/` directory and points to it from `generation.json`. Inspect the marker and its payload in the MCP process's filesystem before assuming extraction failed (use the generation named by your marker):

```bash
cat ./tmp/woods/generation.json                    # {"number": 42, "payload": "payloads/gen-42", ...}
ls ./tmp/woods/payloads/gen-42/manifest.json
```

Custom scripts that require a root `dependency_graph.json` have the same failure.
Update their gate using the [filesystem layout contract](INDEX_LAYOUT.md), which
includes Bash/jq and Python readers. An upload must pin and copy one complete
payload before publishing its captured pointer; keep a failed copy unpublished.

`woods-mcp-start` and `IndexReader` resolve this automatically; these commands are for manual inspection. Legacy flat indexes use a root `manifest.json`. If neither layout resolves, check the selected path, pointer, payload and any volume mount. See [DOCKER_SETUP.md](DOCKER_SETUP.md) for container launches.

---

### Index Server exits with `MissingArtifact`

**Symptom:** `woods-mcp` exits 2 with `MissingArtifact: No woods.json found ...`.

**Cause:** Strict mode is enabled (`WOODS_REQUIRE_INDEX=1`) but no embedding index has been written. By default the server boots without `woods.json`, it serves pattern/regex/structural tools and skips semantic search. You only see this error when you've explicitly opted into fail-closed behavior.

**Fix:** Either generate the index so semantic search is available:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed          # writes woods.json + vector dumps
```

…or unset `WOODS_REQUIRE_INDEX` to boot in pattern-only mode. (The older `WOODS_ALLOW_AUTODETECT=1` flag is no longer needed, auto-detect is the default.)

---

### `codebase_retrieve` reports degraded semantic search

**Symptom:** `codebase_retrieve` answers with a tool error carrying `error_code: degraded_index` ("Semantic search is degraded…") instead of results, and never with a silently empty context. `woods_status` shows `bootstrap.status: "degraded"`, often with a `hydration_failures` report.

**Cause:** The retriever is not healthy, and the server refuses to disguise that as "no matches". Two phases are distinguished in the error metadata:

- `phase: "boot"` — a dump failed to hydrate at startup (corrupt or unreadable `vectors.bin` / `metadata.msgpack`), so the affected in-memory store is empty. Before this guidance existed, the server reported a healthy boot and answered every query with empty results as if they were legitimate.
- `phase: "query"` — the metadata store failed while serving (storage outage, permissions). The typed `Woods::Retriever::StoreError` is mapped to the same degraded payload.
- `phase: "reload"` — a `reload` attempt failed (M7). Candidate stores are built off-side from one captured generation marker and one captured promoted-dump identity, and a candidate that cannot hydrate aborts the whole transaction: nothing is swapped, the reader keeps the previous generation, and the old retriever keeps answering queries. The reload tool answers with a `degraded_index` error carrying `phase: "reload"`, the `generation:` still being served, and the `stores:` whose refresh failed; `woods_status` exposes the same condition additively as `bootstrap.reload_failure`. This is distinct from the boot `degraded` state — the old stores are healthy, so `codebase_retrieve` keeps working while the condition is visible.

The `stores:` field names what is affected (`vector`, `metadata`, `graph`) and `reason:` carries the underlying error.

**Fix:**

1. Read `reason:` from the error payload, or call `woods_status` and read `bootstrap.reason` / `bootstrap.hydration_failures`. For a `reload` failure, read `bootstrap.reload_failure` instead — its `generation` field names the generation still being served.
2. For a `boot` failure: confirm the index directory is readable, re-run `bundle exec rake woods:embed` if the dump may be corrupt, then restart the MCP server.
3. For a `query` failure: check the backing metadata store (the SQLite database in the index directory, or your remote vector backend) for availability and permissions.
4. For a `reload` failure: no restart is needed — the server is serving the previous complete generation. Fix the underlying issue the `reason:` names (a corrupt or missing dump usually means re-running `woods:embed`), then invoke `reload` again. A successful reload swaps the new bundle in and clears the condition (`bootstrap.reload_failure` disappears from `woods_status`). Three reasons resolve on their own:
   - `promoted dump changed during reload` — an embed published while the reload was building candidates. Invoke `reload` again once the writer finishes.
   - `index generation moved during reload` — same, for a unit-index publication. Invoke `reload` again.
   - `could not acquire the extraction writer lock` — a writer held the extraction PipelineLock for the whole wait. Invoke `reload` again once the writer finishes. The reload needs write access to the index directory for this lock, same as every writer.

---

### No tools appear in the MCP client

**Symptom:** The MCP client connects but shows no tools, or the server exits immediately.

**Cause:** The server failed to start, typically due to missing gem dependencies or an incorrect working directory.

**Fix:**

1. Check stderr for errors:

```bash
woods-mcp-start ./tmp/woods 2>&1
```

2. Ensure the gem's executables are installed:

```bash
bundle install
which woods-mcp-start
```

3. For the Console Server, run the rake task directly to see error output:

```bash
bundle exec rake woods:console
# Should hang waiting for MCP protocol input: if it exits, check the error
```

---

### A console inventory tool is not listed

**Symptom:** A tool from the 31-schema inventory is absent from `tools/list`.

**Cause:** Supported servers advertise only executable tools: 9 Tier 1 tools by
default, plus SQL/query when explicitly enabled.

**Fix:** Enable `console_embedded_read_tools` for `console_sql` and
`console_query`. Tier 2, Tier 3, and eval remain inventory only.

---

### MCP client shows JSON parse errors

**Symptom:** The MCP client reports protocol errors, malformed JSON, or unexpected tokens.

**Cause:** Rails boot emits output to stdout (OpenTelemetry notices, gem warnings, initializer `puts` calls). The `woods:console` rake task redirects stdout to stderr before Rails boots, but custom initializers that print output before this capture can break the MCP protocol.

**Fix:**

1. Check for `puts` or `print` calls in your `config/initializers/` files that run at boot.
2. Use `Rails.logger` instead of `puts` in initializers.
3. Test by running the rake task and isolating streams:

```bash
bundle exec rake woods:console 2>/dev/null
# MCP protocol output (stdout) should be valid JSON-RPC
```

---

### Parallel tool calls fail together (sibling call failures)

**Symptom:** When an MCP client sends multiple tool calls in parallel and one fails, all sibling calls in the same batch also fail.

**Cause:** This is MCP client behavior, not a server bug. Some clients (including Claude Desktop and Claude Code) batch parallel tool calls into one request. If any call in the batch raises an error, the transport may reject the entire response frame.

**Fix:** There is no server-side fix. Workarounds:

1. **Send one tool call at a time.** If your client supports sequential mode, use it for unreliable calls.
2. **Validate parameters before calling.** Use `search` to confirm identifiers exist before passing them to `dependencies` or `lookup`.
3. **Avoid mixing high-risk and low-risk calls.** A `lookup` with a typo will take down a parallel `search` that would have succeeded.

---

### MCP client disconnects mid-session

**Symptom:** The MCP client reports "server disconnected" or "transport closed" during normal use.

**Cause:** Several possible causes, the server process crashed, the stdio transport pipe was broken, or the client's idle timeout expired.

**Fix:**

1. Check server stderr for crash output.
2. Run the configured command manually from the same `cwd` and inspect stderr. `woods-mcp-start` validates the index before launch but does not restart a crashed server.
3. For Docker setups, ensure the container stays running: `docker compose exec -d app tail -f /dev/null` keeps it alive.

---

### Console queries time out on large tables

**Symptom:** `console_count` or `console_sample` times out with an error mentioning statement timeout.

**Cause:** The default statement timeout is 5000ms (5 seconds). Large tables without a scope condition can exceed this.

**Fix:** Add scope conditions to narrow the result set:

```
console_count(model: "Order", scope: { status: "pending" })
console_sample(model: "Order", scope: { created_at_gteq: "2025-01-01" })
```

Scope keys are flat, Ransack-style predicates (`_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`) suffixed onto a column name, `scope: { created_at: { gte: "..." } }` (a nested hash) is rejected. A plain key with no suffix (`status: "pending"`) is an equality match.

---

## Embedding Problems

### Configuring vector search on MySQL

**Symptom:** You're on MySQL (or Percona / MariaDB / Aurora MySQL) and `config.vector_store = :pgvector` fails at boot, or you can't find a `:mysql` vector adapter in `lib/woods/storage/`.

**Cause:** MySQL has no native vector-search extension equivalent to `pgvector`. Woods does not emulate vector search in MySQL, every vector adapter the gem ships delegates to a real vector engine. Note that being on MySQL only constrains the *vector* choice: Woods keeps its own metadata in SQLite or memory (`metadata_store: :sqlite | :in_memory`), never in your application database, so there is no MySQL metadata adapter to configure. (Native `:mysql` / `:postgresql` metadata adapters are future work, `BACKEND_MATRIX.md` documents the shape they would take.)

**Fix:** Pair the host app with one of the supported external vector backends. Qdrant is the recommended default for self-hosted / Docker stacks:

```ruby
# config/initializers/woods.rb: MySQL host app: vectors go to Qdrant
Woods.configure do |config|
  config.metadata_store = :sqlite   # Woods-internal metadata, not your app DB
  config.vector_store = :qdrant
  config.vector_store_options = {
    url: ENV.fetch("QDRANT_URL", "http://localhost:6333"),
    collection: "woods_units",
    allow_private_hosts: true # explicit opt-in for trusted localhost/private URL
  }
  config.embedding_provider = :openai
  config.embedding_options = { api_key: ENV.fetch("OPENAI_API_KEY") }
end
```

The Postgres equivalent (in-database vectors via pgvector) is shown for contrast:

```ruby
# PostgreSQL host: vectors can live in the same database via pgvector
Woods.configure do |config|
  config.metadata_store = :sqlite
  config.vector_store = :pgvector
  config.vector_store_options = {
    connection: your_pg_connection,   # a PG::Connection to a pgvector-enabled DB
    dimensions: 1536
  }
  config.embedding_provider = :openai
  config.embedding_options = { api_key: ENV.fetch("OPENAI_API_KEY") }
end
```

For local development against a MySQL app, the `:local` preset (`Woods.configure_with_preset(:local)`, in-memory vectors, SQLite metadata, Ollama embeddings) is a reasonable stand-in. It requires the `sqlite3` gem plus a running Ollama service, but does not exercise the production vector engine. Production MySQL stacks should run Qdrant; the `:production` preset (`vector_store: :qdrant`) is the matching starting point.

See [`docs/BACKEND_MATRIX.md`](BACKEND_MATRIX.md#database-compatibility) for the full matrix and the [MySQL + Qdrant section](BACKEND_MATRIX.md#mysql--qdrant-classic-rails) for graph-traversal details (recursive CTEs on 8.0+).

---

### "Dimension mismatch" error when querying embeddings

**Symptom:** `codebase_retrieve` raises an error about vector dimensions not matching.

**Cause:** The embedding model was changed after embeddings were already stored. The existing vectors have a different dimensionality than the current model produces, and the vector store cannot mix them.

**Fix:** Run a full re-index to regenerate all embeddings with the new model:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

Woods detects the dimension mismatch and raises `Woods::MCP::DimensionMismatch` rather than letting it become a runtime error: `rake woods:embed` refuses before embedding anything (comparing the provider's dimension against the width the `woods_vectors` table or Qdrant collection was created with), and the MCP server refuses at boot (comparing against the dump's WVF1 header). The message names both dimensions and the remedy, drop the vector store and re-index.

**A dimension mismatch is never silently tolerated.** If you are getting poor results without seeing this error, the cause is something else.

For an unsupported `dimensions` request or a wrong-width cached vector, compare
the installed embedding and reader revisions as well as the model, endpoint,
and explicit width configuration. The request/cache consistency fix (#586) is
unreleased after `2.0.0`: it separates stored widths from requested reductions,
keeps fixed-width ada requests compatible, and separates embedding cache entries
by provider configuration. See [embedding options](CONFIGURATION_REFERENCE.md#embedding-options)
and [cache identity](CONFIGURATION_REFERENCE.md#retrieval-cache-options). Do not
remove a width guard to accept mismatched vectors.

---

### OpenAI API errors during embedding

**Symptom:** Embedding generation fails with `401 Unauthorized` or `429 Too Many Requests`.

**Cause:** Missing `OPENAI_API_KEY` environment variable (401), or hitting OpenAI rate limits (429).

**Fix:**

For 401, set the API key:

```bash
export OPENAI_API_KEY=sk-...
bundle exec rake woods:embed
```

Or configure it in your initializer:

```ruby
config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
```

For 429, embedding generation is automatically retried with backoff. If rate limits persist, consider batching with smaller codebases or switching to Ollama for local embeddings.

---

### Ollama connection refused

**Symptom:** Embedding generation fails with `Connection refused` pointing to `localhost:11434`.

**Cause:** The Ollama server is not running, or it is running on a different port.

**Fix:**

1. Start Ollama: `ollama serve`
2. Verify the model is available: `ollama list`
3. If using a non-default port, update config:

```ruby
config.embedding_options = { host: 'http://localhost:11434' }
```

---

### Ollama `400 "the input length exceeds the context length"`

**Symptom:** `rake woods:embed` fails with `Ollama API error: 400 {"error":"the input length exceeds the context length"}`. Individual chunks may look smaller than the configured `num_ctx`.

**Cause:** Ollama's `/api/embed` endpoint enforces the model's **native** `context_length`, not the `options.num_ctx` override (see [ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)). For `nomic-embed-text` that's 2048 tokens, regardless of what `num_ctx` is set to. Separately, without the `tokenizers` gem, Woods estimates token counts from character length, which under-counts dense Ruby source, so chunks that look safe by char count still trip the 2048-token ceiling.

**Fix:** Use Woods 2.0 and install the `tokenizers` gem:

```ruby
# Gemfile
gem 'woods', '~> 2.0'
gem 'tokenizers', '~> 0.5'   # exact BERT WordPiece token counting
```

Woods now:

1. Advertises the native context ceiling per model (2048 for `nomic-embed-text`, 8192 for `bge-m3`/`snowflake-arctic-embed2`, etc.) so the chunker sizes inputs correctly.
2. Uses the real BERT tokenizer to verify every chunk, catching the 10–20% gap between char-based estimates and Ollama's internal count.

If you want fewer chunks per unit and have the disk space, switch to a larger-context model:

```ruby
config.embedding_options = {
  model: 'bge-m3',       # 8192 native context, 1024 dims
  host: 'http://localhost:11434'
}
```

Pull the model first (`ollama pull bge-m3`) and **drop the vector index before re-embedding**: the dimension change (768 → 1024) is incompatible with existing vectors. See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the full tradeoff matrix.

---

## Storage Problems

### "pgvector extension not found" in PostgreSQL

**Symptom:** Running migrations or extraction fails with `PG::UndefinedObject: ERROR: type "vector" does not exist`.

**Cause:** The pgvector PostgreSQL extension is not installed in the database.

**Fix:**

```sql
CREATE EXTENSION vector;
```

Then run the Woods pgvector generator if you haven't already:

```bash
bundle exec rails generate woods:pgvector
bundle exec rails db:migrate
```

---

### Qdrant connection refused

**Symptom:** Embedding or retrieval fails with a connection error to port 6333.

**Cause:** The Qdrant server is not running.

**Fix:** Start Qdrant via Docker:

```bash
docker run -p 6333:6333 qdrant/qdrant
```

Or update your `vector_store_options` to point at the correct host/port:

```ruby
config.vector_store_options = {
  url: 'http://localhost:6333',
  collection: 'woods',
  allow_private_hosts: true
}
```

---

### SQLite locking errors under concurrent access

**Symptom:** Extraction or embedding fails with `SQLite3::BusyException: database is locked`.

**Cause:** SQLite does not support concurrent writers. If multiple extraction processes run simultaneously, they contend on the metadata store.

**Fix:** Use one embedding publisher at a time. A pgvector backend can accept
concurrent vector writes, but Woods' SQLite metadata/output artifact still
needs a coordinated publisher. Configure the hosted preset completely:

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end
```

---

## Docker Problems

### Extraction output not visible on the host

**Symptom:** `ls tmp/woods/manifest.json` fails on the host after successful extraction in the container.

**Cause:** The extraction output directory (`tmp/woods/`) inside the container is not volume-mounted to the host.

**Fix:** Add a volume mount to your `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - .:/app    # Full app mount, output lands at ./tmp/woods/
```

Then re-run extraction. Prefer `docker compose exec app bundle exec rake woods:validate` and `woods:stats`; these checks follow the active v2 generation. Host visibility is only required for an optional host-side Index Server.

---

### Console server exits immediately with "broken pipe"

**Symptom:** The MCP client reports a broken pipe or immediate disconnection when using Docker.

**Cause:** Plain `docker exec` lacks `-i`, or Docker Compose allocated its default pseudo-TTY. Either breaks stdio MCP communication.

**Fix:** Use `-T` with Compose (`stdin` remains attached), or `-i` with plain `docker exec`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app",
               "bundle", "exec", "rake", "woods:console"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

---

### "No such container" error

**Symptom:** `docker exec` fails with `Error response from daemon: No such container: my_app_web_1`.

**Cause:** The container name in your `.mcp.json` or `console.yml` doesn't match the actual running container name. Docker Compose generates names following the pattern `<project>-<service>-<index>`.

**Fix:** Find the exact name:

```bash
docker ps --format '{{.Names}}'
```

Update the container name in your configuration to match exactly.

---

### Path confusion: Index Server uses container path

**Symptom:** Index Server starts but fails to load units, or `woods-mcp-start` reports a missing manifest.

**Cause:** The `.mcp.json` is pointing at the container-internal path (e.g., `/app/tmp/woods`) instead of the host path.

**Fix:** Use the host path in `.mcp.json`. With a standard `.:/app` volume mount, the output is at `./tmp/woods` on the host:

```text
"args": ["./tmp/woods"]     ✓ host path
"args": ["/app/tmp/woods"]  ✗ container path. Index Server cannot read this
```

---

## Notion Integration Problems

### 401 Unauthorized from Notion API

**Symptom:** `rake woods:notion_sync` fails with a 401 error.

**Cause:** The Notion API token is missing or invalid.

**Fix:** Set the token via environment variable (takes priority over config):

```bash
export NOTION_API_TOKEN=secret_...
bundle exec rake woods:notion_sync
```

Or configure it in your initializer:

```ruby
config.notion_api_token = ENV['NOTION_API_TOKEN']
```

---

### 404 Not Found from Notion API

**Symptom:** Notion sync fails with a 404 error.

**Cause:** The database ID in `notion_database_ids` doesn't match any database the integration has access to.

**Fix:**

1. Verify the database ID from the Notion URL (the 32-character hex string).
2. Confirm the integration has been added to the database in Notion's share settings.

```ruby
config.notion_database_ids = {
  data_models: 'your-32-char-database-id',
  columns: 'your-other-32-char-database-id'
}
```

---

### 400 Bad Request from Notion API

**Symptom:** Notion sync fails with a 400 error mentioning property names or types.

**Cause:** The Notion database schema doesn't match the expected property structure. This happens when the database was created manually with different property names or types.

**Fix:** Use the Woods-generated database template. Re-create the database or update its properties to match the expected schema. Check the error message for which property name caused the mismatch.

---

### Notion sync is slow but eventually succeeds

**Symptom:** Notion sync takes much longer than expected on large codebases.

**Cause:** The Notion API enforces a 3 requests/second rate limit. `RateLimiter` handles this automatically, but a codebase with hundreds of models will take proportionally longer.

**Behavior:** This is expected and handled automatically. No action needed, the sync will complete.

---

## Units with the same name but different types

After upgrading, run embedding again if semantic results omit a factory or database
view sharing the same name. Current writers distinguish typed storage identities;
public names remain unchanged. Snapshot migration 007 runs automatically and keeps
existing rows, but cannot recover variants lost by older writers. See the
[upgrade guide](UPGRADING_TO_2.md) for storage, flow rebuild, and rollback details.

## Watch exits 75 repeatedly at startup

Check the installed Woods version and its [watch daemon guide](WATCH_DAEMON.md).
Older releases, including `2.0.0.beta2`, can repeatedly request restart when a
boot-captured file is newer than the last index generation. Stop the supervisor,
run one successful `bundle exec rake woods:extract` in the application environment,
then start the standalone `bundle exec rake woods:watch` process again.

With startup snapshot support, a fresh environment boot performs the full
reconciliation automatically. Changes during environment initialization or live
watching still require restart. Do not prepend `environment` to the watch command
or start it inside an already initialized process when relying on this recovery.

## Source freshness is unknown or drifted

Read `woods_status.index.source_freshness.reasons`. Old indexes, an inaccessible
source root/private key, a quick scan limit and an unverified boot boundary are
different causes. Try `source_check: "deep"` for a budget limit; use the fresh
launcher for a new verified baseline. Do not delete pending hook events or alter
key permissions just to suppress a warning. See [source freshness](SOURCE_FRESHNESS.md).
