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
| `WOODS_WATCH_IDLE_TIMEOUT` | unset | Seconds of quiet after which a dormant daemon exits |
| `WOODS_WATCH_CATCH_UP` | `1` | `0` skips the startup reconciliation |

Run it under a supervisor. When boot-captured configuration changes the daemon
exits `75` (`EX_TEMPFAIL`) on purpose, see [Restart triggers](#restart-triggers).

```yaml
# Procfile.dev
web:   bin/rails server
woods: bundle exec rake woods:watch
```

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

The same escalation happens when the app *can't* reload at all, a boot with
`config.enable_reloading = false`. Extracting against constants that no longer
match their source would be worse than saying so.

## Failure posture

A syntax error mid-edit is normal; it happens every time someone saves halfway
through a thought. The daemon therefore never crash-loops and never publishes a
partial write:

| Failure | What happens |
|---|---|
| Reload raises (`SyntaxError`, `NameError`) | Degraded status naming the reason; index intact at generation N; retried on the next event |
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
through a bind mount. Every other artifact Woods writes stays at 0600.

Note that `SyntaxError` is a `ScriptError`, not a `StandardError`. Rescuing
only the latter would let a half-typed file kill the daemon.

A cycle that fails to land its work never loses its paths. Lock contention, a
failed reload, and a raising extraction all carry the batch into `@pending`, and
the next cycle folds it back in, the files really did change, and no later
event will mention them again. The retry is not a tight loop: a degraded cycle
ends the drain and waits for the next event, because the cause needs an edit to
clear.

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

## Startup is not a clean slate

A daemon that only reacts to events it personally witnessed is stale the moment
it starts: edits and pulled commits that landed while nothing was watching are
invisible to it forever. That matters because callers stand down when a daemon
is alive, so *alive has to mean covered*.

So `run` reconciles before it waits. The watermark is `generation.json`'s mtime, written last on every successful run, so it means "when this index was last
known good", and everything modified since is uncovered, whoever changed it.
With no generation file there is no index, every file is uncovered, and the
storm threshold correctly turns that into one full extraction.

**The watcher thread starts before this reconciliation runs, not after.** A
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
if any path the index attributes a unit to is gone from disk, the daemon runs
one cycle with an *empty* change set, which reaches the ghost units through the
extractor's bounded deletion sweep. Deliberately empty, naming the paths would
make the deletions authoritative for every unit type, and some registered paths
are nominal (on Rails < 7.1, `ActiveRecord::SchemaMigration` registers a
convention path no app has), which authoritative deletion would wrongly remove.
The sweep carries the bounds that make reconciliation safe; the daemon only
supplies the trigger.

This is what makes the documented hook pattern safe:

```bash
bundle exec rake woods:watch_status || start_the_daemon
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
WOODS_WATCH_POLL=1 bundle exec rake woods:watch
```

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

## Placement

The spike asked for three placements to be compared and one chosen. Every
collaborator on `Woods::Watch::Daemon` is injected, so all three are reachable
from the same class, but the default is **(b), a dedicated daemon per
worktree**:

| Option | Verdict |
|---|---|
| **(b) Dedicated daemon**: *recommended default* | One extra booted app per worktree. Isolated: a crash, a restart, or a storm affects only the index. Lifecycle is drivable from worktree hooks. |
| **(a) Embedded in the dev server** via the Railtie | Marginal memory cost ~0 where a booted app already exists, but couples index freshness to the dev server running and puts extraction on its threads. `Daemon#process` is public precisely so a host can do this deliberately. |
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

### Measured at scale

The numbers above are fixture-app numbers. Below are the same measurements on a
**1,940-unit app**: `apps/rails-8.0-large` in
[woods-testbed](https://github.com/lost-in-the/woods-testbed), a hand-written
kernel covering all 34 unit types plus a deterministically generated tree, run by
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

The fingerprint (a digest of `git status --porcelain`) is *as of the call*.
Nothing records the digest the index was built at, so it cannot tell you "this
is the same dirty state the index describes", it gives a stable identity for
the current dirty state, so two of your own calls can be compared to detect the
tree moving underneath you. Pair it with `generation` to distinguish "tree
changed and the index followed" from "tree changed and the index has not caught
up".

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
| Manual `woods:extract` / `woods:incremental` | Waits up to `LOCK_STALE_TIMEOUT` (600 s; override with `WOODS_LOCK_WAIT`) for the lock, then **exits non-zero** rather than proceeding unlocked, a storm-triggered `extract_all` can hold the lock for minutes on a large host, and two concurrent writers rewrite the dependency graph from divergent copies, so the loser's work is silently discarded under a generation that says "fresh" |
| Hook sync on a tree a daemon is already watching | Skips entirely: the daemon has already seen those changes. `WOODS_IGNORE_WATCH=1` overrides |

A hook can check cheaply:

```bash
bundle exec rake woods:watch_status || start_the_daemon   # exit 0 = alive
```

Liveness needs three things to agree, each ruling out a different way the
status file lies: a state a live daemon writes, a pid that still exists (a
`kill -9` leaves the file behind), and a recent timestamp (a machine that lost
power leaves a `running` record whose pid some unrelated process now owns).

One known limit: the pid check sees only the caller's own pid namespace. In the
Docker layout, daemon in the container, output volume-mounted to the host, a
host-side `watch_status` tests a host pid that has nothing to do with the
containerized daemon, so it can misread liveness in either direction for up to
`STALE_AFTER` (the timestamp check still bounds it, and the heartbeat keeps a
live daemon inside that bound). Run `watch_status` on the same side as the
daemon; a cross-namespace liveness protocol isn't worth its complexity here.

### Reader multiplicity is free

Several sessions in one worktree each spawn their own stdio `woods-mcp`. With
the generation check they converge on fresh data with no coordination and no
shared server, which is the property worth protecting, since a persisted
index served by many cheap readers is exactly what Woods has that a
per-process language-server index does not.

### Idle TTL

N resident daemons is N booted apps, and most slots are dormant most of the
time. `idle_timeout` (off by default) stops a daemon after that many seconds
without a file event, so a slot nobody is working in stops holding ~65 MB. A
worktree hook or session start revives it.

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

`#process` is one whole cycle and is the supported embedding point. `#run` only
supplies batches to it.
