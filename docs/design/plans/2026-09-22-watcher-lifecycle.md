# Watcher startup and supervision implementation plan

Status: proposed; implementation has not started. Names and examples below describe
the planned interface, not capabilities of the published gem.

Revised after two independent adversarial reviews on 2026-09-22. The resolved
design decisions are recorded at the end of this plan.

Baseline: Woods `0d0a2b0de8b6a2f1649cd7dc4f73de1349f4f164` on 2026-09-22.
The existing automatic-maintenance guide is an uncommitted draft. Preserve it and
the unrelated TypeSafe work while implementing this plan.

## Outcome

After enabling automatic maintenance once, a developer uses the application's
normal startup command. Woods catches up missed changes, maintains the index,
recovers from changes requiring a fresh Rails boot, and stops with its owner.
The existing MCP connection observes published generations without reconnecting.
Docker and Grove are optional deployment choices.

Keep the current extraction daemon. Add one shared lifecycle implementation with
native, Puma, and external-supervisor entry points. Automatic maintenance stays
an explicit development opt-in; installing or requiring the gem alone starts no
background processes.

## Evidence and existing contracts

- `lib/tasks/woods.rake` implements `woods:watch`: capture a boot snapshot, boot
  Rails, run `Woods::Watch::Daemon`, and exit 75 when a fresh boot is required.
- `lib/woods/watch/daemon.rb` already implements startup catch-up, pending-path
  preservation, duplicate-start claims, and per-cycle writer locking. Reuse these.
- `spec/integration/watch_startup_spec.rb` proves fresh-process reconciliation;
  `spec/integration/watch_daemon_spec.rb` proves extraction behavior.
- The install generator creates configuration and a legacy migration. The agent
  configuration tool manages MCP registration and instructions. Neither installs
  watcher supervision today.
- The documented bare Procfile entry is incomplete under Foreman: an intentional
  child exit ends the process group instead of restarting that child.
- The large-host report verifies the externally supervised Docker/Grove route,
  including a live initializer restart and worktree switching. This does not
  validate a native supervisor or Puma adapter that has not been implemented.

Relevant precedents:

- [Tailwind Rails](https://github.com/rails/tailwindcss-rails/blob/6523db16e2a4af2264579012495ee88b8d65fb76/README.md#live-rebuild): standalone
  watcher, generated Procfile integration, and an optional Puma plugin.
- [Solid Queue](https://github.com/rails/solid_queue/blob/73602fe39b95d48d99f0f419293c566310dae3e2/README.md#puma-plugin): standalone command
  and server-managed background processes.
- [JS bundling](https://github.com/rails/jsbundling-rails/blob/a29703e36bdf9c91716ef210d17d32081800d75d/README.md#javascript-bundling-for-rails):
  installation wires the watcher into the development command.
- [Foreman's shutdown behavior](https://github.com/ddollar/foreman/blob/f65ddba83932bd4670e014389d6e27ea1e20b469/lib/foreman/engine.rb#L421-L470)
  means Woods must absorb planned child restarts in its managed mode.
- [Rails' bin/dev template](https://github.com/rails/rails/blob/484729f64c9dc75117bb835a4a31f5185abf0879/railties/lib/rails/generators/rails/app/templates/bin/dev.tt)
  simply starts the server. Detect the actual command, not the filename.

## User-facing modes

| Mode | Normal startup | Lifecycle owner |
|---|---|---|
| Existing Procfile development | The application's existing `bin/dev` or manager command | Process manager starts the Woods launcher; launcher manages extraction children |
| Simple Rails/Puma development | `bin/rails server` or the application's Puma command | Opt-in Puma plugin starts the same launcher |
| Docker, Grove, systemd, other supervisor | The application's existing service startup | External supervisor manages the existing `woods:watch` process |
| Manual | An explicit extraction or watch command | Developer |

The native and Puma modes share one foreground launcher; they do not run
extraction on a web request thread. The Docker route keeps its existing exit-75
contract. Each index has one selected supervision arrangement.

## 1. Shared foreground launcher and lifecycle contract

Proposed executable: `woods-watch`. The default native command is equivalent to:

```text
woods-watch -- bin/rails woods:watch
```

The argument after `--` is an explicit argument vector, not a shell string.
Applications with custom task layouts can select their actual entrypoint.

Primary ownership: new `exe/woods-watch`, focused collaborators under
`lib/woods/watch/`, child reporting hooks in `lib/tasks/woods.rake` and the
daemon's actual startup boundaries, and executable registration in `woods.gemspec`.

### Required behavior

- The launcher stays outside Rails. Start each extraction child with a fresh Ruby
  process and the application's bundle, working directory, and environment.
- Re-resolve the child bundle after a lockfile change. Inherited Bundler activation
  from a long-lived parent must not silently pin the child to the old dependency
  set. Preserve intentional application environment and `BUNDLE_GEMFILE` selection.
- Keep the task's pre-environment boot snapshot. Do not invoke the daemon in a
  fork that merely inherits already-initialized Rails state, and do not strengthen
  the existing source-freshness claim beyond the boundary actually measured.
- Preserve the existing task's output-directory precedence. A launcher default
  must not override an application's configured custom output directory.
- Use the versioned child lifecycle channel defined below. Do not parse human
  log messages or infer successful publication from an alive PID.
- Reuse per-cycle writer coordination. Duplicate prevention in managed mode is
  scoped to a single host/process namespace; see the explicit ownership boundary
  below. The launcher never holds the extraction writer lock while idle or in backoff.
- Keep logs visible. Never copy environment contents or application exception
  payloads into broadly readable status files; retain bounded diagnostic codes.

### Exit and recovery policy

| Event | Managed launcher behavior |
|---|---|
| First child start | Boot, perform initial extraction or catch-up, then watch |
| Child exits 75 | Reap it and start a fresh child; retain pending paths; do not propagate this planned exit to Foreman or Puma |
| Rapid repeated exit 75 | Apply bounded backoff and report restart-loop degradation; do not spin |
| Rails boot fails or child crashes | Remain visibly degraded and retry with 1, 2, 4, 8, 16, then at most one retry per 30 seconds; reset only after 60 seconds following confirmed startup completion |
| Extraction fails inside a live daemon | Let the daemon retain its generation and retry work; do not restart an otherwise functioning child |
| Launcher receives INT/TERM | Stop scheduling retries, forward shutdown to its owned child, wait with a bounded grace period, reap, and exit |
| Invalid launcher arguments or impossible executable | Fail clearly before starting a child; distinguish setup errors from recoverable application boot errors |
| Idle timeout configured | Reject a nonempty `WOODS_WATCH_IDLE_TIMEOUT` at managed-mode preflight/startup, including zero; require it to be unset. Raw task behavior stays unchanged |
| Child exits 0 without launcher-requested shutdown | Park with an explicit unexpected-stop diagnostic; do not report successful completion, respawn indefinitely, or exit the Foreman entry |
| Missing/incompatible/malformed child protocol | Stop and reap only the owned child, then park with a compatibility/setup diagnostic until the launcher is restarted |
| Another watcher already owns this index | Park with an ownership-conflict diagnostic until normal owner restart; do not overwrite the owner's status, automatically take over, or exit the Foreman entry |

Backoff waits must be interruptible and use an injectable monotonic clock.
All zero exits still terminate a Foreman group, so managed mode supports no idle
shutdown. Initial invalid configuration can fail startup clearly; it must not
schedule a delayed exit after the development stack appears healthy.

### Child protocol and readiness

Use bounded, versioned messages over a private inherited descriptor, correlated
with a random launcher token and a child-attempt token. Minimum events are:
bootstrap hello, compatible Woods task loaded, root/index identity resolved,
watch backend ready, startup reconciliation completed or degraded, and terminal
reason. Handshake validation is separate from receiving a process exit code.

Emit reconciliation completion from the daemon after its real startup obligations
are discharged. `run_started` currently writes `running` before backend readiness
and catch-up; neither that record nor an empty task log establishes completion.
Report degraded startup without claiming completion, and report later recovery.

Install parent-death monitoring before Bundler/application boot, not only inside
the rake task. A nonzero boot failure before the task handshake may be retried;
an explicitly incompatible version or a zero exit without the required protocol
parks the launcher. Unexpected EOF while the child is alive, malformed messages,
and a lost child channel are protocol failures. Never interpret them as success.

Use a configurable boot/handshake deadline (initial default: 300 seconds), with
phase-specific diagnostics. It ends when Rails boot and task identity complete;
it is not an extraction timeout. A slow full extraction or writer-lock wait may
remain pending with honest status. Test a hung Bundler/initializer separately
from a long, valid extraction.

### Ownership boundary

The current raw daemon deliberately treats foreign-host claims as stale
(`Daemon#stale_claim?`, with a pinned spec). Existing claims therefore do not
provide global cross-host exclusion. Do not imply that wrapping them changes this.

For the first managed implementation, add a conservative managed-child claim
policy at the atomic claim decision: foreign/unknown ownership is refused, even
if heartbeat trust is enabled. The raw task's existing compatibility behavior is
unchanged. Test same-host managed/raw races and refusal of an existing foreign
claim. Do not implement automatic standby takeover.

A raw daemon starting later in another namespace can still reclaim a foreign
claim under its existing rules. Mixed-host raw/managed launchers sharing one index
are therefore unsupported: choose one external owner for that deployment. A
global exclusion guarantee would require a separate ownership change shared by
raw and managed launchers, with recovery and compatibility tests. It is not a
hidden prerequisite or a guarantee of this launcher work.

Use an owned process group where supported. Handle parent disappearance as well
as normal shutdown so killing the launcher does not leave a resident extractor.
Choose a control-pipe/parent-monitor implementation with real process tests;
never signal a process solely because its PID appears in an old status file.
Kill the launcher during blocked Bundler and initializer phases in tests. Verify
descriptor closure across forks/execs: unrelated descendants must not keep the
parent-liveness pipe open after its owner dies.

**Completion evidence:** real subprocess tests cover exits 0/75/error, backoff,
shutdown during boot and retry, duplicate starts, parent death, pending-work
recovery, changed bundle selection, and paths containing spaces. Keep the existing
raw `woods:watch` exit behavior unchanged.

## 2. Native installation and removal

Proposed generator: `bin/rails generate woods:watch --mode=procfile|puma|external`.
This is the eventual interface; expose a mode only in the PR that implements and
tests it, including its startup configuration.
Mode selection is explicit. Preflight can recommend a mode based on the existing
startup files, but must not silently enable two launch paths.

Primary ownership: a focused generator under `lib/generators/woods/`, installation
helpers under `lib/woods/watch/`, and generator/installation contract specs.

- Generate an application-relative `bin/woods-watch` wrapper around the shared
  launcher. Verify the installed application task entrypoint before rendering it.
- In Procfile mode, add one owned Woods entry without replacing web, CSS, JS,
  worker, or debugger configuration. Initially support an explicitly selected,
  verified Foreman startup command and its exact Procfile. Preserve `bin/dev`.
- If `bin/dev` only starts Rails, recommend Puma mode when available. Explicit
  Procfile mode without a verified manager must refuse before writes and show the
  supported manager invocation or available alternative. Never install an unused
  Procfile and report automatic maintenance enabled. Do not introduce a generic
  shell-script rewriter or silently install a process-manager gem.
- Custom application tasks use explicit child argv; custom startup wrappers need
  an explicit manager/Procfile selection. Acceptance runs that application's
  selected normal startup command, not only a separate Foreman test invocation.
- Support Rails generator preview and repeated installation. Use receipt-owned,
  reversible fragments. Reuse the agent-config conflict checks and atomic-write
  pattern, not its absolute-root identity or default `0600` file mode. Define a
  watcher-specific receipt with application-relative owned paths/fingerprints;
  generated executable wrappers are explicitly `0755`. Keep local absolute paths,
  process identities, and validation evidence in separate ignored runtime state.
- Provide update/removal behavior that removes only owned files or fragments.
  Changing modes retires the old owned startup entry instead of accumulating
  watchers. Actual running owners are stopped through their normal manager.
- In external mode, provide the verified child command and integration handoff.
  Do not synthesize or replace a host application's Compose anchors and mounts.
- Keep MCP configuration ownership separate. Integrate the watcher into the
  setup runbook and plugin workflow without expanding `woods-agent-config` into
  a generic infrastructure editor.

**Completion evidence:** existing multi-service Procfile, plain Rails `bin/dev`,
custom Rails task wrapper, custom index directory, repeated install, edited
managed section, update/remove, and moving between worktrees. A real Foreman
smoke must prove initializer changes restart only the extraction child while
the web process remains alive. A fresh clone/worktree containing committed setup
must run, update, and remove it without depending on the original checkout path.
Reject configured managed idle TTL before a delayed shutdown becomes possible.

## 3. Optional Puma adapter

Proposed configuration, generated only for the selected Puma mode:

```ruby
plugin :woods if Gem.loaded_specs.key?("woods")
```

The availability guard keeps Puma bootable when Woods is excluded from the
application bundle's development group. Do not use a broad `LoadError` rescue
that would hide a broken installed plugin. Verify the normal bundled development
startup activates Woods before Puma evaluates this configuration.

The adapter additionally enforces development-only startup using Puma's finalized
environment at lifecycle start. Plugin availability is not the environment guard.
An unset `RAILS_ENV` must not imply development when Puma selected production
through `APP_ENV`, `RACK_ENV`, `-e`, or its configuration.

Primary ownership: new `lib/puma/plugin/woods.rb`, thin lifecycle adapter helpers,
Puma-specific integration specs, and narrowly scoped appraisal/CI additions.

- Spawn the same launcher from the Puma master lifecycle, once per server/index,
  never once per worker. The child executes the application wrapper in a fresh
  process; it does not use the web application's loaded model objects.
- Propagate the finalized environment consistently to the launcher and Rails
  child, resolving contradictory environment variables instead of inheriting an
  accidental different environment. Non-development or unknown environment means
  no automatic watcher start. Test all supported environment selection mechanisms.
- Shut down and reap owned children on server stop/restart and detect abrupt
  parent loss. Preserve debugger stdin and the web server's signal handlers.
- Planned watcher restarts and recoverable indexing failures leave Puma running;
  expose degradation through logs and status. Do not copy Tailwind's policy of
  stopping Puma whenever the watcher child disappears.
- Support explicitly tested Puma majors (target 6, 7, and 8 on compatible Ruby
  versions). Keep Puma optional: requiring Woods must work without it. Unsupported
  versions/platforms receive a precise standalone-launcher fallback.
- Cover single-process and clustered/preloaded Puma. Phased/hot restart behavior
  needs explicit tests or an explicit unsupported-mode diagnostic before shipping.
- Ordinary console, runner, migration, test, and production startup must remain
  free of watcher autostart. Production autostart is outside this adapter's scope.

**Completion evidence:** real server startup produces an index; edits and restart
inputs publish through the same MCP connection; the web PID survives planned
watcher restarts; multiple workers produce one watcher; server shutdown leaves
no child or grandchild. Test configuration mistakes and duplicate external owners.

## 4. Status, Docker/Grove guidance, and installed-version accuracy

Primary ownership: watcher status helpers, `spec/mcp/woods_status_spec.rb`,
`docs/{GETTING_STARTED,AGENT_SETUP,WATCH_DAEMON,DOCKER_SETUP,CONFIGURATION_REFERENCE,TROUBLESHOOTING}.md`,
the automatic-maintenance draft, and affected `plugin/skills/` files.

- Preserve `watch_status.json` and its daemon-liveness meaning. After index identity
  resolves, use separate versioned supervision records keyed by random launcher
  token, carrying host/PID, child attempt, heartbeat, starting/retrying/parked state,
  retry timing, and bounded reason. A non-owner never replaces the active owner's
  record. Writes and cleanup are ownership-checked; reads and stale-record retention
  are bounded and use explicit age/host/PID rules. Never send signals from records.
- Before the first resolved index identity, diagnostics are logs-only. Do not guess
  `tmp/woods` or write supervisor files there if Rails fails to boot. Index-visible
  supervision diagnostics become available only after identity is established.
- Correlate active supervision with the daemon's actual child/owner identity;
  show other live launchers as conflicts, not redundant healthy maintainers. A
  live parent without a maintaining child must not satisfy daemon-deference checks.
- Expose supervision details additively in `woods_status` when available; existing
  indexes and raw-daemon installations continue to work. Keep source freshness and
  last publication distinct from both process-liveness records.
- Correct the Railtie/autostart and SessionStart/idle-revival claims. Describe
  the new Puma adapter separately from generic Rails initialization.
- Show native and Docker entrypoints accurately, including custom Rakefiles,
  polling, database readiness, inherited mounts, and restart policies.
- Document one restart owner: native/Puma use the shared launcher; existing
  Docker services can continue supervising the raw task. Avoid stacked independent
  retry loops that obscure failures.
- Grove guidance adds the watcher to the applicable shared or isolated service
  list and keeps source/index paths aligned. No dependency on Grove is introduced.
- Setup handoff records the chosen owner, actual command, resolved root/index,
  completed startup catch-up, and a demonstrated edit plus restart recovery.
- Keep installed-version checks in plugin guidance. Mark all new launch features
  unreleased until a package contains them; bump the plugin version when skills
  change and pair marketplace metadata changes through a cross-linked PR.
- Regenerate public-surface inventory and add changelog fragments with the code
  changes. Track tasks through issues/projects; link this plan as design context.

## 5. Validation and delivery

### Required integration scenarios

| Scenario | Acceptance |
|---|---|
| No prior index | Initial full publication succeeds; startup is not reported as completed merely because a process exists |
| Existing beta4 index | Reader compatibility; catch-up without unnecessary rebuild on an unchanged tree |
| Edit/create/delete | Correct unit and graph changes; existing MCP process observes each publication |
| Initializer/schema/lockfile change | Fresh child state, pending work preserved, no exit-75 loop, web process survives in managed modes |
| Invalid initializer, then correction | Last good generation readable; visible retry state; automatic recovery |
| Rapid config edits during startup | Bounded restarts; no missed work or falsely fresh generation |
| Protocol mismatch, unexpected exit 0, or hung boot | Visible failure/parked state; never successful startup; owned child cleanup; slow valid extraction is not timed out |
| Managed idle TTL inherited from shell | Preflight/startup rejects it clearly; no delayed zero exit that shuts down Foreman |
| Manual extraction alongside watcher | Existing writer serialization; idle watcher does not hold the writer lock |
| Same-host duplicate starts and multiple Puma workers | One active watcher; accurate parked-conflict status; no status clobber or automatic takeover |
| Existing foreign owner | Managed child refuses ownership conservatively; mixed-host raw/managed exclusion is not claimed |
| Puma environment selection | No autostart in production/test via APP_ENV, RACK_ENV, RAILS_ENV, CLI or config; development child matches finalized Puma environment |
| Production bundle excludes Woods | Puma boots with committed plugin configuration and no Woods gem available; no plugin lookup failure or autostart |
| Stock/custom bin/dev and fresh cloned setup | Never claim an unused Procfile is active; verified normal command launches Woods; wrappers executable and receipts portable |
| Worktree A to B / separate agent slots | Correct source/index per owner; prior tree unchanged after switching |
| INT/TERM/parent death | Owned children reaped; no restart after shutdown; unrelated processes untouched |
| Upgrade and rollback | Raw task remains usable; remove new launcher/plugin config before downgrading; existing index remains readable |

Run meaningful subprocess tests first, then the full default suite and RuboCop.
Run the existing booted extraction/watch suites plus new launcher integration
across the repository's compatible Ruby/Rails matrix. Add dedicated Puma-major
jobs and one real Foreman job with pinned compatible dependencies; do not broadly
update the application bundle to make these tests pass.

Validate a locally built, installed gem as well as source checkouts: executable
registration, optional Puma loading, generated wrappers, and documentation links
must survive packaging. Reuse the existing large-host evidence for unchanged
daemon behavior; request only a focused managed-restart and final-package smoke
if that host adopts a new launch mode.

### PR sequence

1. **Launcher and child lifecycle:** shared managed process, tests, additive
   executable, readiness/ownership/status contracts, and command/diagnostic docs.
   Include supervision-record semantics and truthful status in this PR, not later.
2. **Native setup:** owned generator/wrapper/Procfile integration and real Foreman
   acceptance. Depends on PR 1. Expose only completed `procfile` and `external`
   modes; a plain Rails startup needs an explicitly selected supported manager
   until the Puma mode ships.
3. **Puma adapter:** shared launcher integration and versioned server tests.
   Depends on PRs 1 and 2. Add the `puma` generator option, safe generated config,
   environment gate, and user/plugin guidance in this same PR.
4. **Operational handoff:** remaining Docker/Grove corrections, setup/status
   presentation, and paired plugin guidance. Each earlier PR still documents
  the behavior it introduces; this PR reconciles the complete workflow.
5. **Release validation:** installed-gem smoke and updated release issue evidence
   after the supported launch modes are merged and green.

Give each implementation PR an independent review and passing relevant CI before
merge. When delegated, assign file ownership explicitly; the generator, status,
and adapter changes share contracts and must not be developed against incompatible
versions of the launcher. Use the established two-correction-round limit before
coordinator takeover.

Minimum release requirement: the advertised native and external-supervisor paths
must pass their applicable lifecycle scenarios, with raw-task compatibility
explicitly distinguished from managed recovery. Puma support is part of this plan and is
shipped only after its own acceptance passes; if it is deferred to a later release,
remove all pre-release promises and installer choices for that mode.

This plan does not authorize a version transition, tag, or publication. It does
not expand static graph coverage, change extraction facts, introduce automatic
embedding refresh, or start an MCP reader outside its client lifecycle.

## Adversarial-review decisions

Two independent reviews covered lifecycle correctness and installation/release
compatibility. Adopted corrections: finalized Puma environment enforcement;
plugin availability guarding when the production bundle excludes Woods;
managed idle-TTL rejection; explicit single-host ownership scope with no takeover;
real readiness/protocol events and pre-boot parent monitoring; per-launcher status
ownership with logs-only diagnostics before index resolution; verified manager
selection without rewriting `bin/dev`; portable receipts and executable modes;
and PR ordering that never advertises an unimplemented installer mode.
