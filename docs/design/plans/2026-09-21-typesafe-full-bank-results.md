# Full Rails bank: specific signals, shortlist limits, an additional finding

The supplied 204-question Rails bank now has an executable, versioned experiment
alongside the retained six-question implementation. Several specific checks
separated real fixture defects from their controls strongly. The maximum-Noul priority
ordering chosen for this experiment buried some of those signals under general
pattern warnings. That composition is an implementation choice, not a requirement
of the other agent's handoff, and its result is not evidence that Jev cannot
review Rails code.

The complete TypeSafe trial cost an estimated **$0.054246276** for 144 requests.
The 204-question arm averaged about **$0.000502 per request**, approximately
**$0.50 per thousand equivalent requests**. Cheap inference is established here;
useful downstream prioritization requires better evidence and interpretation.

The work is preserved in [draft PR #501](https://github.com/lost-in-the/woods/pull/501)
on `docs/typesafe-development-plan`. The initial checkpoint is `6293ba34`.
The [experiment README](../../../script/typesafe/rails_bank/README.md) and
[prospective protocol](../../../script/typesafe/rails_bank/protocol.md) describe
the commands and limitations. This remains outside the packaged gem. The optional
companion repository stays in backlog B-204; no new repository or shipping CLI
was created.

## What came from the supplied preparation

- All 204 source questions, their exact wording, Score levels and Choice options.
- Sixteen reviewer sections, all sixteen headline/secondary Scores, and three
  routing Choices. No persona prefixes were added to the questions.
- Explicit polarity, question kind, evidence requirements, and the advisory
  shortlist/report model. Ambiguous kind assignments are documented interpreter
  choices; the source bank did not classify every row individually.
- Complete selected Woods unit source, ordinary source/tests, schema and runtime
  premises; one published generation per candidate packet; separate
  source/revision/evidence records.
- Defect/control comparisons with execution outcomes kept outside model state,
  followed by fresh reasoning-agent review.

The [import audit](../../../script/typesafe/rails_bank/bank-corrections.md)
records the exact source snapshot and every metadata interpretation. There were
**no semantic question corrections** in this inference run. The original bank
version is `2026-09-19.1`; imported metadata interpretation is `2026-09-21.1`.

This is not the other project's complete application implementation: source
selection is curated for fixtures, siblings/search/git-history evidence is often
absent, and the general installed-application adapter remains future work. Both
arms use the same new state layout; these are new comparisons, not unchanged
replays of the old six-question captures.

## Corpus, execution, and operational evidence

Twelve defect/control pairs produced 24 independent Rails candidate snapshots.
The original four cover callback bypass, inherited authorization, job/transaction
timing and uniqueness. Eight new pairs cover nil memoization, default-scope
visibility, cache invalidation, unbatched loading, association preloading, tenant
lookup, ineffective assertions and atomic writes. The last three new families
were frozen holdouts before inference. No prompt tuning used their responses.

All 24 intended private oracle outcomes matched, with deep-current runtime indexes
and clean candidate revisions. Execution used Rails 8.0.5.1, Ruby 3.3.1 and SQLite.
The Woods runtime source matches `904226c9`; subsequent repository checkpoint
changes in this branch were experimental scripts/docs. Original candidates have
a follow-on commit recording generated schema: the request builder verifies that
isolated difference and preserves proposed versus materialized identities.

Portable fixture builders were separately verified on all 24 cases, plus eight
original cases rebuilt from a clean tracked testbed checkout without a database
or lockfile. Those fresh builds reproduce mechanisms with new provenance, not
the old historical commit IDs. Original source testbed files were preserved.

Each candidate received both banks three times, with the exact same state within
the pair of arms. All 204 questions fit in one request. Largest serialized request:
59,691 compact UTF-8 bytes. Budgeting used a conservative byte proxy with headroom;
provider token counts are the actual measurements, not that proxy.

| Arm | Calls | Input tokens | Free output tokens | Estimated input USD |
| --- | ---: | ---: | ---: | ---: |
| Six-question baseline | 72 | 431,154 | 13,065 | 0.018108468 |
| Full Rails bank | 72 | 860,424 | 310,506 | 0.036137808 |
| Total | 144 | 1,291,578 | 323,571 | 0.054246276 |

The bank has 34 times as many questions but used approximately twice the input
tokens because questions share state. Median request latency was about 0.45s
for the baseline and 0.66s for the full bank. The three-worker batch took about
28.86s across development and holdout phases, excluding fixture preparation and
reviewers. Rates are estimates using $0.042/M input and free output, not invoices.
[TypeSafe model documentation](https://docs.typesafe.ai/models)

All HTTP responses were 200. There were 143 fully valid responses and one with
an invalid `change_kind` Choice that selected a lower-probability option. Its
other 203 answers remained usable. Thus 14,687/14,688 full-bank answers and all
432 baseline answers passed validation. Twenty-one distribution-sum warnings
were compatible with the declared two-decimal rounding allowance; raw values
were never repaired. No retries or unknown-usage attempts occurred. Credentials
were fetched once and retained only in process memory for the capture.

## Specific checks that worked

These are median yes probabilities from three repeats. They are judged signals
about independently verified fixture mechanisms, not generated explanations.

| Question / mechanism | Defect | Control |
| --- | ---: | ---: |
| `ar_skips_validations`: bypassing the normalization callback | 0.89 | 0.08 |
| `perf_n_plus_one`: association access without preloading | 0.94 | 0.06 |
| `sec_unscoped_lookup`: access outside the authenticated tenant | 0.93 | 0.06 |
| `db_writes_not_atomic`: partial persistence after validation failure | 0.92 | 0.06 |
| `test_cannot_fail`: deliberately vacuous assertion | 0.97 | 0.08 |
| `job_enqueued_inside_transaction`: queueing before rollback | 0.83 | 0.28 |

The N+1 case illustrates additional granularity: the baseline's maximum signal
was 0.75, while the specific bank question reached 0.94 and identified what to
inspect. It does not follow that this always saves a reviewer effort, but it is
real evidence for the usefulness of a specialized question.

Other cases expose limits. The nil-memoization question returned 0.09 for a
literal `||=`/`find_by` implementation that repeats an absent lookup, versus
0.06 for the control; both ordinary specs and the private query-count oracle
were checked. The cache-invalidation question returned 0.94/0.93, failing to
recognize that the control's Active Record object key carries a version.
These remain preserved misses/false leads under this evidence and wording.

Two designated target mappings were wrong and must not be called model misses.
The uniqueness fixture adds an index, while `db_validation_without_constraint`
asks about **adding a validation**; that validation already exists. Likewise,
`ar_default_scope` asks about adding/widening a scope, while the fixture removes
its use in a query. Its `disposition` answer also lacks required sibling context.
Both are gaps in this trial's mapping/catalog coverage for those changes.

## Why the combined priority was worse

The exploratory priority was the maximum median eligible defect Noul. It was
never a calibrated probability for the whole change. For atomic writes, the
useful question separates 0.92/0.06, but both candidates get priority 0.97 because
`metz_argument_order` sees three arguments. On the preloading control,
`metz_reaches_through` reaches 0.93 despite the N+1 check correctly returning 0.06.
The source bank's broad default-defect classification contributes to this problem.

At the predeclared 0.8 band, the baseline alarms on 10/12 defect candidates and
0/12 controls; the full bank alarms on 11/12 defect candidates and 10/12 controls.
An alarm on a control is an **unverified lead**, not automatically a false positive:
the oracle only establishes its planted contract. The extra opportunities for a
high answer in a 204-question bank also make maxima incomparable as probabilities.

The initial nominal target-signal receipt is 8/12. Two mappings above are invalid;
this is not an eight-of-twelve bug-detection success rate. The [pair-level metrics](../typesafe-agent-guide/evidence/full-bank/metrics.md)
preserve that number and all incidental signals. A separately annotated, posthoc
mapping-audited subset is 8/10; it is not independent detection validation.

Among 4,896 candidate/question checks, 472 are out of scope after the applicability
correction, 3,703 have all three answers and declared evidence, and 721 remain
unassessed. Evidence being declared supplied does not prove that every implicit
premise was covered. Whole-app sibling/caller/search requirements are often absent.

## Presentation correction and reviewer comparisons

The first development callback report incorrectly included a test-only check when
no test files changed. Before downstream review, a separately versioned
**post-capture** interpretation (`2026-09-21.2`) applied the source bank's Tests and
Views section premises by changed paths. Coverage absence and regression-for-fix
kept their separate meanings. The correction is independent of probabilities and
labels. Original summary/reports and all raw inputs/answers remain preserved.

Observability has conflicting scope statements: its introduction restricts the
section to rescue/log/raise/job changes, but individual questions also cover new
integrations and sensitive parameters. Those answers remain provisional. No
answer-dependent regex filter was introduced to improve the results.

The initial six fresh reviewer runs used the same local `gpt-5.6-sol` configuration
with low reasoning effort, two paired order seeds, an eight-distinct-candidate
inspection budget, a 180-second prompt budget and a 210-second cutoff. All could
access the same source; assisted reviewers could start from the shortlist.

| Initial condition | Confirmed planted mechanisms, repeats 1 / 2 | Inspected candidates without a confirmed finding |
| --- | --- | --- |
| Ordinary review | 8 / 7 | 0 / 1 |
| Six-question assistance | 8 / 8 | 0 / 0 |
| Full-bank assistance | 6 / 6 | 2 / 2 |

All reported final mechanisms matched the independent fixture evidence. However,
several recorded tool outputs were empty or incomplete, three reviewers reported
truncation, and already-counted candidates could not be reopened to recover it.
Eight inspection log entries therefore establish attempted opens, not complete
model-visible evidence. These results remain observed pilot outcomes, with a
material limitation on arm comparisons. They are not used as proof of causal
quality or cost differences.

A separate six-session **delivery correction** permitted rereads without spending
another distinct-candidate slot, requested one candidate per tool call and an
adequate output allowance. It preserved the bank, provider answers, shortlist,
paired orders, model configuration and budgets. It is a posthoc comparison, kept
separate from the first six runs.

| Delivery-corrected condition | Planted findings, repeats 1 / 2 | Distinct candidates inspected, repeats 1 / 2 |
| --- | --- | --- |
| Ordinary review | 8 / 8 | 8 / 8 |
| Six-question assistance | 8 / 8 | 8 / 8 |
| Full-bank assistance | 5 / 7 | 5 / 8 |

One bank reviewer stopped after five candidates despite budget remaining; all five
had confirmed planted findings. Four dismissed-concern statements in each bank
report describe rejected questions or interpretations, not four wasted candidate
opens. The other bank reviewer found an additional mechanism on a control, verified
below. No established wrong final findings were identified.

All 46 recorded helper outputs in the correction match the expected bytes,
including one reread. One bank reviewer still reported client-visible truncation,
so delivery remains a disclosed limitation. Aggregate input/output usage is
recorded separately; cached input is a subset of input, not extra consumption.
The CLI does not report incremental token usage at each finding, so the intended
**tokens-to-first-real-finding metric remains unavailable**. Event times show when
a finding was emitted, not when the reviewer internally recognized it. These
small, correlated runs establish neither general efficiency gains nor incapability.

The [telemetry addendum](../typesafe-agent-guide/evidence/full-bank/reviewer-posthoc-addendum.md)
records the correction sessions separately:

| Arm, two sessions | Input tokens | Cached subset of input | Output tokens |
| --- | ---: | ---: | ---: |
| Ordinary | 849,672 | 715,648 | 5,909 |
| Six-question assistance | 754,640 | 593,280 | 6,319 |
| Full-bank assistance | 905,285 | 739,840 | 6,032 |

These are completed-turn counters, including repeated context. The richer bank
report did not demonstrate reduced total reviewer input here. First-emission times
for later-confirmed findings were 16.60/17.79 seconds ordinary, 16.17/19.33 seconds
baseline and 15.36/17.11 seconds bank. The latter includes the separately confirmed
conditional finding; that run's first planted finding was at 23.87 seconds. Two
orders, different inspected candidates and delivery caveats make these descriptive
endpoints, not a performance ranking. No reasoning-model dollar total is inferred.

## An additional mechanism found through assisted review

The second delivery-corrected full-bank reviewer identified lost updates in the
**atomicity control** (`f9a470ec`). A separate executable probe confirmed the narrow
claim in a disposable application copy: two transfers receive wallet objects read
before the first transfer commits, then both write balances derived from those
stale values.

| Shared wallet | Starting balances | After stale-object transfers | Fresh reads before each transfer |
| --- | --- | --- | --- |
| Destination | 100, 100, 0 | 90, 90, 10 | 90, 90, 20 |
| Source | 100, 0, 0 | 90, 10, 10 | 80, 10, 10 |

Both transfers complete. There is no `lock_version` column, optimistic locking is
disabled, and the service neither reloads nor locks the supplied records. This
reproduces an admissible stale-read/commit ordering; it does not execute concurrent
threads or prove that an unspecified caller supplies stale records. Fresh reads
are a comparison for this schedule, not a complete concurrency fix.

The original rollback-atomicity oracle still passes and its control label remains
unchanged. The original source, database and captures were preserved. This is a
**confirmed conditional additional mechanism in synthetic application code**, not
a Woods runtime bug. The reasoning reviewer articulated it and execution verified
it; the scalar Jev answers alone did not establish it. It was absent from the
ordinary and six-question reports in these runs, which makes it a useful observed
incremental finding, without proving that the bank caused the advantage.

The [probe](../../../script/typesafe/rails_bank/probe_stale_transfer.rb), selected
source and executable receipts are included with the
[portable evidence](../typesafe-agent-guide/evidence/full-bank/README.md). This is
also why alarms on a planted control cannot automatically be counted as false
positives.

## What to retain and what to change next

Retain the complete catalog and successful mechanism checks, the old baseline,
the source/revision ledger, and raw question results. Keep convention/fact signals
available for human navigation without turning them into correctness alarms.

Before proposing an installed-app companion, improve the interpreter: classify
each question's actual meaning explicitly; establish applicability and missing
premises; show mechanism questions alongside relevant source; and test an ordering
that cannot be dominated by a positional-argument convention. These are changes
to version and measure, not reasons to overwrite the present evidence.

The later user-supplied 27-question support-triage demonstration reinforces one
proposed direction: retain separate dimensions for routing and inspection, using
code to decide relevance. [Chapter 11](../typesafe-agent-guide/11-full-bank-review-lessons.md)
connects this to the live fan-out/routing/composition docs. It is a design insight,
not new trial evidence or proof that a weighted chart would improve results.

Separately correct target coverage for index/constraint changes, investigate the
nil-memoization miss and cache-versioning premise, and measure a real application's
packet size and retrieval quality. Those are bounded next experiments, not claims
that a reduced bank, a persona prefix, or a new threshold is already superior.

## Validation and preservation

- Existing experimental Ruby specs: 193 passed.
- Full gem suite: 9,401 examples, zero failures, three existing optional checks
  pending (optional tokenizers).
- RuboCop: 913 files inspected, no offenses.
- New offline Python checks: 45 passed; retained portable example checks: 28 passed.
- Booted fixtures, portable reconstruction, source hashes and original testbed
  preservation verified; no production Woods behavior changed.
- No new confirmed Woods bugs were found in this set. Planted fixture defects
  were not filed as GitHub bugs.

Reusable code, catalog, tests, curated metrics and examples are stored on the
remote draft branch. Raw local capture directories, databases and published
indexes remain excluded from Git. The earlier implementation and reports remain
available in the initial checkpoint and working branch history.
