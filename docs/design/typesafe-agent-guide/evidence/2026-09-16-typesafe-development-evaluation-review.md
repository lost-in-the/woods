> Portable evidence copy. Historical status and proposed commands are preserved; this is not a promise that the planned APIs were implemented. Links and the installed-skill location were normalized for portability. Raw ignored captures and external source snapshots are not included.

# TypeSafe plan: research and review record

Plan: [implementation plan](2026-09-16-typesafe-development-evaluation.md).
Research/review date: 2026-09-16. Repository baseline: `55a74ea4`.
Scope: design only; no implementation or TypeSafe inference calls.

## Reviewer allocation and limitation

The user requested four agents to review the full plan and iterative correction until no blockers remain. The environment accepts only three other agent threads; spawning a fourth returned `agent thread limit reached`. The review therefore consists of three independent agents plus the author/root agent acting as the fourth reviewer. The fourth perspective is not independent. This limitation was disclosed before plan review and must remain in the handoff.

| Reviewer | Scope |
|---|---|
| `coverage_research` | Assertion adequacy, evidence closure, labels, dataset/evaluation integrity. |
| `bug_research` | Historical oracles, blinding, security/trust boundaries, package compatibility. |
| `performance_research` | Benchmark applicability, recommendation metrics, performance evidence. |
| Root/author | API contracts, operational limits, persistence/replay, failure semantics, integration. |

All independent reviewers read the installed TypeSafe skill, live relevant documentation/cookbooks, and Woods code. They performed a second research pass before reviewing the assembled plan, not merely a review of the earlier conversational recommendation. Primary links and repository evidence are in plan section 14.

## Research pass 2 decisions

- Curated evidence packets precede automatic source/test selection.
- Aggregate SimpleCov data is not per-example execution or assertion evidence.
- Model judgments, execution results, gold labels, and infrastructure errors remain separate.
- Historical replay uses verified paired execution and explicit blinding; it does not establish unknown-bug discovery.
- Benchmarks require task-specific measurement of applicability and scope.
- Scripts, fixtures, and plan stay outside packaged gem paths; ordinary CI stays offline.
- No fixed model-version or confidence-accuracy guarantee is inferred from TypeSafe's typed API.

## Review round 1: revision 1

| ID | Severity | Reviewer | Concern | Disposition in revision 2 |
|---|---|---|---|---|
| COV-1 | Blocking | Coverage | Baseline predictions/scores and strongest-baseline selection were underspecified; conclusions could vary by implementation. | Exact feature/verdict/score table, development-selected frozen comparator, paired family bootstrap rules in section 11. |
| PERF-1 | Blocking | Performance | Ranking irrelevant benchmarks as adverse findings optimizes the opposite of useful benchmark recommendation. | Separate recommendation profile: P(direct), local candidate groups, fixed two-per-change budget, distinct metrics/gate. |
| API-1 | Blocking | Root | Returned model mismatch was recorded but not rejected, allowing an unplanned model to enter a comparison. | Explicit requested/expected identity policy; mismatch invalidates response and halts session. |
| API-2 | Blocking | Root | Per-read timeout and unbounded read could evade total time/byte limits; resume attempt accounting lacked durability. | Connection-scoped total timeout, streamed bounded response, encoding policy, fsynced attempt ledger, lifetime cap. |
| API-3 | Blocking | Root | Mandatory historical Git reads would make ordinary offline tests fail in shallow CI. | Materialized curated evidence for replay; explicit full-history source-verification mode and curator attestation. |
| BUG-1 | Nonblocking | Bugs | Historical arm/oracle pairing was described but not structurally enforced. | Local pair/oracle IDs, exact two-arm validation, matching scenario/oracle digests. |
| BUG-2 | Nonblocking | Bugs | Blinding cannot exclude provider pretraining exposure to published fixes. | Explicit historical-replay limitation in section 7. |
| COV-2 | Nonblocking | Coverage | Completeness review and intended assertion failure should be explicit schema fields. | Attestation reviewer/revision/digest; oracle failure-kind and target-example fields. |
| PERF-2 | Nonblocking | Performance | Excluding operational failures could hide selection bias. | Intent-to-evaluate metrics, failure distributions, no-operations-error advancement requirement. |
| PERF-3 | Nonblocking | Performance | Candidate coverage, claim smoke cases, and workflow timing needed clarity. | Independent phased profile delivery, per-profile corpora, conditional-candidate limits, elapsed/backoff/preparation/replay timing. |

Round-1 verdicts: coverage changes requested; performance changes requested; bugs approved within its scope; root changes requested. No implementation was performed while blockers were open.

## Review round 2: revision 2

| Reviewer | Verdict | Remaining notes |
|---|---|---|
| Coverage | Approved; no blockers | COV-1 and supporting concerns resolved; no further correction requested. |
| Bugs | Approved; no blockers | Clarify that incomplete rankings can improve numerically by losing a false positive; failed runs still prevent advancement. |
| Performance | Approved; no blockers | Keep fresh timing outside deterministic replay content; match benchmark comparator selection to macro per-change recall. |
| Root/author | Approved; no blockers | API/model/persistence/CI blockers resolved. Tighten persisted provider metadata to allowlisted fields and reject extra answer IDs. |

Revision 3 incorporates all remaining notes. It changes no proposed scope or authority. Round 2 established zero blocking concerns across these four review perspectives; final confirmation checks the exact revised text.

## Review round 3: revision 3

| Reviewer | Final verdict |
|---|---|
| Coverage | Approved; no blockers in coverage, evidence, corpus, or evaluation design. No further corrections. |
| Bugs | Approved; no blockers. All prior comments resolved; historical validity/blinding/provenance/packaging remain consistent. |
| Performance | Approved; no blockers. Benchmark metrics and deterministic replay corrections confirmed. |
| Root/author | Approved; no blockers in API/operations/integration design after re-reading final changes. |

Open blocking concerns: **0**. The only subsequent plan edit changes its status from pending confirmation to reviewed. There are three independent reviewer agents and one author review, not four independent reviewers.

Research and review do not establish model usefulness; live evaluation and independently verified oracles remain implementation prerequisites where stated. No implementation or live inference was performed. Planning validation checked Markdown links/fences/whitespace, gem packaging exclusion, and the final working-tree scope; runtime tests were not run for this planning-only change.
