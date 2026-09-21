# 10. Booted application review and fix-verification lessons

Added 2026-09-21. Read the [complete follow-up report](evidence/2026-09-21-typesafe-booted-review-results.md)
for exact revisions, protocols, numbers, failures and limitations. This chapter
extends the original guide; it does not replace the earlier retrieval/coding trials.

## What the new trial established

On eight booted Rails candidates—four constructed defects and four legitimate
controls—Jev's top four from diffs contained three defects and one control. With
Woods runtime evidence, the top four contained all four defects. Evidence included
whole source, schema, inlined concerns, inherited controller filters, job source
and explicit runtime configuration. Selected evidence came from a pinned generation.

The extra context cost little: the three-repeat Woods arm used 125,406 input tokens,
approximately $0.005267. These are curated support selections on a small Rails
8.0/SQLite fixture. They do not establish automatic context retrieval, monolith
performance, or general review accuracy.

An ordinary reasoning agent also selected and explained all four defects. Giving
another agent the Jev ranking did not improve findings and took longer. A further
routed run started from the shortlist instead of reading the entire diff pool:
it used 2.52% fewer reported input tokens, but more output tokens and more time.
Cache proportions differed, so causal dollar savings were not measured.

**Use this as evidence that inexpensive, Woods-informed prioritization is feasible.
Do not present it as established superiority over an ordinary agent.** The first
assisted workflow required reading everything anyway; a useful implementation
must explicitly decide whether screening adds oversight or replaces broad reading.

## What a review adapter needs

1. Identify the intended revision/range and preserve exact candidate source bytes.
2. Use the installed application's `woods-extract full` launcher when a verified
   fresh boot boundary is needed. Ordinary post-boot Rake extraction can correctly
   report `unknown / unverified_boot_boundary` even when its bytes have not changed.
3. Read through `Woods::PublishedIndex.open` for one pinned generation. Keep
   freshness, revision identity and per-question evidence sufficiency separate.
4. Supply full relevant methods and dependencies, not summary chunks presented as
   code. Include inherited filters and concern bodies when they determine behavior.
5. Get version/adapter premises from the actual runtime. A job's explicit enqueue
   override may need source or direct observation beyond the behavioral profile.
6. Keep model scores advisory. Send selected candidates to an agent that can explain
   a concrete mechanism and verify it against tests or runtime behavior.

The [example request](examples/booted-review-request.json) and
[recorded response](examples/booted-review-response.json) are one actual synthetic
callback case from this trial. They are **not inputs to the older ranking-example
CLI**, and contain no oracle outcome. The full report gives their provenance.
Do not generalize its score from one example or call the indexed relationships a
complete execution graph. The sample represents an explicit hypothetical app change.

## Do not use falling scores to certify a fix

The earlier release screen led the coordinator to three executable bugs in two
Woods files. After those bugs were fixed, repeated broad questions barely changed
their scores. Contract-specific questions separated the expiry fix, but missed the
clear and malformed-snapshot fixes. Narrowing to exact method bodies and supplying
a measured library premise still did not reliably repair those judgments.

The narrowed questions were written after the failures were known. They test
assisted contract judgment, not novel discovery or held-out performance. Preserve
unfavorable results; do not keep adjusting until one reassuring score appears.
Executable regressions verified the actual fixes. A quiet model is not a reason
to close a known execution-backed finding or skip its regression test.

## Handle imperfect responses without losing accounting

Across 101 calls, all returned HTTP 200 but four failed the experiment's strict
Choice validation. One selected a non-maximal displayed option; three distributions
summed to .99. Coarse probability rounding may explain those sums, and the local
validator's very tight tolerance may be unsuitable for observed service output.

Define a documented rounding/acceptance policy before inference, preserve raw
values, and validate fields according to how code actually consumes them. A bad
localization need not erase independently valid Noul judgments if the policy
supports partial results. Do not silently renormalize, choose a new winner, or
retry until the result looks acceptable. Record usage before semantic validation:
failed output can still incur cost.

The complete TypeSafe round cost an estimated **$0.018298**. One in-memory credential
lookup served every phase. Agent review usage is reported separately. Cheap input
supports providing useful evidence and trying bounded experiments; it does not
remove the need to measure false leads, reviewer effort and operational failures.

## What remains experimental

The reusable CLI is still proposed as a separate optional Woods companion. No UI,
application jobs or tables for the tool, default gem inference, or automatic merge
gate was introduced. The fixture tables belong solely to disposable reviewed apps.
No new real Woods bugs were reproduced in this round; planted fixture defects were
not filed as issues. A larger prospective application comparison would need fresh
changes, less curated retrieval, stronger cost controls and independent adjudication.
