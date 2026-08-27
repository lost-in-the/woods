# Release V2 Verification Record

## Branch Baseline

- Branch: `audit/v2-final-release`
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

### Unresolved Release State

- No requested Round 5 concurrency defect remains unresolved in the exercised suites.
- The full default suite is not green because of the nine pre-existing Console integration failures above.
- The findings ledger still marks `V2-MCP-001` (task cancellation does not stop associated work) and `V2-CONFIG-001` (configuration/runtime disagreement) as confirmed, deferred, and release-blocking. This round did not change either finding.
