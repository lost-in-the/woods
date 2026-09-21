# Full Rails bank comparison — prospective protocol

Frozen before inference, 2026-09-21. This is experimental source-checkout tooling,
not a gem feature, an application UI, or a merge gate. The earlier implementation
and captures remain intact. This protocol evaluates the supplied bank, not a
generic replacement for it.

## Questions and evidence

Import all 204 questions from the attached September 19 bank, preserving source
wording and Score/Choice criteria. Catalog interpretations of kind, polarity,
context requirements and headline mapping are explicit and versioned. No semantic
question corrections or persona prefixes in this first comparison. A later
revision must keep this bank and these answers intact.

The comparator retains the earlier six questions exactly, except its Choice
options enumerate this request's regions. Both arms get byte-identical state.
The new shared state layout has the handoff's named fields and explicit links
from legacy regions into complete units; this is a fresh comparison, not a claim
that the old captures were rerun unchanged. Whole source and annotations survive;
duplicate chunks, timestamps and redundant unit-level edges may be omitted.

Read frozen, booted Rails evidence from each fixture's pinned generation. Check
source hashes, clean worktree, runtime freshness and revision identity separately.
The four older pairs have a follow-on commit recording generated db/schema.rb;
verify that exact isolated materialization difference and retain both identities.
Fixtures select support by known family: this does not evaluate autonomous
retrieval. Explicitly missing siblings, whole-app searches, git history, or test
evidence remain missing. Required evidence is recorded per question. Source and
test bodies are evidence; executable oracle outcomes and labels are not sent.

A conservative compact UTF-8 byte budget with headroom is used before calling
the provider: 30,000 state-plus-longest-question bytes and 60,000 whole-request
bytes. It is a local proxy, not a claim to implement the vendor tokenizer. Split
questions with the whole state if needed; never trim distinguishing source to
fit. Real provider token counts are recorded. Current documented model limits:
64k whole request, 32k state plus longest question.

## Corpus and order

Twelve matched defect/control pairs: four previously investigated Rails fixtures
plus eight new pairs. The last three new families (tenant lookup, test
effectiveness, atomic writes) are frozen holdouts. Other nine pairs are development
cases. Fixtures are modest and intentionally legible, not representative estimates
for a large application. The vacuous-test pair is explicitly an easy control.

Every candidate receives the full bank and baseline, three repeats each, with a
pinned jev-1.13.0 model. Randomize order within development and then holdout;
consume neither group for prompt tuning in this initial run. Expected 144 calls
before request splitting. Every intended request remains in the denominator.
No automatic retries; explicit repeats are separately scheduled and charged.
Resolve credentials once into process memory, discard after the whole capture.

## Validation and interpretation

Preserve raw bytes, usage, elapsed time and all failures. Reject wrong response
types, nonfinite/out-of-range values, invalid IDs and Choice losers. Report
distribution rounding separately: sums within 0.005 * option-count of one are
rounding-compatible; stricter sum discrepancies remain visible. Never repair
raw answers. Score expectation tolerance follows rounded distribution values.
One failed answer does not discard other valid questions in a 204-question call.
Three valid repeats are required for the primary median-based shortlist; incomplete
answers remain explicitly unassessed. Preserve all individual repeats.

Nouls with yes-is-good polarity invert only in display/routing code. Headline
Scores remain separate dimensions, never combined as a defect probability.
Choices route; conventions/facts are shown separately. Exploratory bands .5 and
.8 order checks, with .8 used for high-signal accounting. They are not calibrated
acceptance thresholds. Candidate ordering uses the largest eligible defect Noul
only for navigation; broad and full-bank maxima are not comparable probabilities.

Report target-question separation, every incidental high answer by kind and
evidence availability, missing answers/evidence, known and unknown cost, and
holdout results separately. A planted mechanism's passing oracle does not prove
the whole control has no other defect. Incidental flags require independent
inspection; they are initially unverified leads, not automatic false positives.

## Downstream review

Compare ordinary review, six-question assistance, and full-bank assistance on
the same candidate pool and accessible evidence. Use independent fresh sessions
of the same reviewer model/settings, same per-run time/output limits and shared
inspection capabilities. Run two repeats per arm, varying candidate order with
paired seeds. Each reviewer starts with the change inventory or assisted report;
assisted arms need not read the entire pool before following leads.

Record supported mechanisms, false leads investigated, additional findings,
unassessed candidates, tokens/time to first later-verified finding where telemetry
allows, total tokens/time, cache subsets and Jev cost separately. A prompt budget
is not a hard token limit: record actual usage and external time cutoff. Count
reviewer outcome matches only after comparing mechanisms to separate oracles.
Do not claim general superiority from these small related runs or causal cache
savings. Do not compare raw tokens across models as equivalent dollars.

## Sources

- https://docs.typesafe.ai/api
- https://docs.typesafe.ai/models
- https://docs.typesafe.ai/cookbooks/parallel_questions
- The preserved source-question-bank.md and bank-corrections.md in this directory.
