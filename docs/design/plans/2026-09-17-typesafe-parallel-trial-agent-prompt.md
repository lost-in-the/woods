# Prompt for the agent conducting the parallel Rails-monolith trial

You wrote `QUESTIONS-FROM-A-PARALLEL-TRIAL.md`. The Woods investigation's coordinating agent has now checked your questions against the retained requests, instructions, captures, execution summaries, source cards, and guide. Use the answers below to revise your assessment and propose the next useful experiments. These are evidence corrections and limits, not a request to favor TypeSafe or defend either study.

Work from existing artifacts first. This task is to produce an updated analysis, a sanitized evidence handoff, and prospective experiment designs. Do not make new provider calls, run new trials, or change production in this task; describe missing controls prospectively. Preserve the original studies and label any new analysis as retrospective. References such as `evidence/...` below refer to the unpacked Woods guide; the answers are self-contained if raw Woods artifacts are unavailable on your machine.

## Verified answers to your questions

### 1.1 — The SQLite patches passed the additional suites

Yes: for the exact frozen submissions, adding the existing retrieval/ranker suites would still produce passing results. The posthoc audit already executed:

```text
bin/rspec spec/retrieval/search_executor_spec.rb spec/retrieval/ranker_spec.rb --seed 20260917 --format progress
```

All five submitted T004 patches and the untouched correct baseline passed **116 examples, zero failures each**: six runs, 696 repeated examples. The five patches were BM25 3k/8k, TypeSafe 1k draws 1/2, and TypeSafe 3k. The BM25 1k cells abstained and supplied no patch. See `evidence/four-tests-posthoc-review.md` and `evidence/2026-09-16-typesafe-four-tests-evaluation.md`.

Therefore those suites do **not** turn the frozen 4/4-versus-3/4 completion result into 3/4-versus-3/4. However, your broader concern is valid: those suites also did not reject the observed compatibility changes. All five patches narrowed InMemory Unicode folding. **The SearchExecutor attribution/score change belonged to BM25 3k, BM25 8k, and TypeSafe 3k; the two differentiating TypeSafe 1k patches did not change that helper.** They did make broader SQL rewrites and change InMemory behavior.

The public task specified ASCII-insensitive literal matching; the adapter contract explicitly left non-ASCII folding backend-specific. That explains the recorded endpoint, but does not make an unrequested behavior change harmless. The author instructions also said to preserve unrelated behavior. Treat the result as “passed declared tests, with observed compatibility concerns,” not production-ready correctness. A new requirement to preserve the observed Unicode behavior would reject these particular repairs; report that as a separate sensitivity analysis, applying it symmetrically to all arms. Do not silently redefine the old endpoint.

### 1.2 — Abstention and scope need separate outcomes

The study reported abstentions separately but treated them as non-completions in the primary accepted/intended count. It did not have a prospectively defined, independently adjudicated “passed but unacceptable scope” endpoint. So it measures bounded completion, not whether a maintainer would prefer a patch to a cautious abstention.

For subsequent work, preserve two dimensions: **execution outcome** and **scope/compatibility review**. A patch can pass tests and still need changes. Keep missing-evidence abstention separate from malformed output, operational failure, and behavioral failure. Do not automatically turn abstention into success either. Measure the actual escalation path: fetch additional evidence, retry under a declared budget, review, and finish or stop. Report safe useful completion, reviewer burden, and time/cost to resolution alongside first-attempt completion. Freeze scope criteria before outcomes; do not use “a wider diff” alone as proof of a harmful change.

### 1.3 — Correct the candidate-recall denominator

The Canopy study's approximately 95% figure was **mean coverage of labeled relevant units at the candidate boundary**, not the percentage of the whole corpus retrieved. Pools contained **2–20 units, median 14, from 62 stored units**. A small pool can retain most labeled relevant evidence.

The later Woods study did discover nearly all eligible files, but TypeSafe and BM25 ranked the same **top 80 cards from about 4,200 segmented cards**. Broad file discovery and the inference shortlist are distinct stages. Target-file survival was checked; recall of every necessary implementation mechanism was not comprehensively established.

There is still no designed large-monolith, low-candidate-recall study. Three existing Canopy queries had lower relevant-candidate recall. Their retrospective 1,200-token results were:

| Query | Available labeled relevant units | Native ID/full-source recall | TypeSafe rank ID/full-source recall |
| --- | --- | --- | --- |
| `hybrid-2`, newsletter | 4/5; 20 candidates | 60% / 60% | 60% / 60% |
| `hybrid-3`, editorial | 4/5; 20 candidates | 40% / 20% | 60% / 40% |
| `direct-3` | 0/2; 2 candidates | 0% / 0% | 0% / 0% |

These are three exposed development cases, not evidence that an advantage generalizes to your monolith. Preserve the distinction between corpus fraction, relevant-unit candidate recall, delivered ID recall, delivered complete-source recall, and task-mechanism sufficiency. Complete source is useful evidence, but no study established it as a calibrated predictor of author success.

### 1.4 — No documented blinded human reference-label validation

No recorded study establishes reference labels supplied by an independent human blind to model outputs. Classification figures are agreement with reviewed development labels, not human-grounded accuracy. That limitation deserves an explicit sentence in the overview and validation record.

The coding studies also include actual deterministic syntax/behavioral execution. Those observations are stronger than another model's opinion, but their agent-curated oracles can miss behavior. Distinguish annotation provenance from executed outcomes. Apply the same distinction to your own corpus: human-authored review comments do not automatically make model-assigned checklist or sequence-error categories human-adjudicated labels.

### 1.5 — The ordinary comparator also received extra instructions

The natural-claims comparator and reference agents were designated the same twelve packet states and the same Choice definition that TypeSafe received. The original request objects confirm equal packet contents. **Both agents additionally received `review-instructions.md`**, with more explicit distinctions between historical observations, source-implied behavior, test definitions, and executed tests. They also produced reasons and ambiguity flags.

Extra source/PR lookups were prohibited by their instructions. No retained comparator event audit independently proves enforcement; there is also no evidence demonstrating extra fetching. Do not equate a behavioral restriction with a verified tool-disabled environment.

The reported 7/11 exact and 11/12 binary versus 11/11 and 12/12 are descriptive results for asymmetric workflows. They do not establish that a plain model call generally beats typed judgments. Later aligned instructions improved one pass, but an unchanged original also improved on repetition. Do not demote your equivalent claim check solely on this comparison; require a matched, held-out comparison with equal state, task semantics, and access.

### 1.6 — The repeated request bodies were byte-identical

The coordinator rechecked **all 30 primary/repeat pairs** against the saved bodies and SHA-256 values. Every pair matched exactly. Bodies contained only `model`, `state`, and `questions`; no nonce or varying request identifier was inserted. Requested and returned model identifiers were `jev-1.13.0`. The capture's local IDs changed for bookkeeping and were not transmitted in the body. Transport headers/server internals were not wire-captured or attested.

Full 80-card rank identity failed for all four tasks; largest score movement was .11. Packed source remained byte-identical on 3/4 tasks at 1k and 1/4 at 3k. This warrants its own prominent stability section. It establishes failure of exact rank determinism in these comparisons, not that useful ordering is entirely random or always unstable. Report top-k overlap, rank correlation, cutoff crossings, and delivered-byte changes separately.

Crucially, the repeated authors used the **original primary contexts**, not the re-ranked repeat contexts. Their equal acceptance rates therefore do not prove that selector drift had no downstream effect.

Your changed-batch observations need an exact-request repeat control before attributing the excess variation to batching. Hold the full state, question wording, model, and relevant settings fixed; distinguish within-condition repeat noise from changes associated with batch composition. Define what “8% of a column's spread” means and report absolute values as well.

### 1.7 — No downstream author test of the Canopy removal policy

No author consumed the Canopy strict-`>0.5` filtering arm. Its rejection was against the evidence-preservation objective: it lost baseline-labeled IDs on 12/28 queries and complete source on 13/28. Those losses do not by themselves prove loss of task-solving ability. A separate guard-mutation exercise established one mechanism's importance, not author performance under the filtered contexts.

An earlier, different compact-example selector did use `>0.5` plus top-three selection, hydrate selected IDs to full packets, and feed an author that passed 116 checks. That does not validate Canopy filtering or isolate threshold effects.

Also qualify “ordering is safe, removal is not.” Under a finite context budget, reranking changes what is delivered. The rank-only Canopy arm lost baseline-labeled IDs on 7/28 queries and complete source on 10/28. Ranking is advisory and reversible upstream; it is not intrinsically lossless after packing.

### 1.8 — Assembled units were ranked, but not patched as physical source

Actual retrieval requests included **64 candidate occurrences across eight enriched units** with inlined concern source: Article/Comment/Invoice with Archivable, two controllers with RequiresAuthor, and Payment/CardPayment/BankPayment with Auditable. Payment also involved STI and AASM. These counts are repeated card occurrences, not independent tasks.

Cards included the complete extracted enriched source string, identity/type, a nominal path, namespace, and dependencies. That string could contain schema/routes annotations and comment-prefixed concern bodies marked “Included from”; it was not one contiguous editable interval. The later authoring studies instead used exact physical source spans with same-file byte guards.

No dedicated Phlex, SimpleDelegator, general DSL, or multi-file-editing success stratum was measured. For your codebase, propose evidence bundles with separately identified physical spans for declarations, delegation targets, concerns, helpers, and contracts. Preserve each span's file/hash/byte coordinates and explicit relationships. Never invent a contiguous source range for an assembled view. Treat dependency completeness and hydration as separate hypotheses to test.

### 1.9 — The rejected body survives; a resend would not settle historical cause

The original 180,409-byte body is retained, SHA-256:

```text
4276a468991b45de6f00b2af7ac1a9a620fd9f4ea160ede8539af6b1be7695c6
```

Its byte-identical scheduled repeat was never sent after the first 400. A later diagnostic sent a small ten-question marker successfully, then the original full state with one changed marker question at 170,033 bytes and received another 400. That reproduced a full-state failure, not an unchanged-request repeat. No explanatory error body or failed-call usage was preserved adequately.

A new resend would establish current acceptance or rejection of those bytes. It would not alone distinguish size, representation, content, validation, or prior service conditions. Size is plausible, not established. If pursued later, retain safe structured errors and use controlled interventions; do not describe one additional response as a causal diagnosis. No new inference was performed to answer this feedback.

### 1.10 — Component timings exist; matched substitution savings remain unmeasured

In the compact example-selection study, the ordinary selector took **38.100856 seconds from launch to output file**, while the TypeSafe primary call recorded **437.98 ms** at the HTTP/client boundary. TypeSafe used **6,675 input / 184 output tokens**, estimated **$0.00028035**; ordinary selector tokens/billing were unavailable. Both downstream implementations passed 116 acceptance checks.

The selectors saw the same compact state, but used different selection/output procedures, and their timers had different boundaries. This is partial substitution evidence, not a measured end-to-end speedup or cash saving. Do not divide those two times into a speedup claim.

Discovery cost is also incomplete. The final study records MCP search calls of roughly **0.011–0.057 seconds** and initialization of **0.635–0.726 seconds**, but these exclude index extraction, source construction, and broader preparation. They are not total discovery times. Report cold extraction, freshness updates, warm lookup, source-card construction, inference, authoring, and review separately; allocate shared index cost over actual reuse rather than assuming either free preparation or a full extraction per question.

## Assertion strength deserves another targeted study

It was followed up: the initial four-family/40-case trial led to four more families/16 packets, real implementation mutations, standalone/batched judgments, and 56 calls. Choice matched 15/16 standalone and 16/16 batched; the composed veto retained 0/4 correct direct cases. The next documented step prioritized claims before expanding assertion families. That was an experiment-order decision, not a finding that assertion judgments were useless.

Your distinction between primitive quality and policy quality is correct. Prioritize **advisory assertion triage** if it addresses a demonstrated developer need. Keep the raw judgment and any consuming rule separate. The original lexical comparator was weak, the families were correlated, human-grounded labels were absent, and the planned holdout/advancement criteria were not met. Zero observed false-direct calls is not a calibrated assurance guarantee.

Compare against credible static checks and ordinary review, include helpers/fixtures and natural RSpec, execute benign and faulty implementations, and judge useful findings at the team's real attention budget. Do not silently collapse “contains an assertion,” “asserts the intended invariant,” and “kills this mutant.”

## Cache feedback: retain both levels of identity

The portable Python example is an **explicit replay adapter**, not a production cache that automatically pays for a miss. Whole-request identity deliberately binds exact experiment replay. Adding a production judgment cache is a different layer.

Your per-`(state, question)` approach can avoid repeated paid judgments when only other questions change. Please document it as a reusable pattern, while preserving:

- The complete effective state and complete question semantics, including type, instructions, criteria, and referenced IDs/paths.
- Model/version policy, rubric/schema/preprocessing versions, tenant/source authorization, and freshness.
- Original batch membership, capture/request identity, timestamps, returned model, and whether the result was reused or freshly sampled.
- An immutable request-level attempt ledger for aggregate usage, failures, and repeat analysis.

Hash the **full effective state**, not just the focal candidate, when neighboring cards were also sent. Cached values intentionally reuse one past judgment; they do not demonstrate invariant fresh-call behavior. Do not duplicate a request's shared input usage onto each cached question or invent a provider-measured per-question cost. Validate migration equivalence and retain the old records instead of rewriting their experimental provenance.

The [parallel-questions cookbook](https://docs.typesafe.ai/cookbooks/parallel_questions) supports shared-state batching and explicitly distinguishes sequential timing from concurrent scheduling. Its current published output is **12.2x cheaper / 10.0x faster**, exactly the figures in your feedback. Please identify whether yours are independently measured monolith results, a local cookbook rerun, or quoted cookbook results. This is a provenance clarification, not an accusation; report each under its actual source.

## Evidence to return from your trial

Prepare a compact sanitized handoff using existing artifacts. Keep private source/PR text on its authorized host; synthetic reproductions and aggregate tables are sufficient where disclosure is inappropriate.

1. **Score contracts:** actual sanitized request/response examples, requested/returned model, validation rules, level-text failure cases, both numeric feature transformations, and the exact action-mapping rule. Action-worded levels do not eliminate decision policy: a probability-weighted Score can lie between levels, or equal a middle level without any probability on it. Explain argmax/rounding/escalation and ties; use Choice if the actions lack a meaningful order. See the [Score contract](https://docs.typesafe.ai/primitives/score).
2. **Drift and cache migration:** integer denominators, unique subjects/questions versus repeated answers, exact-body and changed-batch controls, raw and normalized deltas, batch/state hashes, cache bypass rules, migration invariants, and observed decision changes. An 11,700-answer cache is not 11,700 independent subjects.
3. **Prediction null:** target definition, PR counts/splits, paired held-out predictions or aggregate errors and uncertainty, all baselines/features, tuning procedure, and feature availability at prediction time. Check chronological/author/family leakage and whether final merged diffs or later index generations disclose post-review information. “No distinguishable gain” is not proof of equivalence without a suitable interval/design. This is a review-effort result, not a direct defect-detection result.
4. **Review taxonomy:** integer counts for the 87% unmatched and 28% sequence-error figures, category definitions, who assigned labels, no-match/multilabel handling, disagreement resolution, and any blinded human audit. Human comment absence does not establish defect absence. The 159/220 zero-inline-comment base rate constrains alert utility; it does not provide 159 proven-clean PRs.
5. **Assertion checks:** distinguish written policy, observed reviewer complaints, and a check whose precision/usefulness you actually measured.

Until inspected, summarize your monolith results as **reported external evidence**, separate from the Woods measured ledger. The negative prediction result is valuable even if it supplies no case for deploying TypeSafe. Neither study's endpoint settles the other's.

## Deliver the revised assessment and next-test plan

Return four artifacts or clearly separated sections:

1. A response matrix for your original questions: answered, corrected premise, still unknown, and what would change a deployment decision.
2. The sanitized handoff above, with unsupported claims and unavailable artifacts stated plainly.
3. Proposed guide edits: narrower README completion language; both relevant-unit and complete-source recall; explicit absence of human label validation; prominent failed-veto and exact-repeat findings; distinct execution/scope outcomes; replay-versus-cache guidance; component-versus-total costs. Do not silently alter frozen historical reports or scores.
4. A prioritized prospective plan for the following three pilots, plus a small repeat/cache control where needed. Specify baselines, task/PR-level holdouts, outgoing state, labels/oracles, success and stop criteria, intended denominators, and estimated/measured costs before new calls.

**Pilot A — Assertion triage:** natural, helper-aware cases; strong static and ordinary-review controls; executable mutants and a blinded human annotation subset if claiming semantic accuracy. Optimize useful review findings and false reassurance at a realistic alert budget. No composed veto by default.

**Pilot B — Selective monolith evidence:** freeze realistic discovery/shortlists and stratify by missing mechanisms and assembled/DSL cases. Compare BM25, TypeSafe, and a transparent declaration/helper-hydration baseline under equal evidence budgets. Measure retrieval, actual delivered spans, downstream task completion, scope concerns, and abstention/escalation separately. If filtering is tested, include paired downstream authors and preserve the unfiltered comparator. Do not manufacture a favorable result by rescuing known target files.

**Pilot C — Actual substitution economics:** replace an ordinary bounded selection turn with TypeSafe using matched state, equivalent task semantics/access, consistent timer boundaries, and randomized paired execution. Record cold/warm discovery, actual cache and provider usage, retries, author effort, review, and accepted outcomes. Use $0.042/M input and free output as the stated TypeSafe estimate; keep unknown subscription billing unknown. Cheap inference can justify equal-quality substitution, but total savings must be measured.

Prefer these narrow decision-linked evaluations over another global PR-risk score unless a new operational target and independent evidence justify that direction. Finish with the single pilot you recommend first and the evidence that would make you abandon it. Do not force a positive adoption conclusion.
