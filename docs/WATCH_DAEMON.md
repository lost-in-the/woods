# The Watch Daemon (`woods:watch`)

A resident, booted-app process that keeps the index current as files change,
instead of as-fresh-as-the-last-explicit-rake-run.

Background: [#164](https://github.com/lost-in-the/woods/issues/164), phase 2.
The correctness work it stands on is in
[INCREMENTAL_EXTRACTION.md](INCREMENTAL_EXTRACTION.md), a watcher on top of an
incorrect incremental path just delivers wrong answers with lower latency.

> **Development only.** The daemon adds no network listener and no new
> transport. It watches the filesystem and writes to `tmp/woods`. Don't run it
> in production; there is nothing to gain and a booted process to lose.

## Running it

```bash
bundle exec rake woods:watch     # alias: woods:guard
```

```
Watching /app, index at /app/tmp/woods
Ctrl-C to stop.
```

| Environment variable | Default | Meaning |
|---|---|---|
| `WOODS_OUTPUT` | `tmp/woods` | Index directory |
| `WOODS_WATCH_DEBOUNCE` | `0.4` | Seconds of quiet before a batch is considered settled |
| `WOODS_WATCH_FULL_THRESHOLD` | `50` | Actionable changed-file count above which a full extraction replaces incremental |
| `WOODS_WATCH_POLL` | unset | `1` forces the polling backend, set this inside a container watching a bind mount |
| `WOODS_WATCH_POLL_INTERVAL` | `1.0` | Positive, finite seconds of sleep between polling scans; does not select the polling backend |
| `WOODS_WATCH_IDLE_TIMEOUT` | unset | Seconds of quiet after which a dormant daemon exits |
| `WOODS_WATCH_CATCH_UP` | `1` | `0` skips the startup reconciliation |
| `WOODS_WATCH_TRUST_FOREIGN_HOST` | unset | `1` lets a reader trust a fresh foreign-host heartbeat without checking its pid locally; see [cross-host liveness](#cross-host-liveness) |

The raw task needs a supervisor that restarts it after exit `75` (`EX_TEMPFAIL`);
see [Restart triggers](#restart-triggers). Docker restart policies can supply
this. A bare task in Foreman cannot: Foreman shuts down its process group when a
child exits. Use the managed launcher below for native Procfile development.

### Managed development startup

**Unreleased after `2.0.0.beta4` ([#538](https://github.com/lost-in-the/woods/issues/538)).**
Record the installed gem path and Git revision as well as VERSION; a checkout
can have new behavior with the last beta's version. Verify both commands before
using the new setup:

```bash
bundle exec woods-watch --help
bin/rails generate woods:watch --help
```

Choose one lifecycle owner per application index:

| Existing development workflow | Setup |
|---|---|
| Rails/Puma, including a `bin/dev` that just starts Rails | Opt-in `puma` mode; the development Puma master starts one separate extraction process, regardless of worker count. |
| An existing Foreman workflow | `procfile` mode with the exact existing Procfile and selected normal Foreman command. |
| Docker Compose, Grove, or another supervisor | `external` mode returns the raw task command; configure its lifecycle through the existing supervisor. |

For Puma, preview before applying:

```bash
bin/rails generate woods:watch --mode puma --pretend
bin/rails generate woods:watch --mode puma
```

This adds an executable `bin/woods-watch` and an owned directive to
`config/puma.rb`. The directive loads the plugin only when the active Woods gem
contains it. An absent gem or an older version without the plugin leaves Puma
running without a watcher; this also works for Git/path bundles. The adapter
separately enforces Puma's finalized development environment.
Starting a console, task, or production
Puma does not start a watcher. The watcher still uses another Rails process and its associated memory.
Puma installation checks the application's installed Puma version (supported
majors: 6, 7, and 8 on native Unix Ruby) and selects the normal `bin/rails server`
path using `config/puma.rb`. If `config/puma/development.rb` exists, setup refuses
because Puma would choose it first. Custom `-C` configurations need an explicit
external/Foreman arrangement; this generator does not discover or rewrite them.

For an existing Foreman arrangement, select the command you will actually use:

```bash
bin/rails generate woods:watch --mode procfile --procfile Procfile.dev \
  --manager-command 'foreman start -f Procfile.dev' --pretend
```

Repeat without `--pretend` to apply. Preflight checks task discovery and Foreman
availability with bounded commands; it does not start services. Installation
preserves `bin/dev` and every unowned service. If `bin/dev` only runs Rails, it
will still only run Rails: choose Puma mode or explicitly use the selected
Foreman command. No process-manager gem is installed automatically.

Run setup with the same application environment as normal startup. Preflight
preserves environment-based Bundler configuration, including `BUNDLE_PATH`,
`BUNDLE_APP_CONFIG`, and excluded groups, while resetting inherited activation
state and requesting frozen resolution. Earlier Git builds of this unreleased
installer dropped those settings ([#540](https://github.com/lost-in-the/woods/issues/540)).
If normal task discovery works but installer preflight cannot find Rails or an
installed dependency, check the loaded revision and bundle environment before
reinstalling gems or adding a persistent `.bundle/config` workaround.

Installer refusals return a nonzero exit status with their diagnostic (#544,
unreleased after `2.0.0.beta4`). Earlier Git builds printed the refusal but exited
successfully, so automation using those builds must also check the diagnostic and
whether installation actually applied.

Use `--child-command 'bundle exec rails woods:watch'` when that is the
application's actual Rails entrypoint. Command strings become explicit argument
vectors; shell pipelines, variable expansion, and shell setup scripts are not
supported. Do not prepend an `environment` task or an already booted Rails runner.

### Ownership, updates, and removal

The generator records relative owned paths and fingerprints in `.woods-watch.json`.
Commit it with the generated configuration so a new clone/worktree can update or
remove that setup. Runtime transaction state stays under `tmp/woods-watch-install/`;
keep that directory ignored. Changes to owned content or executable permissions
cause a conflict rather than an overwrite. Review the conflict and restore or
adapt the owned setup explicitly; do not delete the receipt to force an overwrite.

```bash
# Change modes or update owned setup (include the selected mode's options).
bin/rails generate woods:watch --operation update --mode puma --pretend
# Remove owned startup fragments and wrapper; preserve application edits.
bin/rails generate woods:watch --operation remove --pretend
```

Repeat without `--pretend` to apply. Stop an existing watcher through its current
manager before changing owners; the generator does not stop running processes.
Explicit updates refresh owned directives in place, preserving surrounding text
and the block's newline style. Repeating setup preserves the existing directive.
Earlier Git builds used a Puma guard that checked only whether Woods was loaded;
use the update command above with a supporting bundle to install the capability
guard ([#542](https://github.com/lost-in-the/woods/issues/542), unreleased after
`2.0.0.beta4`). Do not hand-edit the owned block or receipt.

For a permanent downgrade, remove the startup configuration while the supporting
gem is still installed. The updated Puma guard lets a branch with an older gem
boot without indexing; it does not make `bin/woods-watch` or a Foreman entry
compatible with that gem.
For Docker/Grove, see [automatic maintenance](AUTOMATIC_MAINTENANCE.md).

An interrupted apply retains its local transaction journal. When Rails boots,
preview recovery with `bin/rails generate woods:watch --operation recover
--pretend`, then repeat without `--pretend`. The Rails command boots the application
before invoking the generator; its `--pretend` prevents installation writes,
not application initialization.

If an initializer prevents Rails boot, run the boot-free recovery helper directly
from the application root using its bundle:

```bash
bundle exec ruby -rwoods/watch/installation -e \
  'puts Woods::Watch::Installation.new(root: Dir.pwd).recover(pretend: true)'
```

Repeat with `pretend: false` to restore the recorded transaction. Recovery checks
snapshots and changes only owned files; concurrent edits keep the journal for
manual resolution. The helper does not load Rails or run task probes. Do not
delete a pending journal to force setup.

### Managed restart and failure behavior

`woods-watch -- bin/rails woods:watch` stays outside Rails and starts a fresh child
for each planned restart. It absorbs exit 75 so Foreman/Puma remain running.
Managed launching requires POSIX process groups and `fork` (Linux/macOS Ruby).
Other platforms should use the raw task with an external supervisor.
Boot failures retry with bounded backoff; a failed extraction leaves the last
good generation readable. `--boot-timeout SECONDS` defaults to 300 seconds and
bounds boot/handshake, not a valid extraction or writer-lock wait.

Managed mode requires `WOODS_WATCH_IDLE_TIMEOUT` to be unset: automatic maintenance
needs a resident child. An unexpected clean stop, incompatible child, or another
owner parks the launcher with a diagnostic until its normal owner restarts it.
There is no automatic ownership takeover. Managed duplicate prevention is scoped
to one host/process namespace; do not mix raw and managed writers across different
containers sharing an index. Use one external owner for that arrangement.

Daemon liveness, completed startup reconciliation, and source freshness remain
different facts. Managed supervision records under `watch_supervisors/` expose
starting/retrying/parked state separately in `woods_status`; an alive supervisor
without a maintaining child does not provide daemon coverage. If the first Rails
boot fails before resolving the configured index path, diagnostics are logs-only.

Verify startup catch-up, an edit, and an initializer restart through the existing
MCP connection before declaring automatic maintenance active. With worktree
management, also verify source and index mounts switch together.

## One cycle

```
watch → debounce → classify → reload if needed → extract → publish
```

**Classify** is the step that matters. Extraction reads the *runtime*, `ActiveRecord::Base.descendants`, `Rails.application.routes`, resolved config,
callback chains on loaded classes, so "a file changed" and "re-reading it is
now worth anything" are different questions. `Woods::ReloadPolicy` answers the
second one; the table of path classes lives in
[INCREMENTAL_EXTRACTION.md](INCREMENTAL_EXTRACTION.md#what-a-change-actually-requires-reload-restart-or-neither).

**Publish** bumps `generation.json`, and only ever after a successful write.
A reader that sees generation N knows the files for N are already on disk, and
a run that failed leaves the number alone, so staleness stays honest.

## Restart triggers

Rails' reloader replaces autoloaded constants and nothing else. It does not
re-run initializers, re-resolve `Rails.application.config`, or rebuild the
schema cache, all of which Woods captures. Changes to dependency/Ruby selection
files (`Gemfile`, `Gemfile.lock`, `.ruby-version`), `.env*`, Rails
application/boot/environment files, initializers, environments, credentials,
database/schema files, `config/settings.yml`, `config/settings/*.yml`, or
boot-captured service config
(`config/{cable,storage,sidekiq,puma,cache,queue}.yml`, including `.yaml`)
make the daemon write a degraded status, stop, and exit `75` for a supervisor
to restart it. Scheduled-job YAML remains an in-process re-extraction input.
The exact matchers live in `lib/woods/reload_policy.rb`.

This is `rails/spring`'s contract, copied deliberately: Spring's staleness bugs
came from under-scoping exactly this set, so the boundary here is drawn on the
generous side.

A restart-trigger change found at startup is reconciled with one full extraction
when it is covered by the task's environment-boot snapshot. That advances the
generation through real extraction, so a supervisor restart does not repeatedly
exit `75` over the same files. Live restart triggers still stop the daemon,
including edits during startup extraction. Their paths survive shutdown even
when the preceding extraction has advanced the generation watermark.

The same escalation happens when the app *can't* reload at all, a boot with
`config.enable_reloading = false`. Extracting against constants that no longer
match their source would be worse than saying so.

## Failure posture

A syntax error mid-edit is normal; it happens every time someone saves halfway
through a thought. The daemon therefore never crash-loops and never publishes a
partial write:

| Failure | What happens |
|---|---|
| Reload raises (`SyntaxError`, `NameError`) | Degraded status naming the reason; index intact at generation N; pending paths retried on the next file event or heartbeat |
| Extraction raises | Degraded status; generation not advanced |
| Payload directory can't be opened, over a payload-born index | Degraded status; generation not advanced. An incremental run only writes the units it touched, so there is no complete flat index it could fall back to publishing, see [Payload publishing](#payload-publishing) |
| Index written but the generation bump failed | Degraded status; paths carried forward. The extractor deliberately does not fail an otherwise-good extraction over an unwritable marker, but the marker *is* what readers refresh on, so the daemon cross-checks that the number moved rather than reporting `running` over an index nothing can see |
| Boot-captured config changed | Degraded status; daemon exits `75` |
| Watcher dies | Degraded status; daemon exits |

`tmp/woods/watch_status.json` carries the state:

```json
{ "state": "degraded",
  "reason": "SyntaxError: unexpected end-of-input",
  "generation": 41,
  "pid": 4821,
  "updated_at": "2026-07-27T04:55:12Z" }
```

Three states, and the middle one is the point: `running` (current, or current
within a debounce window), `degraded` (alive but *cannot* update, index frozen
at a known generation, reason attached), `stopped` (nothing is maintaining this
index). A stale answer is only dangerous when nothing says so.

The file is written world-readable (0644) by design: host-side hooks read it
through a bind mount. Writes through `Woods::AtomicFile` default to owner-only
0600 unless the caller supplies another mode. This is not a guarantee for every
Woods artifact: the SQLite metadata store does not enforce 0600, and a newly
created database uses 0644 under umask 022. Restrict access to the output
directory according to the source and metadata it contains.

Note that `SyntaxError` is a `ScriptError`, not a `StandardError`. Rescuing
only the latter would let a half-typed file kill the daemon.

A cycle that fails to land its work never loses its paths. Lock contention, a
failed reload, and a raising extraction all carry the batch into `@pending`, and
the next cycle folds it back in even if no new event mentions those files.
A degraded cycle ends the current drain to avoid a tight retry loop. Pending
paths are retried on the next file event or [heartbeat](#the-heartbeat), so a
finished contending writer does not require another edit to trigger recovery.
Heartbeat retries use a separate worker so status updates and lock refresh
continue while extraction runs.

### The heartbeat

`alive?` disbelieves a record older than `STALE_AFTER` (15 minutes), and cycle
boundaries are otherwise the only thing that writes one. So the daemon re-stamps
its record every `HEARTBEAT_INTERVAL` (a third of the window). Without it a
perfectly healthy daemon reads as dead after a quiet quarter-hour, the most
common state for a worktree nobody is typing in, and every caller that stands
down for a live daemon starts contending with it instead.

The heartbeat republishes the **last** state, not `running`. A degraded daemon
is still degraded between events, and saying otherwise is the one thing this
file exists to prevent.

The same tick is also when carried-forward paths get retried, but the retry
drain runs on **its own thread**, not the heartbeat's. Running it inline meant a
retried storm (`extract_all` on a large host) stopped the re-stamping and the
`PipelineLock` touch for its whole duration: past `LOCK_STALE_TIMEOUT` (600 s)
any waiting writer retires the live lock and two writers clobber one index, and
past `STALE_AFTER` (900 s) `woods:incremental` stops standing down at the same
moment. `drain`'s own `try_lock` still refuses overlapping drains, so at most
one retry is ever in flight.

## Startup is not a clean slate

A daemon that only reacts to events it personally witnessed is stale the moment
it starts: edits and pulled commits that landed while nothing was watching are
invisible to it forever. That matters because callers stand down when a daemon
is alive, so *alive has to mean covered*.

The standalone `woods:watch` task snapshots reload/restart inputs before invoking
Rails' `environment` task. Inputs unchanged across that boundary, including
carried paths that remain deleted, may be reconciled by a full extraction.
Unreleased after `2.0.0.beta3`: registered restart inputs deleted while the
daemon was stopped also trigger a full extraction after a fresh environment
boot. Nominal framework paths still use the bounded deletion sweep.
Changes during environment initialization still require restart. Lock contention,
extraction failure, and publication failure retain the full-reconciliation
obligation for retry; a successful publish clears it.

This boundary covers **environment initialization**. Bundler and
`config/application.rb` can run before the task begins; the snapshot does not
prove that edits during those earlier stages were incorporated. Start the task
against a settled boot configuration. If Rails is already initialized or the
`environment` task was already invoked, the daemon keeps conservative restart
handling. Use `bundle exec rake woods:watch` as a separate process, rather than
`bundle exec rake environment woods:watch`.

So `run` reconciles before it waits. The watermark is `generation.json`'s mtime, written last on every successful run, so it means "when this index was last
known good", and everything modified since is uncovered, whoever changed it.
With no generation file there is no index, every file is uncovered, and the
storm threshold correctly turns that into one full extraction. A marker whose
payload pointer no longer resolves counts as no index too: the marker can
outlive the directory it names (a partial restore from a CI artifact, an
external cleanup targeting the large directories), and readers deliberately
degrade a dangling pointer to the index root, so trusting the mtime there would
report "current at startup" over a directory holding nothing.

**The built-in watcher establishes detection before reconciliation runs.**
Polling signals readiness after its baseline scan; native watching signals after
listener startup, including a fallback to polling. Startup waits up to 30 seconds
for readiness and reports an error if detection cannot start. Callbacks enqueue
live events immediately, while extraction waits until startup obligations are
established. A
file saved while catch-up's own extraction is still in flight (which can take
minutes on a storm-triggered full run) used to be lost twice: no watcher
existed yet to see it, and the polling watcher takes its baseline snapshot
inside `start`, after the save, so its first diff already excluded it. Worse,
the save's mtime predates the generation bump catch-up publishes at the end, so
a future restart's watermark check would read the file as already covered,
permanently. Starting the watcher first closes that window; `enqueue`/`drain`
already tolerate the duplicate paths this produces against whatever catch-up
finds on its own via the tree scan.

Deletions need one extra step, because a deleted file leaves no mtime to scan:
registered restart inputs follow the full-reconciliation rule above. For other
registered paths gone from disk, a deletion-only startup runs one cycle with an
*empty* change set, which reaches the ghost units through the
extractor's bounded deletion sweep. Deliberately empty, naming the paths would
make the deletions authoritative for every unit type, and some registered paths
are nominal (on Rails < 7.1, `ActiveRecord::SchemaMigration` registers a
convention path no app has), which authoritative deletion would wrongly remove.
The sweep carries the bounds that make reconciliation safe; the daemon only
supplies the trigger.

This is what makes the documented hook pattern safe:

```bash
bundle exec rake woods:watch_status || start_the_daemon # same host; see cross-host liveness below
bundle exec rake woods:incremental   # stands down, the daemon has these
```

Without the catch-up, the sync exits 0 while the changes that prompted it never
reach the index. `woods:incremental` still runs when the daemon is *degraded*:
alive but not updating is not coverage.

## Storms

A branch switch or rebase touches hundreds of files at once. Above
`WOODS_WATCH_FULL_THRESHOLD`, N incremental steps cost more than one full
extraction and risk interleaving with a still-settling tree, so the daemon
falls back to a full run and logs that it did.

## Watcher backends

| Backend | When | Trade-off |
|---|---|---|
| `listen` gem | Used automatically when the host has it | Native FS events; low latency, no idle CPU |
| Polling | Fallback; no dependency | Costs a scan per interval, but works across container bind mounts |

The fallback is not a consolation prize. Native FS events **do not propagate
reliably across container bind mounts**, `listen` documents this, and macOS
Docker VMs are the usual casualty. Since extraction typically runs inside a dev
container with the source bind-mounted, a host in that position should force
polling rather than trust a watcher that may sit silent while files change
under it:

```bash
WOODS_WATCH_POLL=1 WOODS_WATCH_POLL_INTERVAL=2.5 bundle exec rake woods:watch
```

### Polling cost

For a slow bind mount, increase `WOODS_WATCH_POLL_INTERVAL` to reduce scan
frequency. The default is 1.0 second; the example above uses 2.5 seconds.
Each cycle also includes the scan's duration. Longer intervals can delay
change detection and polling shutdown. The value also applies when a native
watcher fails and falls back to polling; it has no effect while native watching
is active. Blank, malformed, nonfinite, zero and negative values are rejected
before the daemon starts.

Selection is also self-correcting at runtime. If `listen` cannot start at all, inotify watch exhaustion (`ENOSPC`) is the usual reason on a large tree, the
daemon logs it and falls back to polling rather than exiting, because a daemon
costing some CPU beats one that never fires. Failures *after* startup are not
treated as backend failures: the rescue covers only the setup, so an error
raised by the extraction inside a callback surfaces as itself.

Polling compares `[mtime, size]` at full float resolution. Truncating mtime to
whole seconds loses a second write inside the same second permanently, there is
no later event to catch it, and save-then-formatter at a 1s interval is
entirely ordinary. Size is the tiebreaker for filesystems that really do offer
only whole seconds.

Ignored by default: `.git`, `node_modules`, `tmp`, `log`, `coverage`,
`vendor/bundle`, `public/assets`, `public/packs`, `storage`. That ignore list is
what keeps a polling scan bounded.

Polling and startup catch-up preserve each logical path when multiple directory
symlinks point to the same source tree. For example, `a_shared/user.rb` and
`app/models/user.rb` both remain visible; an earlier alias must not hide the path
that extraction recognizes. Cycles back to a directory already on the current
traversal branch are pruned, while independent sibling aliases remain visible.
This can increase scan work for deliberately repeated aliases; avoid unnecessary
aliases in large watched trees. Ignored logical paths are still pruned.

## Placement

Run one dedicated extraction process per active worktree/index. The managed
Puma adapter and native launcher above retain that separation. Requiring Woods
or loading its Railtie does not start indexing by itself. Custom integrations
can use the injected daemon collaborators deliberately:

| Option | Verdict |
|---|---|
| **(b) Dedicated daemon**: *recommended default* | One extra booted app per worktree. Isolated: a crash, a restart, or a storm affects only the index. Lifecycle is drivable from worktree hooks. |
| **(a) Custom in-process integration** | A host can call public `Daemon#process` deliberately, but must own threading, reloading, and lifecycle. This is not an automatic Railtie feature or the managed Puma adapter. |
| **(c) Host watcher + in-container session** | Solves bind-mount event unreliability, but with the most moving parts. Forcing the polling backend solves the same problem with none. |

Measured on the fixture app (Ruby 3.3, Rails 8.0):

| Measurement | Value |
|---|---|
| Ruby baseline RSS | 27.8 MB |
| + booted Rails app | 64.9 MB (+37.1) |
| + Woods daemon on top | 72.1 MB (+7.2) |
| Single-file cycle | 48–81 ms (p95 81 ms) |
| 8-file storm → full extraction | 227 ms |

The daemon's own footprint is small; the cost of option (b) is the booted app,
not Woods. That is why (a) is worth keeping available for hosts that already
pay for one.

#### Where a full extraction of the fixture app spends its time

One cold `extract_all` over `spec/dummy`, 147 units of which 119 are framework
sources, 7 repetitions, Ruby 4.0.6 / Rails 8.0.5.1, phase timers around the
orchestrator's own methods. Total **190 ms** at p50.

Every share below is that phase's milliseconds over the 190 ms total, so the
top-level rows add up to the total. Indented rows break their parent down and
are already counted in it.

| Phase | ms | share of 190 ms |
|---|---|---|
| extraction | 115 | 60.5% |
| &nbsp;&nbsp;of which `RailsSourceExtractor` | 100 | 52.6% |
| &nbsp;&nbsp;of which `ModelExtractor` | 4.4 | 2.3% |
| &nbsp;&nbsp;of which every other extractor | 10 | 5.3% |
| `write_results` | 23 | 12.1% |
| git enrichment | 22 | 11.6% |
| graph analysis (`GraphAnalyzer#analyze`) | 6.1 | 3.2% |
| &nbsp;&nbsp;of which PageRank | 3.9 | 2.1% |
| manifest, graph and analysis writes | 6.9 | 3.6% |
| orphan sweep | 2.6 | 1.4% |
| dedupe, package annotation, dependents, path normalisation, publish | 0.6 | 0.3% |
| not attributed to a timed phase | 13.8 | 7.3% |
| **total** | **190** | **100%** |

The unattributed row is the orchestration between the timed phases: output
directory setup, the `ModelNameCache` reset, rebuilding the graph from the
deduped results, and the payload bookkeeping. It is named rather than dropped so
the column is a real accounting.

**The graph layers are not where the time goes.** PageRank moving inside
`analyze`, and the three reports added beside it, come to 3.2% of the run
together. Git enrichment, the other suspect, is 11.6%: real, but not a phase to
rewrite. The dependents pass and path normalisation are below a millisecond
each.

One phase clears 15%: `RailsSourceExtractor`, at 52.6%. Read it with the
fixture's shape, though. 119 of 147 units *are* framework sources here, so this
figure is a property of a fixture app with almost no application code, not a
finding about a real host. Turning it off is one flag
(`include_framework_sources`), and it does not touch the incremental path at
all. Filed as B-187 rather than acted on here: sizing it needs a host where
framework sources are the minority.

### Measured at scale

The numbers above are fixture-app numbers. Below are the same measurements on a
**1,940-unit app**: `apps/rails-8.0-large` in
[woods-testbed](https://github.com/lost-in-the/woods-testbed), a hand-written
kernel covering all 35 extractors plus a deterministically generated tree, run by
`scripts/woods_bench.rb` in woods-testbed (Ruby 3.3.1 / Rails 8.0.5, in-container, 5 reps per
scenario). See [woods-testbed#2](https://github.com/lost-in-the/woods-testbed/issues/2).

Cold full extraction: **5,541 ms**, and the phase split is the surprise:

| Phase | ms | share |
|---|---|---|
| `write_and_publish` | 2,925 | 53% |
| extraction | 2,556 | 46% |
| graph analysis (PageRank + structural) | 27.8 | 0.5% |
| dedupe | 12.5 | 0.2% |
| git enrichment | 10.6 | 0.2% |
| path normalisation | 4.6 | 0.1% |
| dependents resolution | 4.3 | 0.1% |

**PageRank and the dependents pass do not dominate.** Together they are 32 ms of
5,541, six tenths of one percent. The cost is extraction itself plus *writing
the output*, and the latter is dominated by `AtomicFile`'s fsync per unit file.
Anyone optimising the graph passes here would be tuning 0.5% of the runtime; the
lever is the write path.

Incremental, per scenario, with the units each change causes to be rewritten:

| Change | p50 | p95 | Units written | % of index |
|---|---|---|---|---|
| a controller | 274 ms | 341 ms | 6 | 0.3% |
| a model | 402 ms | 451 ms | 38 | 2.0% |
| **`config/routes.rb`** | **2,534 ms** | 2,830 ms | **1,036** | **53.4%** |
| `db/schema.rb` | 107 ms | 134 ms | 0 | 0.0% |

The routes row is the wholesale re-run of `ROUTE_CONSUMER_EXTRACTORS`. Read the
**shape** alongside the size: 53.4% is higher than the ~24% measured on a
production host, because the testbed's generated tree is deliberately dense in
controllers and view templates, exactly the route-consumer types. A real app
with more models per controller sits lower. Any figure quoted from that variant
therefore carries its scale *and* its composition, which is why the harness
embeds the generator manifest in every result.

`db/schema.rb` writing zero units is correct, not a gap: `ReloadPolicy`
classifies it `:restart`, and a plain `extract_changed` touches nothing because
the models are class-based and their constants have not changed.

**Still not measured:** event latency across a **macOS** Docker Desktop bind
mount. A Linux bind mount measures 723–824 ms from write to generation bump, but
osxfs/gRPC-FUSE is the behaviour actually in question and needs a macOS host, so that gap stays open rather than being closed with a Linux number.

## The freshness contract

A daemon that keeps the index current is only half the problem. The other half
is a reader that notices.

### Generations

Every extraction mode, full, incremental, targeted refresh, daemon cycle, writes `tmp/woods/generation.json` as its **last** action:

```json
{ "number": 42, "token": "9f2c81ad3e4b7c05", "updated_at": "2026-07-27T04:55:12Z", "reason": "incremental" }
```

Two properties, both from the same rule, never advance a cursor over work that
didn't land:

- **Bumped last**, so a reader that sees generation N knows N's files are
  already on disk.
- **Not bumped on failure or on a no-op run**, so staleness stays honest.

`IndexReader` checks it at the top of every read: one `File.stat` of a
~100-byte file, with caches dropped only when the generation number actually
advanced. The stat signature is `[mtime, size, inode]`, the inode is
load-bearing, because two same-second bumps with an identical payload length
are the daemon's steady state and `[mtime, size]` alone cannot tell them apart
on a coarse-mtime filesystem. Since `AtomicFile` renames a fresh tempfile on
every publish the inode always moves, so in practice the file is re-parsed once
per publish; the saving is on the reads *between* publishes, which is the
common case. That makes the MCP `reload` tool an
*optimization* rather than a correctness requirement, previously a long-lived
server held whatever it read at boot, so an agent working alongside a running
extraction silently got answers describing the tree as of the last server
start.

An index with no generation file (written before this existed, or by a third
party) behaves exactly as it always did.

### `woods_status`

```jsonc
{ "index": {
    "generation": 42,
    "generation_reason": "incremental",
    "generation_updated_at": "2026-07-27T04:55:12Z",
    "git_sha_matches_head": true,
    "working_tree_dirty": true,           // git_sha_matches_head only sees committed HEAD
    "working_tree_fingerprint": "3f9a2c81ad3e4b7c",
    "staleness_seconds": 12
  },
  "watch": {
    "state": "degraded",                  // running | degraded | stopped | absent
    "reason": "SyntaxError: unexpected end-of-input",
    "generation": 41
  } }
```

`working_tree_dirty` closes a real hole: an agent forty uncommitted edits deep
was told the index matched HEAD while every answer described the tree before
those edits.

The fingerprint hashes the current `git status --porcelain` path/status list.
Repeated edits to the same already-dirty file can leave it identical. It is not
content identity. Use `index.source_freshness` for generation-bound content
verification; see [source freshness](SOURCE_FRESHNESS.md) for `current`, `drifted`,
`unknown`, scan budgets, fresh-process capture and partial-runtime limitations.

### Multi-file read consistency

The index is a directory, not a file, so "read the index" is many reads. Two
options were on the table.

**Per-request generation re-check, implemented.** Each read checks the
generation first, so an *unpinned* read never serves from a cache older than
what is published. `IndexReader#with_pinned_generation` extends that across a
sequence: freshness is checked once on entry and then held, so nothing already
cached is dropped and re-read at a newer generation partway through. `warmup!`
uses it.

The pin is the deliberate exception to the sentence above, and it is reader-wide
rather than per-request: while any pin is held, `refresh_if_stale` returns early
and *every* read on that reader, including ones outside the pinned block, under
a threaded transport, is served at the pinned generation. Pins are refcounted,
so invalidation resumes when the last one releases. Consistency within a
sequence is bought with bounded staleness across concurrent ones; for a
development-time index that is the right side of the trade, but it is a trade.

Its documented limit: pinning suppresses invalidation, it does not snapshot. An
artifact never read before is still loaded from disk as it stands when the
block reaches it. Guaranteeing more would mean materializing the whole index on
entry, which is what `warmup!` costs, per request.

### Payload publishing

**Atomic pointer over the whole payload, adopted.** Every writer now
publishes into `payloads/gen-<N>/` (`Woods::PayloadStore`) instead of
`tmp/woods/models/…` directly, and `generation.json` carries a `payload`
pointer naming which directory the current generation lives in
(`Woods::Generation#payload_dir`). A reader resolves every artifact through
that one pointer, so a single atomic write of `generation.json` is the commit
point for the whole payload, no reader can see a manifest from generation
N+1 next to a unit from N. An index written before this existed (or a
third-party writer that still writes flat) has no `payload` key, and every
reader falls back to the index root unchanged.

Retention does not invalidate an in-flight read. While
`IndexReader#with_pinned_generation` serves a payload, it holds a shared
advisory lock on that generation's `manifest.json`; pruning takes an exclusive
non-blocking lock on the same file and skips a busy generation. This works
across Index MCP and extraction processes without reader-created lease files,
so read-only index mounts remain sufficient for ordinary tools and a crashed
reader leaves no stale lease. A skipped directory can temporarily exceed
`WOODS_PAYLOAD_RETENTION` and is reconsidered by the next successful publish.
The protocol relies on the same filesystem advisory-lock support as Woods'
pipeline coordination.

A **full** extraction (`Extractor#extract_all`) degrades to a flat publish if
it can't open a fresh payload directory, the write set is the whole app, so a
flat publish is still a complete index. An **incremental** run
(`extract_changed` / `refresh`) writes only the units it touched, so there is
no complete flat index it could fall back to: over a payload-born index it
raises `Woods::ExtractionError` instead of publishing a corrupt-looking
mixture. The generation is never bumped over a raised run, so readers keep
serving the last good index. See `Extractor#begin_payload!(strict:)`.

### MCP `resources/updated`: evaluated, not implemented

The MCP spec supports server-initiated `notifications/resources/updated`, and
#164 asked whether it is worth adding as a push channel. It is not, yet:

- The `mcp` gem gives the server `notify_resources_list_changed` but no
  `notify_resources_updated`, and gates the method behind a
  `resources.subscribe` capability with no handler hooks for
  `resources/subscribe` / `unsubscribe`.
- The index server runs over stdio as a request/response loop. Pushing would
  mean writing unsolicited frames from a background thread while the main loop
  reads stdin.
- Client support is not something we could depend on anyway, so it would be
  strictly additive on top of a reader-side check that already delivers the
  correctness property for every client.

The reader-side generation check is the robust answer, and it is the one
implemented. Revisit if the gem grows the server-side API and a client we care
about acts on it.

## Multiple worktrees

The topology to design for: a worktree manager provisions a canonical checkout
plus N agent slots (commonly ~5), each an independent `Rails.root` with its own
container stack and its own `tmp/woods`, while several sessions run
concurrently, sometimes sharing a worktree.

### Disjointness is structural

Per-worktree output directories mean daemons never contend *across* worktrees.
There is deliberately **no** shared cross-worktree index and **no** daemon
multiplexing several worktrees from one process: the single-active-project
failure mode of stateful multiplexed servers is well documented in adjacent
tools, and disjoint-by-construction is what makes this design safe.

### Within one worktree, writers serialize

Three writers can want the same index: the daemon, a manual `woods:extract`,
and a hook-triggered `woods:incremental`. They share the existing file-based
`PipelineLock`, and the policy is:

| Situation | Behaviour |
|---|---|
| Daemon cycle while another writer holds the lock | Daemon yields, publishes a `contended` degraded status, and **carries its paths into the next cycle** so nothing is lost |
| Manual `woods:extract` / `woods:incremental` / `woods:refresh` (including `woods:extract_framework`) | Waits up to `LOCK_STALE_TIMEOUT` (600 s; override with `WOODS_LOCK_WAIT`) for the lock, then **exits non-zero** rather than proceeding unlocked. It also exits non-zero with a typed error when the final generation marker cannot be published; the previous generation remains readable. A storm-triggered `extract_all` can hold the lock for minutes on a large host, and two concurrent writers rewrite the dependency graph from divergent copies, so the loser's work is silently discarded under a generation that says "fresh" |
| Hook sync on a tree a daemon is already watching | Skips entirely: the daemon has already seen those changes. `WOODS_IGNORE_WATCH=1` overrides |

A hook can check cheaply:

```bash
bundle exec rake woods:watch_status || start_the_daemon   # same host, exit 0 = alive
```

The check does not boot Rails. Without `WOODS_OUTPUT`, it resolves
`tmp/woods/watch_status.json` relative to the active Rakefile, not the
launcher's current directory, so `rake -f /app/Rakefile woods:watch_status`
and worktree-manager invocations inspect the same per-app status. Set
`WOODS_OUTPUT` when the daemon uses a non-default index directory.

### Cross-host liveness

By default, a reader trusts only a same-host record: a `running` or `degraded`
state, a positive pid that still exists, and a recent ISO8601 timestamp. Foreign
hostnames are rejected because a container pid cannot be checked on the host.

For a daemon and reader sharing the same index through a bind mount, opt in in
each reader's environment:

```bash
export WOODS_WATCH_TRUST_FOREIGN_HOST=1
bundle exec rake woods:watch_status || start_the_daemon
```

Set the variable inside one-off containers running `woods:incremental`, and in
the host MCP process when it reports `woods_status`. Docker does not forward a
host environment variable automatically: pass `-e WOODS_WATCH_TRUST_FOREIGN_HOST=1`
to `docker compose run` or `docker compose exec`, or configure that service's
environment. Use the same shared index (`WOODS_OUTPUT` when needed) in each process.

Opted-in readers accept foreign `running` and `degraded` records on heartbeat
freshness, without any local pid lookup. Heartbeats run every five minutes; a
crashed foreign daemon can still be believed for up to 15 minutes after its last
heartbeat. Missing or malformed timestamps and timestamps more than 30 seconds
in the future are rejected. Keep the participating clocks synchronized.

`degraded` means alive but unable to update: `watch_status` exits 0, incremental
still attempts extraction, and clean refuses. `WOODS_IGNORE_WATCH=1` still
overrides writer stand-down and clean protection. It does not alter the status
report. Direct Ruby callers can override the environment with
`Status#alive?(trust_foreign_host: true)` or `false`.

This is liveness evidence for an established daemon, not a cross-container
startup lease. Simultaneous starts in foreign namespaces still need one
supervisor to coordinate ownership. Hostnames are also imperfect identity:
custom or reused identical container hostnames retain the local-pid limitation.

### Hooks for agent sessions

For client registration and the supported Claude/OpenCode event shapes, see
[edit client adapters](CLIENT_HOOKS.md). Both use the shared queue below.

The daemon covers a human's editor session. A `claude -p` run in a worktree
with no daemon needs a different trigger, so the Woods plugin ships two freshness
hooks (`plugin/hooks/hooks.json`), both shipped disabled:

| Hook | When | What it does |
|---|---|---|
| `PostToolUse` (`Edit`, `Write`, `MultiEdit`), async | A supported extraction or boot input changes | Queues an immutable JSON event, then calls `woods:hook_refresh[<encoded batch>]`; output goes to `hook.log` |
| `SessionStart` (`startup`, `resume`) | Session begins | Checks source content through `woods:source_status`; warns on drift or unknown evidence |

Both read `cwd` from the hook payload, so a linked worktree uses its own index.
Both require an existing `generation.json` and `WOODS_HOOKS_ENABLED=1`;
`WOODS_HOOKS_DISABLED=1` overrides enablement. The broader refresh task is
**unreleased after Woods 2.0.0.beta2**. Check the installed gem's task list
(`bundle exec rake -T woods:hook_refresh`, through the application container
when appropriate) before enabling this plugin version. An older gem's unknown
task error leaves queued events in place; installing the plugin does not upgrade
the gem.

The portable path predicate is generated from `PathDispatcher` and
`ReloadPolicy` with `bundle exec ruby -Ilib script/generate-hook-rules`.
A contract test rejects stale generated rules. It covers services, controllers,
jobs, concerns, views, locales, supported test/lib files, routes, package
boundaries, and the remaining standard extractor triggers. Unrelated documents
stay quiet. Normal edits use fresh-process incremental extraction; changes to
initializers, boot configuration, dependencies, schema, or other restart inputs
use fresh-process full extraction. The transport also preserves explicit
`add`, `update`, `delete`, and `move` operations; a relevant deletion/move selects
full extraction to remove runtime classes absent from the next boot. The Claude
adapter receives one `tool_input.file_path`. The OpenCode adapter supplies every
verified patch metadata path, including both rename sides. Neither infers paths
from shell commands or parses patch text. Custom runtime roots outside the
standard dispatcher rules require an explicit refresh; the portable predicate
cannot discover application configuration without booting it.

`WOODS_HOOK_RAKE` sets the command prefix (Docker:
`docker compose exec -T app bundle exec rake`). The encoded JSON task argument
carries paths and the output setting across the container boundary, without
assuming Docker forwards host environment variables or can read a host queue
filename. The host needs Bash 3.2 or later, standard Unix tools, and either `jq`
or Ruby; it does not need the application bundle. Prefix words are split without
shell evaluation: use an executable wrapper for quoted arguments or extra
container environment settings. `WOODS_OUTPUT` overrides `tmp/woods`, relative
to each process's application root or as an explicitly supplied absolute path;
absolute paths must be valid on both sides of a container bind mount.

Each event remains under `<output>/hook-pending/` until the task succeeds.
Successful no-op consumption is acknowledged too. Contending invocations enqueue
and return while the owner drains bounded batches (up to 16 queue files /
1,000 paths / 48 KiB of JSON, without splitting a multi-file event). Commas,
spaces, and newlines are preserved. An empty drain releases the lock before
checking again, so a final arriving event can acquire ownership.
A failed command, killed worker, incompatible gem, or publication failure retains
its batch for retry: delivery is **at least once**, so crash recovery can repeat
already completed work. Pending events in the previous `hook-pending.txt` format
are imported on the next relevant edit. Event filenames are private hook state;
do not modify them while a worker is running.

An active daemon produces exit **75** before Rails boots. This is a deferral,
not acknowledgement: the hook cannot prove which queued events the daemon has
consumed. It retains the queue and writes a diagnostic. It does not start, stop,
or restart the daemon. After resolving the cause, the next relevant edit retries
the queue. To retry immediately, invoke `woods-post-edit.sh` with the original
JSON event on stdin and the same opt-in/output/prefix settings; with a running
daemon, stop it first or explicitly configure `WOODS_IGNORE_WATCH=1` in the
application command's environment. A quiet `SessionStart` does not acknowledge
the queue. Prefer a resident watcher for sustained edits; enabling both does not
make refresh faster and can accumulate deferred events.

After the complete event input has been read, validated, and queued, the refresh
hook starts its `WOODS_HOOK_TIMEOUT_SECONDS` deadline (default 600, integer range
1–3600), including subsequent batches. The producer must close stdin: the 1 MiB
input limit bounds bytes, not time waiting for EOF. The deadline terminates the local
command process group and retains work on timeout. For a Docker exec prefix,
local process termination cannot guarantee cancellation inside the container;
check the application process and extraction lock before retrying a timed-out
container run. Async client hook timeouts are not a reliable worker deadline.
With `flock`, kernel locks release after process exit. The mkdir fallback records
an owner PID and reclaims dead owners; it never steals a live owner's lock based
only on age. Only the invocation that removes the recorded dead-owner marker
may replace its lock directory; competing reclaimers leave their events queued
for the winning owner. Legacy empty lock directories use `stat` and
`WOODS_HOOK_LOCK_STALE_SECONDS` (default 1800) for conservative recovery.
A reused PID can delay recovery until that process exits; inspect the recorded
owner before manually removing a lock. Hooks sharing this filesystem must run in
the same host PID namespace; run the actual extraction through the container
prefix instead of running competing host/container hook workers.

Broader coverage increases the number of Rails boots. A view or locale edit now
costs a fresh incremental run, while a boot/config edit costs a full run. There
is no provider or embedding call added by this hook. Opt in for occasional agent
edits; use `woods:watch` for repeated work, and keep full extraction for large
change sets as described above.

The `SessionStart` hook uses the shared quick source verifier through
`WOODS_HOOK_RAKE`. It has a ten-second command deadline, including startup;
failed commands and old gems lacking `woods:source_status` report unknown.
It does not initialize Rails or start a provider. See [source freshness](SOURCE_FRESHNESS.md#containers-and-hooks).

### Reader multiplicity is free

Several sessions in one worktree each spawn their own stdio `woods-mcp`. With
the generation check they converge on fresh data with no coordination and no
shared server, which is the property worth protecting, since a persisted
index served by many cheap readers is exactly what Woods has that a
per-process language-server index does not.

### Idle TTL

N resident daemons is N booted apps, and most slots are dormant most of the
time. `idle_timeout` (off by default) stops a daemon after that many seconds
without a file event. Revival requires a separately configured supervisor or
startup hook; the shipped SessionStart hook only checks freshness. Managed
`woods-watch` rejects this setting because an idle child shutdown would leave
automatic maintenance inactive until the owner restarts it.

```ruby
Woods::Watch::Daemon.new(output_dir: …, idle_timeout: 900).run   # 15 minutes
```

Off by default because a single-worktree host wants the daemon to stay up.

### What is verified, and what isn't

| Property | Where |
|---|---|
| A real file write reaches `extract_changed`, watcher thread, callback, debounce and drain loop end to end | `spec/watch/watcher_integration_spec.rb` |
| A burst coalesces into one extraction; a same-second rewrite is not lost; a `stop` racing startup is honoured | same |
| A real `Rails.application.reloader` picks up changed source, under the interlock unload lock | `spec/integration/watch_daemon_spec.rb` |
| Concurrent cycles serialize; no deadlock; no orphaned lock, even when extraction raises | `spec/watch/multi_instance_spec.rb` |
| Contended cycle carries its paths forward | same |
| Idle TTL exits and records why | same |
| Six real worktrees stay disjoint, validate-green, independently versioned | `spec/integration/multi_worktree_spec.rb` |
| Many concurrent readers per worktree converge without coordination | same |

**Per-daemon memory at six-worktree scale, measured.** `Rails.root` is a
process singleton, so six *concurrently extracting* booted apps cannot exist in
one Ruby process. That constraint is about processes, not containers, so six
forks with disjoint output directories satisfy it, `scripts/woods_daemon_scale_smoke.rb` in woods-testbed does exactly that:

| | |
|---|---|
| Parent booted app, no extraction | 83.3 MB |
| Per worktree after two full extractions | 165.9 – 166.3 MB (mean **166.0**) |
| Summed across six | 996.2 MB |

**The 72.1 MB figure above is a fixture-app number; at 1,940 units it is 166 MB, 2.3× that.** Plan for the measured figure, not the extrapolation.

Two caveats the harness prints itself: forks share the parent heap
copy-on-write, so the 996 MB sum is an upper bound rather than true additional
memory and the mean is the per-daemon figure; and this measures repeated
`Extractor` cycles, so it is the extraction footprint rather than the idle
steady state a dormant daemon holds.

## Embedding it

```ruby
# A host that owns its own event loop
daemon = Woods::Watch::Daemon.new(output_dir: Rails.root.join("tmp/woods"))
result = daemon.process(changed_paths)
# => { action: :incremental, state: :running, generation: 42, count: 1, duration_ms: 61 }
```

For an embedded `#run`, pass `boot_snapshot: Woods::Watch::BootSnapshot.new(root: …)`
with the snapshot captured **before** environment initialization if the host can
establish that boundary. Without it, startup restart inputs remain restart
requests. Direct `#process` calls always preserve conservative restart handling.
Injected watchers retain their existing `start`/`stop` interface; those with
asynchronous startup can implement `ready_callback=` and call it after detection
is established to participate in the readiness handshake.

`#process` is one whole cycle and is the supported embedding point. `#run` only
supplies batches to it.

### Optional bounded context hints

Context hints are a separate Claude Code opt-in, **unreleased after Woods
2.0.0.beta2**. Verify `bundle exec woods-hook-context --help` in the installed
application bundle before enabling `WOODS_HOOK_CONTEXT_ENABLED=1`. The plugin
version alone does not establish gem support. `WOODS_HOOKS_DISABLED=1` disables
both context and refresh; `WOODS_HOOKS_ENABLED` controls only the existing
freshness/refresh hooks. Either feature can work without the other.

Separate synchronous SessionStart and PostToolUse entries emit Claude's
`hookSpecificOutput.additionalContext`. SessionStart gives a short served-index
orientation. After a relevant native Edit/Write/MultiEdit, the hint identifies
candidates from one retained published generation. Direct candidates and
transitive candidates are distinguished; test mappings are suggestions, never
proof of coverage. Post-edit hints always say **pre-refresh snapshot** because
an edit can precede publication. Source freshness is checked against that same
payload; unknown/drifted evidence remains explicit. An unresolved or ambiguous
edited identity directs the agent to manual search and typed lookup. No match
within the bounded snapshot establishes neither absence nor no impact.

Limits are fixed: depth 2, at most 10 visited nodes including the root, 100
examined edges, and 2 KiB for the **entire JSON output**, preserving whole rows.
An index is refused above 16 MiB per required artifact or 50,000 combined graph
nodes/variants. These preparation checks, JSON parsing, cache construction,
source verification, path/content hashing, formatting and suppression state all
run within the hook's private process-group deadline: the worker is killed at
850 ms, leaving dispatch/cleanup headroom within a one-second work budget.
The helper also has a 650 ms inner deadline. OS scheduling can delay observation
of a deadline. Cold bundle/container startup can therefore produce no hint;
the deadline is not extended. Oversized evidence is marked truncated; missing,
corrupt, unsupported or timed-out input produces a short unknown notice or
silence. Silence is never a complete/no-impact claim. The hint boots no Rails
application and calls no provider.

The synchronous opt-in can add up to this budget to a supported tool call. It
makes context available to Claude's next model request; it does not rely on the
later-turn delivery of the independent asynchronous refresh worker. A reminder
need not appear as a visible transcript entry. See the
[Claude context-output contract](https://code.claude.com/docs/en/hooks#add-context-for-claude).

The default command is `bundle exec woods-hook-context`. Set
`WOODS_HOOK_CONTEXT_COMMAND` to an executable wrapper or argv prefix for a
container-only bundle. Prefix words are split without shell evaluation; a
wrapper handles quoted arguments. Explicit `WOODS_HOOK_CONTEXT_ROOT` maps the
hook payload's original cwd and contained edit path onto a runtime-visible
application root. For example, a container prefix can include
`docker compose exec -T -e WOODS_HOOK_CONTEXT_ENABLED=1 -e WOODS_HOOK_CONTEXT_ROOT=/app app bundle exec woods-hook-context`.
Forward a custom `WOODS_OUTPUT` explicitly too. Running Claude inside the
application container avoids external container startup and path mapping.

Repeat suppression uses session/worktree, served generation/token, changed-file
content identity and normalized hint content. Repeated identical evidence stays
quiet; later same-file edits and generation changes can reappear. Missing session
or bounded content identity disables suppression. Private `hook-context-state.json`
retains at most 32 sessions and 32 emitted identities per session under a separate
nonblocking lock. It records **emitted**, not confirmed delivered, hints.
Contending or unavailable state may skip optional context. Its bounded atomic
state update never reads, acknowledges, or clears `hook-pending`, nor acquires
refresh/watch locks. Disable context to roll back without changing refresh.

Only the native Claude context entries are supported here; the OpenCode adapter
continues to provide refresh events. No prompt-triggered retrieval is injected.

See the [matched public Rails task comparison](EVALUATION.md#matched-optional-context-hook-tasks-406) for delivered hints, task outcomes, measured overhead and observed limitations.
