---
name: woods-verification
description: Run and maintain Woods' scoped contributor verification journeys with exact evidence and negative controls. Not a release or merge gate.
---

# Woods verification spike

Read `AGENTS.md`, `CONTRIBUTING.md` and `docs/VERIFICATION_SPIKE.md` first.
Track this workflow under GitHub #1043; #1040 owns the separate concern fix. This
skill adds a reproducible behavioral check, not permission to ship or a new
backlog. Existing test, review, privacy and merge requirements still apply.

## Launch

Use an isolated worktree and an already provisioned, compatible Ruby/Rails
appraisal. Inspect the candidate and all local changes. Do not install a host
app, reuse a client database, change credentials, reset worktrees, or update
dependencies merely to run this check. Use a frozen lock. Run:

```
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile \
  bundle exec ruby script/verify-journey
```

## Doctor

The runner verifies the selected Woods gem resolves to this checkout and records
Ruby/Rails/SQLite, the effective Gemfile and lock digest, HEAD and source digest.
Missing dependencies or malformed evidence are failures, not skipped passes.
It does not provision anything. The fixture supplies explicit `CHANGED_FILES`
and intentionally has no Git provenance claim.

## Drive

The original fresh-task journey: a fresh process extracts a nested ActiveJob,
an indirect queue input changes, and another fresh task process incrementally
publishes. Read the queue through `IndexReader`, compare it with both the live
runtime and a same-process full extraction, and require generation 1 then 2. The unchanged
job's queue must move from `before` to `after`.

## Evidence

Read the generated `tmp/verification-*/receipt.json` and stdout/stderr. A process
exit of zero alone is insufficient. Do not translate `passed_scoped_journey`
into full-index equivalence, resident reload acceptance, client acceptance,
policy verification, CI success, or merge readiness.

Run the fault control separately:

```
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile \
  bundle exec ruby script/verify-journey --negative-control
```

It deliberately bypasses only the real `woods:incremental` task invocation in
its disposable child. Success means the verifier rejected the specific stale
publication while live runtime/full extraction observed the new queue. Other
failures do not count as successful fault detection. Keep both receipts.

## Cleanup

The runner removes only its disposable fixture tree. Evidence remains under its
unique ignored output directory. Each subprocess has a 180-second bound and an
owned process group; SIGINT, SIGTERM and timeouts reap unfinished children. Never delete unrelated logs, checkouts, processes or indexes.

## Maintain

Initial source anchor: `e97f3875f8f97a7e2bc8a18e9ed97f992596b88f`.
Covered path: `spec/fixtures/incremental_runtime/hybrid_task.rb`,
`lib/tasks/woods.rake`, `Extractor#extract_all/#extract_changed`, nested job
runtime discovery and `MCP::IndexReader#find_unit`. Read changes to those paths,
including moved definitions and new writers, before trusting an older receipt.
The anchor is a review aid, not automatic proof that every change is covered.

Re-run the positive journey, the fault control, and runner specs after changes.
Classify failures as product regression, harness gap, documentation drift or
environment blocker. Never weaken the expected queue/generation to get green.
If adding a mapped journey, provide its actual runnable entry point and limits;
do not list planned coverage as executed coverage. Review all implemented
journeys when maintaining this skill. Change-triggered use is manual in this
spike; no new scheduler, CI gate or external monitor is installed.

## Resident reload journey (expanded spike)

`script/verify-resident-journey CANDIDATE_CHECKOUT [--negative-control]` uses the
selected candidate's frozen Rails bundle and production code. Set an absolute
`BUNDLE_GEMFILE` belonging to that candidate. The verifier may live in another
worktree; its own script/fixture digest is bound separately.

The synthetic fixture performs independent cold full/full extraction controls,
then helper edit → Rails reload → new extractor → incremental publication →
independent cold comparison, followed by restoration and another cycle.
It reuses the candidate's canonical `IndexComparison`; read that comparator's
exclusions before describing the scope. It does not run the native watcher or
client app. The fixture's final JSON is evidence, not its exit status as a test
verdict: the runner validates the complete named-check list.

#1040 owns the product regression/fix. On an unfixed candidate this journey
should report an assertion failure; do not weaken the oracle or silently switch
candidate to get a pass. `--negative-control` deliberately omits publication and
must fail at the named progress assertion after all baseline controls pass.

Receipts now distinguish `failed_assertion`, `blocked_environment`,
`failed_harness`, and `interrupted`. Parsed observations survive subsequent
failure and are checkpointed before assertions. A changed candidate/dependency
or verifier invalidates attribution, including on a failing run. Do not count
such an invalidated run as an observed product failure.

Use `script/verification/compare_workflow.rb CANDIDATE_CHECKOUT 5` only for an
explicit measurement task. It alternates paired raw and wrapped executions of
this identical journey and applies identical behavioral assertions to both.
The wrapper adds preflight, provenance and durable diagnostics; compare its
cost rather than claiming that it makes extraction faster. Record spread and
machine load, not just median. This does not measure developer throughput.
