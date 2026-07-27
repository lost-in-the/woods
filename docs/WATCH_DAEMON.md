# The Watch Daemon (`woods:watch`)

A resident, booted-app process that keeps the index current as files change,
instead of as-fresh-as-the-last-explicit-rake-run.

Background: [#164](https://github.com/lost-in-the/woods/issues/164), phase 2.
The correctness work it stands on is in
[INCREMENTAL_EXTRACTION.md](INCREMENTAL_EXTRACTION.md) — a watcher on top of an
incorrect incremental path just delivers wrong answers with lower latency.

> **Development only.** The daemon adds no network listener and no new
> transport. It watches the filesystem and writes to `tmp/woods`. Don't run it
> in production; there is nothing to gain and a booted process to lose.

## Running it

```bash
bundle exec rake woods:watch     # alias: woods:guard
```

```
Watching /app — index at /app/tmp/woods
Ctrl-C to stop.
```

| Environment variable | Default | Meaning |
|---|---|---|
| `WOODS_OUTPUT` | `tmp/woods` | Index directory |
| `WOODS_WATCH_DEBOUNCE` | `0.4` | Seconds of quiet before a batch is considered settled |
| `WOODS_WATCH_FULL_THRESHOLD` | `50` | Changed-file count above which a full extraction replaces incremental |

Run it under a supervisor. When boot-captured configuration changes the daemon
exits `75` (`EX_TEMPFAIL`) on purpose — see [Restart triggers](#restart-triggers).

```yaml
# Procfile.dev
web:   bin/rails server
woods: bundle exec rake woods:watch
```

## One cycle

```
watch → debounce → classify → reload if needed → extract → publish
```

**Classify** is the step that matters. Extraction reads the *runtime* —
`ActiveRecord::Base.descendants`, `Rails.application.routes`, resolved config,
callback chains on loaded classes — so "a file changed" and "re-reading it is
now worth anything" are different questions. `Woods::ReloadPolicy` answers the
second one; the table of path classes lives in
[INCREMENTAL_EXTRACTION.md](INCREMENTAL_EXTRACTION.md#what-a-change-actually-requires-reload-restart-or-neither).

**Publish** bumps `generation.json` — and only ever after a successful write.
A reader that sees generation N knows the files for N are already on disk, and
a run that failed leaves the number alone, so staleness stays honest.

## Restart triggers

Rails' reloader replaces autoloaded constants and nothing else. It does not
re-run initializers, re-resolve `Rails.application.config`, or rebuild the
schema cache — all of which Woods captures. So on a change to `Gemfile`,
`Gemfile.lock`, `config/application.rb`, `config/boot.rb`,
`config/environment.rb`, `config/initializers/**`, `config/environments/**`,
`config/database.yml`, credentials, `db/schema.rb` or `db/structure.sql`, the
daemon writes a degraded status, stops, and exits `75` for a supervisor to
restart it.

This is `rails/spring`'s contract, copied deliberately: Spring's staleness bugs
came from under-scoping exactly this set, so the boundary here is drawn on the
generous side.

The same escalation happens when the app *can't* reload at all — a boot with
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
within a debounce window), `degraded` (alive but *cannot* update — index frozen
at a known generation, reason attached), `stopped` (nothing is maintaining this
index). A stale answer is only dangerous when nothing says so.

Note that `SyntaxError` is a `ScriptError`, not a `StandardError`. Rescuing
only the latter would let a half-typed file kill the daemon.

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
reliably across container bind mounts** — `listen` documents this, and macOS
Docker VMs are the usual casualty. Since extraction typically runs inside a dev
container with the source bind-mounted, a host in that position should force
polling rather than trust a watcher that may sit silent while files change
under it.

Ignored by default: `.git`, `node_modules`, `tmp`, `log`, `coverage`,
`vendor/bundle`, `public/assets`, `public/packs`, `storage`. That ignore list is
what keeps a polling scan bounded.

## Placement

The spike asked for three placements to be compared and one chosen. Every
collaborator on `Woods::Watch::Daemon` is injected, so all three are reachable
from the same class — but the default is **(b), a dedicated daemon per
worktree**:

| Option | Verdict |
|---|---|
| **(b) Dedicated daemon** — *recommended default* | One extra booted app per worktree. Isolated: a crash, a restart, or a storm affects only the index. Lifecycle is drivable from worktree hooks. |
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

**Not yet measured, and the honest gap:** these are fixture-app numbers. A
large host app (thousands of units) has not been measured, and neither has
event latency across a container bind mount. #164's success criterion 2 asks
for both before the feature is called production-ready. Until then the daemon
is opt-in and documented as such.

## The freshness contract

A daemon that keeps the index current is only half the problem. The other half
is a reader that notices.

### Generations

Every extraction mode — full, incremental, targeted refresh, daemon cycle —
writes `tmp/woods/generation.json` as its **last** action:

```json
{ "number": 42, "token": "9f2c81ad3e4b7c05", "updated_at": "2026-07-27T04:55:12Z", "reason": "incremental" }
```

Two properties, both from the same rule — never advance a cursor over work that
didn't land:

- **Bumped last**, so a reader that sees generation N knows N's files are
  already on disk.
- **Not bumped on failure or on a no-op run**, so staleness stays honest.

`IndexReader` checks it at the top of every read: one `File.stat` of a
~100-byte file, parsed only when its mtime or size moved, caches dropped only
when the number actually advanced. That makes the MCP `reload` tool an
*optimization* rather than a correctness requirement — previously a long-lived
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
those edits. The fingerprint (a digest of `git status --porcelain`) lets a
caller distinguish "same dirty state as when the index was built" from "the
tree moved under me".

### Multi-file read consistency

The index is a directory, not a file, so "read the index" is many reads. Two
options were on the table.

**Per-request generation re-check — implemented.** Each read checks the
generation first, so the reader can never serve from a cache older than what is
published. `IndexReader#with_pinned_generation` extends that across a sequence:
freshness is checked once on entry and then held, so nothing already cached is
dropped and re-read at a newer generation partway through. `warmup!` uses it.

Its documented limit: pinning suppresses invalidation, it does not snapshot. An
artifact never read before is still loaded from disk as it stands when the
block reaches it. Guaranteeing more would mean materializing the whole index on
entry, which is what `warmup!` costs — per request.

**Atomic pointer over the whole payload — evaluated, not adopted.** Extending
the `IndexArtifact` `dumps/latest` pattern to all of `tmp/woods` (write
`gen-N/`, flip a pointer) would close the gap completely. It was rejected for
now because it changes the on-disk contract for every consumer that reads
`tmp/woods/models/…` directly — the Obsidian exporter, CI artifact chains,
`woods:validate`, the docs — and doubles disk during a write. The remaining
window is between two reads inside one call, versus the unbounded staleness
that existed before, so the cost/benefit does not currently favour it. Worth
revisiting if a concrete straddle ever bites.

### MCP `resources/updated` — evaluated, not implemented

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

## Embedding it

```ruby
# A host that owns its own event loop
daemon = Woods::Watch::Daemon.new(output_dir: Rails.root.join("tmp/woods"))
result = daemon.process(changed_paths)
# => { action: :incremental, state: :running, generation: 42, count: 1, duration_ms: 61 }
```

`#process` is one whole cycle and is the supported embedding point. `#run` only
supplies batches to it.
