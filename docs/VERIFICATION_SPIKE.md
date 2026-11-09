# Contributor verification workflow spike

This is an opt-in, local experiment inspired by pstack's verification lifecycle
and tstack's bounded review/continuation practices. It reuses Woods' existing
fixture rather than replacing its tests or importing either agent stack.

## What exists

- `script/verify-journey`: frozen-bundle doctor, bounded real Rails task journey,
  read-back assertions, source identity, retained logs and a structured receipt.
- `--negative-control`: process-local omission of incremental publication;
  proves the assertions detect the intended stale output instead of accepting
  any command that exits zero.
- `.agents/skills/woods-verification/SKILL.md`: launch, doctor, drive, evidence,
  cleanup and maintenance instructions.
- `spec/ci/verification_journey_spec.rb`: explicit false-positive checks.

The first journey reuses `spec/fixtures/incremental_runtime/hybrid_task.rb`.
Its app, SQLite database and publications are disposable and synthetic. It runs
real `woods:extract` and `woods:incremental` tasks in separate Rails processes.
Each full-extraction oracle runs in the same Rails process as its task, not an
independent cold process. It checks one nested job's queue against live runtime and full extraction and
requires publication progress. The existing fixture sets `CHANGED_FILES`;
it does not infer changes from missing Git metadata.

The receipt binds HEAD plus tracked/unignored file contents (including local
spike files), effective dependency lock and runtime versions. It refuses source
changes observed between start and finish. It is a local record, not signed
attestation, exhaustive environment capture or proof against concurrent changes
that are reverted during the run. Preserve the logs alongside it.

## Important limits

The original queue journey remains scoped to fresh tasks. The added
`script/verify-resident-journey CANDIDATE_CHECKOUT` covers a synthetic resident
helper edit and restoration, each with real Rails reload, publication progress,
concern retention and an independent cold-process comparator. Two independent
cold full extractions establish the baseline before edits. The candidate's
`spec/support/index_comparison.rb` owns normalization/exclusions.

The driver contains no product fix. #1040 retains ownership; an unfixed candidate
can and should fail the concern-retention assertion. Candidate production code,
its canonical comparator and the verifier's own files are separately identified.
Native filesystem watcher, private client acceptance, installed package and
other Rails/platform combinations remain unverified. Comparator parity is not
unqualified byte equality or reader freshness acceptance.

Diagnostics distinguish assertion, environment and harness failures. Parsed
observations are retained before validation; earlier evidence survives a later
failure. End identity is recorded even on failure, invalidating attribution if
candidate/dependency/verifier inputs changed. Commands record elapsed wall time.

## Contributor policy reconciliation

CONTRIBUTING remains the canonical policy. CLAUDE now agrees with failure-first
bug regressions, narrow checks during iteration, full unit/style checks before
review (or a specifically documented blocker), and local CI before push. No
existing gate is weakened. Omitted checks remain unverified, not waived by a
scoped journey or a passing hosted job.

## Matched comparison protocol

Run the same resident fixture raw and through the wrapper, five paired
repetitions with alternating order. Both arms validate exactly the same named
assertions. This isolates workflow overhead instead of comparing a cheaper
unchecked command with stronger verification. Record every sample, wall time,
child CPU, maximum RSS and load. Correctness is mandatory; cost is descriptive,
not a promised speedup or an invented adoption threshold. The raw arm already
contains behavioral checks, so defect detection is not unique to the wrapper.

The original queue journey versus resident coverage is a separate capability
comparison, not a performance comparison. Independent cold controls and reload
coverage do additional work and must not be advertised as faster extraction.
No development-throughput improvement has been measured.

## Bounded review and continuation checklist

Keep this evidence with the issue/PR, not a second local backlog:

1. Record candidate SHA and local diff identity, reproduction and exact commands.
2. Give each review finding a stable ID, affected contract, evidence and disposition
   (fixed, disputed with evidence, deferred to linked issue, or unresolved).
3. Bound a review experiment to three rounds. Exhausting the budget is unresolved,
   not approval. Preserve serious uncommon compatibility/security failures.
4. At handoff, inspect current head and uncommitted work, preserve attribution,
   independently reproduce the original failure, and recheck the source PR.
5. Before readiness claims, re-read exact-head CI, all review threads and aggregate
   review state, draft state and required policy. Access failure means unknown.
   Never turn a polling script's exit status or an Actions impact report into
   code-review approval. Maintainer merge permission remains required.

## Rollout decision

Evaluate whether the receipt plus negative control makes one existing real
journey easier to repeat and audit. Next, evaluate the resident proof against the exact client candidate without
taking over #1040 ownership.
Only expand to other journeys after the first one earns its maintenance cost.
Do not install upstream shipping/automerge behavior or hard-reset playbooks.

Sources: [pstack verification](https://github.com/cursor/plugins/tree/6b0300214a09fd6029cfb7077043125758cd1fd2/pstack/skills/create-verification-skill),
[pstack maintenance](https://github.com/cursor/plugins/tree/6b0300214a09fd6029cfb7077043125758cd1fd2/pstack/skills/maintain-verification-skill),
[tstack review loop](https://github.com/t3dotgg/tstack/tree/1085050f3baed1ac724caa4a8166145fb2ac88af/skills/sol-loop),
[tstack takeover](https://github.com/t3dotgg/tstack/tree/1085050f3baed1ac724caa4a8166145fb2ac88af/skills/takeover).
