# Jev as a bounded source investigator

Jev selected useful supporting source more often than the static rule in this
pilot, but that improvement did **not** produce an additional verified defect
lead. This supports testing source navigation separately from defect judgment;
it does not establish that either workflow improves a downstream reviewer.

The live run used four new booted Rails defect/control pairs, two repeats, and
**80 requests costing an estimated $0.01187277**. Necessary-card coverage improved
from **8/16 static runs to 12/16 adaptive runs**, entirely because Jev found the
calendar configuration that the static rule missed. All high-band defect leads
concerned the same invoice-rounding defect: two static repeats and one adaptive
repeat. The other adaptive rounding answer was 0.78, below the frozen 0.80 band,
with the correct calculation category and helper location.

Read the [frozen protocol](../../../script/typesafe/investigation/protocol.md),
[reproduction instructions](../../../script/typesafe/investigation/README.md),
[accounting receipt](../../../script/typesafe/investigation/results/2026-09-21-accounting.json),
and [source adjudication](../../../script/typesafe/investigation/results/2026-09-21-adjudication.md).
The original six-question and full-bank implementations remain unchanged. This
is source-checkout research for the planned separate companion, outside the gem.

## What this experiment compared

Each case began with its complete changed physical source, diff, explicit intent,
shared runtime premises and five neutral supporting-file menu entries. Supporting
bodies were unavailable until selected. Both arms had a two-file inspection limit
and the same four focused questions: contract violation, missing context,
mechanism category and supporting source location.

The static rule preferred direct constant references, then filename-token overlap
with source and intent. The adaptive rule used a closed Jev Choice over remaining
files, `stop` and `need_context`. A second selection received the first file's
body. Code performed only the selected read; Jev did not execute source or generate
an explanation. Every adaptive run used both reads; there were no stops or invalid
routes in this capture.

A shared initial 204-question scan supplied at most eight eligible defect-Noul
hints to adaptive routing. Tests/Views premises, question direction and declared
context requirements limited those hints; all 204 raw answers were retained.
The static selector and both final focused requests did **not** consume those
hints. Consequently this run cannot establish the bank's incremental benefit:
there was no no-bank routing arm. The static workflow could omit the initial scan
entirely; the paired experiment retained it as a shared stage.

The prepared source, menus, questions, protocol, schedule, runner/dependency hashes
and private execution evidence were frozen before inference. Candidate/repeat
order was seeded and arm order alternated. There were no prompt changes, retries,
fallbacks or reruns after seeing answers. Conservative byte-budget checks covered
every allowed zero/one/two-file combination without truncation.

## Fixtures and actual evidence

Woods runtime was pinned to `9f55ee840e22b160a148c48da3dcef1210d07ed7`.
Disposable applications ran Rails 8.0.5.1, Ruby 3.3.1, SQLite and the test Active
Job adapter. All eight ordinary specs passed, all eight private mechanism checks
matched their intended outcomes, and all eight indexes were deep-current at a
clean matching candidate revision. Database changes stayed in disposable copies.

Three pairs deliberately shared identical initial source and diff. Their
pre-existing helper, caller or configuration differed. These are controlled
background-premise comparisons, not three independent real-world regression
histories. The reservation pair instead differed in `requires_new: true` and
shared its background source. Menu paths, IDs and common runtime premises matched
within each pair. Labels, required-card lists, private outcomes and timezone
premises stayed outside initial provider state.

| Pair | Source-verified mechanism | What the arms observed |
| --- | --- | --- |
| Invoice rounding | Rounding each 0.335 line before summing produces 1.02; the required aggregate rounding produces 1.01. The control helper retains precision. | Both read the helper and ordinary spec. Both selected calculation and the correct helper on the defect; controls selected `none`. |
| Fixed-field JSON input | The caller passes string keys while the consumer fetches symbol keys, silently replacing an explicit heading and day window with defaults. The control caller normalizes keys. | Both read the caller, but defect probabilities stayed low and source location was `none`, despite selecting `input_contract`. |
| Nested reservation | A rejected reservation inside a materialized caller transaction leaves persisted availability at -2 instead of 3 without the savepoint. The control rolls back the inner write while retaining the caller's attempt row. | Neither read the concrete batch caller. Static read two models; adaptive read the ordinary spec and pool model. Intent still allowed a conditional nesting concern. |
| Configured calendar day | UTC boundaries violate the application's New York calendar day near midnight; the UTC-configured control satisfies its contract. | Only adaptive read the configuration, but it still answered `none` for the New York defect. Static answers were similar for both variants without that premise. |

The configured-card coverage diagnostic is private ground truth used only during
analysis. It does not prove those cards are the only possible sufficient evidence,
or that reading them guarantees comprehension. These deliberately small menus
do not test discovery across a monolith or automatic graph-based menu construction.

## Preserve the misses and the component answers

The table shows contract-violation Nouls in repeat order. They are model judgments,
not measured probabilities of actual failure. The frozen high-lead composition
also requires a valid non-`none`/non-`unknown` mechanism and a supplied source
location. It is an advisory reporting band, not a passing or blocking threshold.

| Case | Static, repeats 0 / 1 | Adaptive, repeats 0 / 1 | High leads, static / adaptive |
| --- | ---: | ---: | ---: |
| Rounding defect | .80 / .80 | .78 / .80 | 2 / 1 |
| Rounding control | .27 / .32 | .29 / .32 | 0 / 0 |
| JSON defect | .32 / .41 | .32 / .35 | 0 / 0 |
| JSON control | .25 / .27 | .24 / .23 | 0 / 0 |
| Reservation defect | .62 / .59 | .61 / .61 | 0 / 0 |
| Reservation control | .63* / .64 | .63 / .57 | unassessed + 0 / 0 |
| Calendar defect | .63 / .62 | .30 / .34 | 0 / 0 |
| Calendar control | .63 / .65 | .20 / .22 | 0 / 0 |

`*` The contract Noul was valid, but the accompanying mechanism Choice failed
validation: it selected `transaction_boundary` at 0.36 while `none` was 0.37.
The [Choice contract](https://docs.typesafe.ai/primitives/choice) describes the
selection as the highest-probability option. The composite remained unassessed;
no answer was silently repaired or counted as a correct negative.

There were **79 fully valid requests out of 80**, all HTTP 200. Component answers
remain available for the partially invalid request. Some valid independent answers
also disagreed semantically: reservation requests could select `none` as the
mechanism while pointing to changed source as evidence of a violation. A category
or location alone must not become a finding. Lower-band transaction/time concerns
also appeared on controls; absence of high-band control leads is not proof of
low false-investigation cost.

The calendar result is particularly useful: the adaptive arm improved evidence
retrieval and lowered its missing-context answers, yet still missed the known defect. We should
not infer that supplying the right file automatically fixes judgment. Conversely,
the JSON category separated defect from control even while the other components
failed to form a supported lead. Preserve such signals for downstream evaluation
without relabeling them as confirmed model discoveries.

## Cost and operational results

| Stage | Calls | Input tokens | Free output tokens | Estimated input USD |
| --- | ---: | ---: | ---: | ---: |
| Shared 204-question scans | 16 | 126,038 | 69,030 | .005293596 |
| Static focused calls | 16 | 40,422 | 3,670 | .001697724 |
| Adaptive routing and focused calls | 48 | 116,225 | 7,197 | .004881450 |
| Actual total, shared stage counted once | 80 | 282,685 | 79,897 | **.011872770** |

The estimate uses [published pricing](https://docs.typesafe.ai/models) checked
September 21: $0.042/M input, free output. It excludes coordinator/reviewer work
and is not an invoice. There was one credential lookup for this capture, zero
retries, no missing-usage attempts, and no unfinished jobs.

If each standalone arm included its own initial scan, the static allocation would
be $0.006991320 and adaptive $0.010175046 for sixteen runs. These are alternative
workflow allocations, not additive actual spending. Static without its unused
scan would cost $0.001697724. The price difference is tiny; potential value should
be judged through saved reviewer effort and useful findings, neither established
by this pilot.

The serial requests consumed 37.004 seconds in aggregate: 9.889 shared, 6.391
static and 20.725 adaptive. Those exclude preparation, local processing and source
verification. Total observed source bytes across focused runs were 11,236 static
and 12,195 adaptive. They count repeated inputs and are not unique source size or
token savings. More useful selection did not mean less source in this run.

## Reuse corrections and validation

The exact inference runner is preserved in commit `6c06c6ca`. A subsequent
read-only publication review found that offline summarization assumed every
persisted attempt had latency. A process interrupted after recording `started`
could therefore make the summary fail. The post-capture correction counts unknown
latencies explicitly and preserves unfinished work; it changes no request,
judgment, routing decision or complete-run measurement. Future preparations also
retain runner/dependency source snapshots alongside hashes. The live capture was
not rerun to adopt that correction.

Validation after implementation: 19 offline investigation tests and seven docs-
audit tests passed. The interruption regression failed before the correction and
passed after it. The full default gem suite passed **9,401 examples, zero failures,
three optional-tokenizer pending checks** (seed 21213); RuboCop inspected 915 files
with no offenses. The fixture lane supplied eight booted Rails examples and eight
private outcome checks. No production runtime or public gem interface changed,
so no additional Rails-version matrix or live-backend lane was needed. The docs
audit separately ran 51 targeted Ruby examples at its pinned main revision.

Fixture/source adjudication was performed by the fixture author, with separate
accounting/privacy and publication reviewers. This is source/oracle verification,
not blinded independent detection. Original raw requests, responses, private
execution receipts and indexes remain local under
`tmp/typesafe-investigation-2026-09-21/run-final/` and `fixtures-verified/`.
Portable receipts deliberately omit local machine paths and application databases.
The synthetic defects are not Woods runtime bugs and were not filed as such.

## Next useful comparison

Keep the application companion small. On fresh application cases, compare static
source selection, Jev selection without scan hints, and selection with hints.
Give a downstream reasoning reviewer equal inspection access and measure verified
findings, false leads investigated, actual total usage and elapsed time. Broad
bank signals may still be useful at this price; their incremental value needs that
comparison. Do not discard a case solely because a composite is below 0.80.

For documentation, the concurrent [quick audit](2026-09-21-typesafe-release-docs-audit.md)
suggests a related next step: keep section-level readability/relevance, but make
accuracy checks claim-specific and request missing source before judging. Neither
workflow should convert missing evidence into a passing review.
