# Using a full Rails question bank without losing useful signals

The September 21 follow-up implemented the supplied **204-question bank**, keeping
the older six-question experiment intact. It tested twelve Rails defect/control
pairs, three repeats per arm, then fresh reasoning reviewers. It demonstrated
useful mechanism judgments and one additional verified conditional issue through
assisted review. It did not establish a superior general shortlist or production
pre-push tool.

Start with the [full results](evidence/2026-09-21-typesafe-full-bank-results.md),
[complete metrics](evidence/full-bank/metrics.md), and
[source bank](evidence/full-bank/source-question-bank.md). The
[catalog](evidence/full-bank/catalog.json) makes interpretation inspectable.
The source-checkout runner and builders are available in
[draft PR #501](https://github.com/lost-in-the/woods/pull/501); the portable archive
includes selected real request/response bytes, not every historical capture or
the Docker caches required for fixture reconstruction.

## What an implementation should preserve

Treat the question bank as data with a version, provenance and executable
contract. This import preserves every original question, Score level and Choice
option: 185 Nouls, 16 Scores and 3 Choices in sixteen sections. The source version
is `2026-09-19.1`; metadata interpretation is `2026-09-21.1`. No question wording
was semantically corrected during inference. Read the
[import audit](evidence/full-bank/bank-corrections.md) before reusing its defaults.

Each catalog question carries an identifier, section, primitive type, instruction,
direction, kind, declared context requirements and source location. Score criteria
and headline roles are explicit where applicable. A receiving project should
preserve these dimensions separately:

| Dimension | Purpose | Failure to avoid |
| --- | --- | --- |
| Direction | `yes_is_bad`, `yes_is_good`, `higher_is_worse`, `higher_is_better`, `unordered` | Treating good coverage or an existing regression test as a defect |
| Kind | Fact, defect or convention | Turning the presence of a pattern into a correctness finding |
| Evidence | Supplied, not supplied, unknown; per-question requirements | Treating an unsupported answer as assessed or passed |
| Applicability | Whether this question describes this change | Scoring test-only questions when no test changed |
| Primitive | Noul, Score or Choice | Interpreting a Score as probability that a change is wrong |
| Presentation role | Headline, secondary dimension, navigation | Inventing an independent vote from a reviewer heading |

The bank supplies breadth. It does not eliminate the need to decide these
contracts. Defaults inherited from the source are not necessarily useful for
ranking: `metz_argument_order`, for example, asks about positional arguments and
can dominate a maximum even when a more specific correctness question is low.

## Keep source, identities and evidence requirements distinct

Build a packet from complete selected source and one pinned Woods generation per
candidate. Generated chunks are retrieval aids; they can omit the method-body
difference that makes a fixture fail. Preserve physical source and changed tests
alongside the relevant unit's `source_code`, schema header, runtime premises and
relationships. Concerns can make unit coordinates differ from physical lines.

Record three independent facts: whether the captured index was current, which
checkout and intended revision range it describes, and which evidence each
question received. A current index for yesterday's commit is not evidence about
today's diff. A complete selected unit does not establish complete application
context. Empty callback annotations are not proof of no effects; supply the body
and relevant helpers, and disclose unresolved behavior.

This runner validates **captured** deep-freshness/clean-revision receipts and
serialized source hashes. Its fixture collectors checked live state at capture.
It does not recheck an application worktree each time a frozen request is prepared.
The original four pairs materialized schema in a follow-on commit; preparation
verified that isolated difference and retained both proposed and materialized
identities. General application adapters need their own clean/dirty/revision
policy instead of assuming this fixture exception applies everywhere.

The actual state contains review policy, intent, changed paths, diff, source
regions, selected units, helper/test evidence, runtime premises, graph context,
PR metadata and explicit evidence limits. A region can refer to an included unit
to avoid duplicate source. A reference must resolve within the same request;
putting only a local path in state does not let Jev read that path.

Private labels, oracle outcomes and hidden tests stay outside requests. Ordinary
application tests remain legitimate evidence. Freeze the state and compare arms
on identical bytes so evidence selection does not silently become another
experimental variable. Record serialized requests, responses, model, versions,
source hashes, usage and latency before deriving reports.

## Cheap inference changes what is worth attempting

All 204 questions fit in one request for these curated packets. The largest
compact UTF-8 request was 59,691 bytes; preflight used a conservative byte proxy,
not a claim that bytes equal provider tokens. The provider's actual usage is the
cost basis. For larger applications, select coherent evidence and split questions
with complete shared state; do not silently cut off a method to make a request fit.

The 72 full-bank calls used 860,424 input tokens and 310,506 free output tokens,
an estimated **$0.036137808**, about **$0.000502 per request**. The 72 baseline calls
cost **$0.018108468**. Together, 144 calls cost **$0.054246276** at $0.042/M input
and free output. The larger bank asks 34 times as many questions for approximately
twice the input cost because they share state. Median latency was about 0.66s
versus 0.45s; these are small-packet measurements, not a monolith latency promise.

Consequently, retaining a broad bank for exploration can be economical even when
only some answers help. The expensive failure may be reviewer distraction,
duplicate source or a bloated report. Measure those separately before concluding
that narrowing the bank itself is necessary. Reasoning-model usage, cached-token
rates, extraction time and human investigation are separate from the Jev estimate.

Load the provider key once for a capture, through an environment variable or a
credential subprocess whose arguments contain a secret reference rather than a
secret value. The runner invokes an argument array, never a shell; the key remains
in memory, with redirects and automatic environment proxies disabled. This avoids
one secret-manager lookup per request without saving the key in a repository.

## Validate answers individually and preserve imperfect runs

All responses were HTTP 200, but one Choice selected a lower-probability option.
That invalidated one answer, not its 203 valid neighbors: 14,687/14,688 bank
answers passed, as did all 432 baseline answers. Twenty-one probability-sum
warnings fit the predeclared two-decimal rounding allowance; raw answers were
preserved. Unknown usage and failures must remain in the accounting; this run
had neither retries nor unknown-usage attempts.

Three valid repeats and declared supplied evidence were required for a question
to enter the shortlist. A Noul has no independent confidence field. Missing
premises therefore come from the ledger, not a guessed confidence band. Scores
remain dimensions with their own confidence; they are not Noul probabilities.

The first report exposed a Tests/Views applicability mistake. A separately
versioned, post-capture presentation (`2026-09-21.2`) corrected those source-bank
premises by changed paths, preserving initial reports and answers. This was not
a new model run. Observability's conflicting section/question scope remained
provisional instead of being filtered opportunistically. The summarizer refuses
to overwrite a versioned presentation. Preserve this distinction between raw
inference and changed interpretation in any project.

## Specific signals and a poor combined priority can coexist

Median defect/control probabilities included 0.94/0.06 for N+1, 0.93/0.06 for
tenant lookup, 0.89/0.08 for callback bypass, 0.92/0.06 for non-atomic writes,
0.97/0.08 for a vacuous test and 0.83/0.28 for a job queued before rollback.
The bank therefore supplied useful, focused leads on independently checked
mechanisms. The [preloading sample pair](examples/README.md) includes exact
request/response bytes so an agent can inspect the evidence behind one signal.

Our experimental priority took the maximum median eligible defect Noul. That
choice was **ours**, not a requirement of the supplied handoff. Both atomicity
candidates scored 0.97 overall because a three-argument warning overwhelmed
the useful 0.92/0.06 transaction answer. At the 0.8 band, the bank alarmed on
11/12 planted defects and 10/12 controls; the baseline alarmed on 10/12 and 0/12.
These are candidate alarm counts, not directly comparable probabilities or a
general accuracy score. More questions create more opportunities for a high value.

There were also real limits: the literal absent-result `||=` memoization defect
scored 0.09 versus 0.06; cache invalidation scored 0.94/0.93 despite a versioned
object key in the control. Two designated targets were incorrect: questions about
adding validations or adding/widening default scopes did not describe the actual
index/query edits. Preserve those mapping errors as experiment errors, not Jev
misses. The nominal 8/12 target-alarm count and posthoc mapping-audited 8/10 subset
are not an independently established defect-detection rate.

## Downstream review supplied an additional finding

Six original and six separately corrected reviewer sessions used the same locally
configured coding model, two order seeds and eight distinct-candidate inspection
slots. The correction allowed rereads, one candidate per tool call and a larger
output allowance. It addressed incomplete recorded evidence from the first six
sessions; the two experiments must not be pooled.

Corrected ordinary and baseline-assisted runs each confirmed 8/8 planted findings
in both repeats. Full-bank runs confirmed 5 and 7; the first stopped after only
five candidates. The second also identified stale-instance lost updates on the
atomicity control. A separate executable probe reproduced lost credits or debits
when overlapping wallet snapshots were loaded before the first transfer committed.
Fresh loading before each sequential transfer preserved totals for that schedule.

The original rollback contract still passed. The new test did not run concurrent
threads or establish how a real caller loads records. Its value is a confirmed
conditional additional mechanism beyond the planted oracle, discovered through
assisted reasoning and independently executed. It was absent from the other arms'
reports, but this small observation does not prove that the bank caused an
advantage. See [probe evidence](evidence/full-bank/stale-transfer-result.md).

All 46 corrected helper outputs matched the expected recorded bytes, yet one
reviewer still reported client display truncation. Audit both. An inspection-log
entry proves an attempted open, not necessarily usable attention to every byte.
The CLI exposes aggregate token usage, so **tokens to first confirmed finding
could not be measured**. Timestamped emissions are useful but not a substitute.

## What the vendor's 27-question demonstration adds

A user-supplied screenshot shows one support-triage request returning separate
impact, urgency, scope, security and routing judgments. It displays $0.000081 and
114 ms for that request. The screenshot supplies neither full inputs nor a
correctness audit or completed comparator timing; those numbers are an example,
not a general benchmark.

Its useful design clue is to retain a vector of judgments for different decisions.
The live [fan-out documentation](https://docs.typesafe.ai/patterns/fan-out)
explicitly recommends asking speculative questions together and letting code use
only the relevant answers. This supports keeping the full bank while improving
its consumer, rather than assuming that fewer questions are the cure for noise.

For review, a Choice could suggest a next inspection, applicable Nouls could flag
specific mechanisms, and Scores could organize dimensions. A single route must
not hide a second issue or imply that missing evidence is safe. An uncertain route
should leave ordinary review available. These are proposed adaptations, not new
inference results or a verified improvement to this trial.

[Intent routing](https://docs.typesafe.ai/patterns/intent-routing) also suggests a
way to save expensive work: direct an appropriate check to existing deterministic
tools, source retrieval, or a focused reasoning review. The specific code-review
mapping needs testing. [Composite scoring](https://docs.typesafe.ai/patterns/composite-scoring)
permits explicit, inspectable weights over dimensions; a chart or weighted
navigation score can be useful without being a probability that a change is bad.
Neither those docs nor this screenshot validates our maximum-over-204 ordering.

## What community implementations add

The [Made with Jev showcase](https://madewithjev.com/) was reviewed on September 21.
Its speed/cost figures are author reports, not an independent audit. Three linked
implementations offer concrete ideas for a next experiment. Source URLs below
identify the inspected projects; upstream `main` may change. No external project
code was installed or executed in this review.

**Jev Review: investigate a signal in stages.** Its
[judgment definitions](https://raw.githubusercontent.com/devagrawal09/jev-review/main/src/review/judgments.ts)
and [workflow](https://raw.githubusercontent.com/devagrawal09/jev-review/main/src/review/workflow.ts)
screen files, select a concrete hunk with `noMatch`, classify a mechanism with
`noIssue`, score conditional severity, then select a reviewer. The inspected
follow-ups are typed Jev calls, not a handoff to a heavier reasoning model.
For Woods, this suggests binding a signal to source before calling it a finding.
The implementation still uses maximum screening probability to select profiles,
and severity assumes the suspected concern exists. Those choices do not resolve
our priority problem. A severity response must not be mistaken for confirmation
of its premise.

**Blink: allocate a limited search budget.** Its
[search](https://raw.githubusercontent.com/ellipsis-dev/blink/main/src/search.ts)
and [walker allocation](https://raw.githubusercontent.com/ellipsis-dev/blink/main/src/walkers.ts)
use a Choice over existing file/directory names and distribute an integer search
budget. Walkers share directory decisions; a hundred walkers are not a hundred
independent judgments. It reads names rather than source, so the output is a
retrieval proposal. A Woods adaptation could nominate likely callers, schemas or
siblings when a ledger says context is missing. The next step must actually read
and verify the selected evidence before changing that ledger.

**Jev Ultrafast: ask speculatively, execute conditionally.** Its
[implementation](https://github.com/browser-use/jev-ultrafast/blob/main/jev_ultrafast/model.py)
asks for an operation and compatible targets together; code validates and uses
the target for the selected operation, retaining raw answers. Options come from
observed controls. Its [evidence limits](https://github.com/browser-use/jev-ultrafast#evidence-and-limits)
explicitly call for independent outcome verification. The useful review adaptation
is a closed set of available evidence actions rather than arbitrary generated
commands. Keep all bank signals, but let applicability and supplied evidence
control which signals drive the next inspection.

Together these examples suggest **a bounded investigation loop**, beyond a static
risk chart: gather broad signals; select a concrete source span or missing-evidence
action; inspect it; ask a focused follow-up; stop, request more context or hand a
supported lead to a reasoning reviewer. Jev can make several of those choices
itself. Each dependent stage needs a later call with the new state—parallel
questions in one request do not consume one another's answers.

This is an inference from inspected designs. We have not run this loop or shown
that it beats our retained baseline. A suitable next test would freeze the action
set, state, maximum inspections, stop rules and fallback; compare it with static
bank-assisted review on the same untouched cases; and count confirmed mechanisms,
failed searches, unassessed items, total provider/reviewer usage and latency. Give
`none` and `need_context` real meanings. Do not optimize the loop on the already
exposed twelve pairs and then present those pairs as a new holdout.

## A practical next implementation

Keep the old baseline, full bank, selected source and every answer. Version any
new interpreter separately. A sensible next prototype would present applicable
mechanism questions beside their evidence, with facts/conventions as additional
navigation. It would supply missing runtime/search premises or explicitly mark
them unavailable, and avoid a generic pattern question suppressing a useful
specific lead. Whether that improves review must be tested rather than assumed.

For Woods users, make the installed-app adapter an optional companion CLI invoked
by an agent, using the published-index contract. The application is the code
under review; no application UI, job queue or tables are implied. Test discovery,
database semantics, Rails version and queue configuration belong in adapter
premises and capability checks. Runtime extraction boots the host application;
Woods' self-map is only for static analysis of the gem itself.

The current checkout implements a curated fixture experiment, not autonomous
packet selection for an arbitrary application. The separate companion repository
remains backlog B-204. Before promoting it, exercise real application packet sizes,
source selection, clean/dirty revisions and downstream review cost. Preserve the
positive checks, cheap exploration and additional finding without turning this
small trial into a production guarantee.
