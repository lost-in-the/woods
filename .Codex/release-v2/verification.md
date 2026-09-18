# Release V2 Verification Record

The August sections below are historical. The [2026-09-18 readiness audit](#readiness-audit-2026-09-18) records the newer frozen baseline and its limits; it is not approval to publish a final artifact.

## Branch Baseline

- Branch: `release/2.0.0-readiness` (audit began on `audit/v2-final-release`)
- Base SHA: `8fea1922886ac34991820ddf6a97dae94fe06fa3`
- Base relationship command: `git merge-base HEAD 8fea1922886ac34991820ddf6a97dae94fe06fa3`
- Expected result: `8fea1922886ac34991820ddf6a97dae94fe06fa3`

## Clean Baseline Evidence

- Ruby: `ruby 4.0.1`
- Dependency bundle: `BUNDLE_PATH=$PWD/vendor/bundle` (run from the repo root)
- PATH: `PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`
- Command: `PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=$PWD/vendor/bundle bundle exec rake spec`
- Result: `6,304 examples, 0 failures, 4 pending, random seed 20215, 1m18.87s`
- Coverage command: `PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=$PWD/vendor/bundle COVERAGE=true bundle exec rake spec`
- Coverage result: `91.17% line coverage`; opt-in integration suites were excluded from that baseline.
- Main CI: [run 32302116061](https://github.com/lost-in-the/woods/actions/runs/32302116061), `21/21` jobs green.

## Inventory Contract

- Write command: `PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=$PWD/vendor/bundle bundle exec rake release_v2:write_surface_inventory`
- Verification command: `PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=$PWD/vendor/bundle bundle exec rake release_v2:verify_surface_inventory`
- CI location: the `lint` job runs the verification command before RuboCop.
- Contract source: `.Codex/release-v2/surface-inventory.json` is generated from code and must be regenerated in the same serial ledger update that changes a public surface.

## Ledger Discipline

`findings.json` updates are serial: update one finding, run its reproducer and the inventory verification command, then record the next finding update.

## Task 4 Fix Round 5 (2026-08-20)

- Fix base: `72fb5640bce4558d490bca5af9229b919472e013`
- Pipeline lock: a persistent sibling guard file and `flock(LOCK_EX)` now serialize every primary-path transaction. Acquisition retains `O_EXCL`; stale retirement, release, ownership touch, and restore retain token checks without recursive flocking. The sibling location keeps the guard stable when `woods:clean` removes the index directory.
- Index MCP reads: a server-local prepend wrapper pins every `IndexReader` tool handler, resource, and template for its complete production dispatch. Reload remains unpinned until it enters the exclusive reload API. Direct `IndexReader` callers remain responsible for pinning multi-read sequences.
- Pipeline cooldown reset: missing, malformed, and irrelevant state return `false` after a shared read lock without opening for write. Relevant resets take an exclusive lock, re-read, and atomically preserve unrelated records.

### TDD Evidence

- Pipeline lock regressions failed first on five race cases; the deterministic cross-process rename-gap reproducer acquired through the missing primary path before the guard was added.
- MCP dispatch regressions failed first on five handler-level pinning cases before the server wrapper was installed.
- Pipeline cooldown regressions failed first on six missing/irrelevant read-only and public repair cases before the no-op read path was added.
- The repository-wide run then exposed four assertions around the guard's initial in-directory location and `woods:clean`; the sibling-guard contract failed before the final placement change and passed afterward.

### Verification

- Public repair/reload handlers: `17 examples, 0 failures` (seed `49487`).
- Lock, cooldown, direct-reader, and clean races: `85 examples, 0 failures` (seed `1847`).
- Full Index MCP suite: `817 examples, 0 failures, 1 pending` (seed `20694`); the pending example requires Linux procfs.
- Coordination/operator and integration suites: `121 examples, 0 failures` (seed `592`).
- Official Ruby MCP client: `3 examples, 0 failures` (seed `10830`).
- Packaged gem smoke: `11 examples, 0 failures` (seed `25523`).
- MCP Inspector: `6 examples, 0 failures, 2 pending` (seed `26189`); Inspector 2.2.0 sends the removed legacy `logging/setLevel` request after modern negotiation in both transports.
- Surface inventory verification: passed; the generated inventory records the server wrapper registration source without changing tool counts or conditions.
- Release inventory/workflow/gemspec contracts: `43 examples, 0 failures` (seed `2746`).
- RuboCop: `580 files inspected, no offenses detected`.
- Full default suite: `6,478 examples, 9 failures, 5 pending` (seed `48427`). All nine failures are in `spec/integration/console_server_spec.rb`, reproduce in isolation (`34 examples, 9 failures`), and have no diff from the fix base. They were left unchanged under this round's no-Console constraint.

### Historical state after PR #245 (superseded by the readiness audit below)

- No requested Round 5 concurrency defect remains unresolved in the exercised suites.
- The nine historical Console integration failures are no longer present in the current branch gates. Woods PR #245 commit `898e396` passed all 23 required checks, including unit suites on Ruby 3.0–4.0, booted extraction on Rails 6.0–8.1, official-client MCP transports, live backends, coverage, security, lint, build, and PII checks ([CI run 33108637107](https://github.com/lost-in-the/woods/actions/runs/33108637107)).
- The most recent complete local default-suite run before the final documentation-only review rounds reported `6,896 examples, 0 failures, 3 pending`; the later focused release/config/reload/snapshot/graph suite reported `187 examples, 0 failures`.
- `V2-MCP-001` is resolved as an explicit documented limitation: durable tasks support completion/reconnect polling, while `tasks/cancel` returns a stable unsupported-method response and no longer claims to stop work.
- `V2-CONFIG-001` is resolved by the provider/store validation, resolved-config persistence, and preset-reopen work now covered by builder, config-resolver, and preset-persistence specs.
- `findings.json` contains no confirmed release-blocking finding.


## Readiness audit: 2026-09-18

### Baseline and scope

The frozen audit baseline is `59b0085f21629edc698fb20138d19c5fc75d07f5`
(`2.0.0.beta2`). This is a bounded review of publication/generation pinning,
MCP and Console safeguards, source inputs, session assembly, hooks, and package
installation. It does not substitute for the final release-SHA matrix or a
whole-branch review after subsequent changes. No version transition, tag, or
publication was performed.

A disposable static self-map and actual bundled MCP stdio requests established
source ownership and the 14-tool packaged registration. They do not establish
runtime Rails extraction behavior.

### Default suite and coverage calibration

The default suite ran under Ruby 4.0.6 with coverage enabled and a private `/tmp`
namespace: **8,896 examples, zero failures, three optional-dependency pending
examples**, seed `42970`. Line coverage was **92.56% (25,078/27,093)** and branch
coverage **80.00% (8,065/10,081)**.

Two earlier green PR CI runs independently measured the same default-process
surface:

| Tested PR / head | CI run | Line | Branch |
| --- | --- | --- | --- |
| #435 / `0c5b1b76` | [35300283249](https://github.com/lost-in-the/woods/actions/runs/35300283249) | 92.79% | 80.15% |
| #436 / `1deaa9c8` | [35300524851](https://github.com/lost-in-the/woods/actions/runs/35300524851) | 92.68% | 79.99% |

These results justify raising the aggregate line gate from 85% to **90%**.
They do not justify an 80% branch gate: one green run is already below it.
Six production files have no hits in this process and 16 of 332 files are below
70% line coverage. Subprocess, installed-artifact, Rails, and live-backend
coverage is not collated here; these figures are not evidence those files are
untested. Per-file/branch gates and broader contract coverage remain in #231.

### Independent regression and concurrency checks

- Publication, pinning, freshness, source inputs, hooks, and exports:
  **232/0**, seed `2253`.
- MCP authentication/origin/HTTP and Console SQL, model, credential, context,
  and redaction safeguards: **440/0**, seed `12442`. This is a focused regression
  run, not a new live-database security audit.
- Current replacements for historical P1 reproduction commands: **300/0**,
  seed `5543`. The obsolete Console bridge paths in `findings.json` now point
  to the executable-mode and CLI contracts; their separate replay is **53/0**,
  seed `50639`.
- Ruby 3.0.7 Solid Cache/session, exclusive reload, and thread-helper soak:
  **40 fresh processes, 61 examples each, 2,440 total, zero failures**. Seeds
  alternate `45779` and `6657` ten times, then cover `6660` through `6679`.
  These are focused files at those seeds, not replays of the original entire
  randomized suite. They establish neither the cause nor a fix for #375/#395;
  both issues remain open.

The refresh hook's one-MiB input cap does not bound time waiting for EOF. A
controlled producer holding stdin open outlived a one-second command timeout;
no queue was written. Native event producers close stdin, and no supported
client failure was demonstrated. The canonical watch guide now states that the
private command deadline begins after input collection, validation, and queue
publication. This is a documented scope limit, not a new cancellation promise.

### One baseline artifact, two clean installed environments

`gem build --strict` built the frozen baseline once. SHA-256:

```text
1b12b6ebb4d4f2ef25332732ee529677e82518e15dde95956498ae254fdfbc31
```

The same bytes were installed into fresh gem homes in two unprivileged Docker
containers, with the source checkout read-only and external networking disabled
at test time. Both ran the actual installed-package integration lane with
`WOODS_RUN_PACKAGE_SMOKE=1`, `WOODS_RUN_PACKAGE_INSTALL=1`, and seed `23218`:

| Environment | Installed-package result |
| --- | --- |
| Ruby 3.0.7 / Rails 6.0.6.1 | 23 examples, zero failures |
| Ruby 4.0.6 / Rails 8.1.3.1 | 23 examples, zero failures |

Both resolved MCP SDK 1.5.1. Dependencies were prepared before disabling network;
no external provider/backend service was exercised. The initial Ruby 4 harness
omitted Ruby's bundled-gem path and failed before examples; preserving
`Gem.path` corrected the harness. This is baseline package evidence, **not** a
final release artifact or a claim of upgrade/downgrade compatibility for every
stored format. The separate exact-floor lane checks MCP 1.2.0 and the other four
declared direct dependency minima.

### Baseline package/privacy scan

The independent scan covered 1,054 tracked files and 380 packaged files
(eight executables). Every packaged file matched its frozen tracked source.
The repository credential scanner's 30 patterns produced 77 tracked matches
and three packaged matches; manual review identified fixtures, disposable
localhost CI credentials, and documented examples. Supplemental path and
literal-credential checks found no confirmed private host path or real credential.
This covers the frozen tree/package, not all Git history, runtime environments,
unknown secret formats, or remote secret-scanning alerts.

The scan also found installation guides using `~> 2.0` while only 2.0 prereleases
were published. That constraint excludes prereleases. The setup correction must
link the canonical published-version choice and retain installed-capability
checks; plugin updates must not imply the application gem was upgraded.

### Findings and remaining release work

The audit reproduced a wrong-source session context when a controller and an
earlier dependency share an identifier. [PR #437](https://github.com/lost-in-the/woods/pull/437)
rejects ambiguous dependency identities before returning context, leaves absent
controllers in the timeline without a source reference, and pins the whole read
to one generation.
The broader identity migration remains #213.

Exact runtime-floor testing also exposed Rails 6.0.0 positional middleware
options on Ruby 3. The compatibility fix retains keyword validation and request
security checks. Its installed-artifact probe explicitly uses an API-style
application with static serving disabled: upstream Rails 6.0.0 middleware has
additional Ruby 3 compatibility limits. It does not claim arbitrary Rails 6.0.0
applications boot on Ruby 3.

#232 remains open for the final candidate: repeat its required adversarial,
exact-SHA matrix, artifact/metadata/privacy, and upgrade/rollback gates after
release preparation. Do not reuse this baseline's package digest as final
release evidence. Actual APFS/virtiofs host performance acceptance in #305 also
remains unverified here. Optional major backend/provider upgrades and deferred
features are not prerequisites established by this audit.
