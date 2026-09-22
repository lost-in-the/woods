# What we actually tested

For the September 21 booted-application review, known-fix replays and downstream
reviewer comparisons, see [chapter 10](10-booted-review-lessons.md) and its
[full report](evidence/2026-09-21-typesafe-booted-review-results.md). The historical
September 16–17 measurements below remain unchanged.

These are separate development experiments conducted on September 16, 2026 local time, continuing into September 17 UTC. They used small, often correlated or previously exposed tasks. Do not pool the rows into one accuracy estimate. Reference labels were generally agent-reviewed rather than independent human ground truth. Provider responses reported `jev-1.13.0`; that identifier does not prove immutable weights or future availability.

The exact earlier reports and later protocol are preserved in [evidence](evidence/README.md). The portable archive contains summaries, provenance hashes, aggregate measurements, and illustrative runnable examples. It does not contain every original request, private acceptance, source snapshot, or author transcript needed to rerun the historical studies exactly.

## 1. Assertion-support feasibility and expanded cases

The initial smoke used six variants of one dependency-graph assertion family. TypeSafe matched 6/6 assistant-authored labels using 6 calls and 4,461 input tokens. All original examples executed successfully; three exact/helper variants rejected a substituted wrong result. This checked assertion discrimination with **result substitution**, not an actual implementation mutation or broad test coverage.

The expanded trial used 40 packets from four correlated families, plus four repeats: 44 calls and 27,821 input tokens. Exact agreement was **32/40**; all 12 direct assertions were recognized, and none of the 28 others was falsely called direct. All eight disagreements classified type-only weak assertions as absent. Independent pre-inference review originally agreed on 36/40 labels; four tautology labels were corrected before inference. All 40 controls passed execution, and 16 injected-result examples failed as expected.

A shallow matcher baseline achieved 26/40 but falsely called 14 cases direct. This is a useful weak control, not evidence that TypeSafe beats strong static analysis or careful review. A correct direct classification had confidence as low as .52, while one taxonomy disagreement had .94. Four obvious instruction-injection controls and four repeat labels held, with probability drift up to .06. None establishes a general security boundary, calibration, or determinism.

**Lesson:** bounded assertion triage is feasible, but labels, missing helper closure, and the distinction between weak and absent assertions matter. Aggregate execution coverage does not establish that an assertion protects a behavior. See [historical audit](evidence/typesafe-guide-history-audit.md).

## 2. Decomposition and the failed assertion veto

A fresh development set contained 16 packets from four families with actual isolated implementation mutations. It compared standalone Choice with a batch containing that Choice and four Nouls about helpers, scenario execution, invariant coverage, and wrong-result assertions. Individual-Noul and repeat calls brought the total to 56.

Standalone Choice matched **15/16**, batched Choice **16/16**. A direct/weak .49/.49 tie contributed to the difference; this does not establish a batching accuracy gain. Neither falsely called a case direct. The prospective conservative composition policy nevertheless escalated **all four correct direct cases**, retaining **0/4**. More questions made the overall decision less useful even though the raw labels were strong. That veto remains reproducible in local replay tooling and is not recommended for adoption.

For the same five questions on four packets, shared-state batching used 3,172 input tokens versus 9,012 for separate calls: **64.8% less input**. Summed sequential times were 1.74 versus 7.48 seconds. All 56 calls used 33,864 input tokens. This compares equal question sets; it does not mean adding four questions is cheaper than asking one original question, or demonstrate concurrent throughput.

The mutation controls had 16 passing correct-code executions; eight strong/helper-omitted executions rejected mutants and eight weak/absent ones survived. The code and model judged different things: execution can use a helper that the supplied packet omits. Local replay review also found and fixed four harness regressions involving reversed question semantics and malformed UTF-8. A valid request hash alone did not establish that a frozen policy was consuming the same proposition.

**Lesson:** evaluate the composed workflow, useful-decision retention, and review burden, not only question accuracy. Bind complete instructions and criteria, including polarity. [Original design and results](evidence/2026-09-16-typesafe-development-evaluation.md#15-first-implementation-milestone-after-live-smoke-trials).

## 3. Constructed claim verification

Twenty-four claims across six code/documentation families had pinned source excerpts and independent pre-inference labels. TypeSafe matched **23/24**, retained all six supported claims, and falsely supported none of the other 18. One unproven universal claim was called contradicted rather than unsupported.

Injection variants, exact repeats, and an adaptive omission-marker removal follow-up brought the total to 42 calls. Six quote checks, four arithmetic checks, and three narrow code executions ran separately. The substring baseline abstained on all 24 cases, so it did not provide a meaningful verification-quality comparison. Removing omission notes left five cases insufficient-context and changed one to unsupported.

**Lesson:** exact quotes, arithmetic, semantic implication, and missing records are different evidence questions. Strong constructed results need validation on natural claims. [Claim pilot](evidence/2026-09-16-typesafe-development-evaluation.md#16-claim-support-development-pilot).

## 4. Natural PR claims and configuration diagnosis

Two untouched summary sentences from each of six recent merged PRs produced twelve natural claims. An ordinary coding-agent comparator and separate reference reviewer agreed on supported/not-established status; one taxonomy dispute was excluded from exact scoring before inference.

TypeSafe matched **7/11 exact labels and 11/12 support statuses**; the comparator matched **11/11 and 12/12**. All six positive cases were retained, but one publication claim was passed despite reviewers finding it unestablished. Three fixed repeats made 15 calls. The references were agent judgments, and no contradiction-positive natural cases or historical runtime oracle were present.

Follow-up review found no demonstrated API/model/schema defect. It did find instruction asymmetry: reviewers had clearer directions about historical observations and executed tests. The disputed supported winner had probability **.39**, against **.61 total non-support probability**, with confidence **.18**. A product that uses argmax over four classes makes a different decision than a prospectively defined binary support-mass rule. No corrected gate was retrospectively declared validated.

**Lesson:** this is neither a clean model-capability ceiling nor proof of a confident false approval. Preserve original results while isolating instruction and evidence effects. [Natural claims and review](evidence/2026-09-16-typesafe-development-evaluation.md#17-untouched-real-pr-claim-comparison).

## 5. Controlled instruction/context and narrow judgments

The next 68 calls isolated three questions:

- Instruction alignment on seven unchanged packets with repeats: first-pass eligible exact agreement moved from 3/4 to 4/4; both arms reached 4/4 on repeat. Binary agreement moved from 5/6 to 6/6, then both were 6/6. The disputed publication support probability dropped from .39/.37 to .06/.07.
- Added adjacent narrative under matched instructions: no selected verdict changed on either pass. A uniquely supported control's support probability fell from .93/.94 to .73/.73 and confidence from .91 to .63. Stable verdicts hid a distribution shift.
- Two narrow Nouls separated code implication from presence of a historical record across six constructed states. All twelve primary judgments matched references, and all twelve repeated labels agreed.

The reference review found genuine taxonomy/scope ambiguity; changing both task and primitive in the narrow stage prevents attributing the result specifically to Noul. Presence of a supplied record does not independently establish that an event happened.

**Lesson:** state and question design can materially affect results, but these are development diagnostics, not a proven cure or general accuracy gain. [Controlled diagnostics](evidence/2026-09-16-typesafe-development-evaluation.md#18-controlled-instruction-context-and-narrow-task-diagnostics).

## 6. Large context-selection failure and compact retry

The task was an already-planned offline evidence reader. Ten implementation/spec packets were frozen alongside an independent 116-case acceptance checker. The original 180,409-byte selection request returned HTTP 400; the run stopped without retries or authoring. A separate small-state marker with ten questions succeeded, while the original large state with one marker failed. Failed-call usage is unknown, and the original diagnostic body was not retained. No exact rejection limit was established.

A separately reviewed compact retry used 41 verified source/spec spans and a 24,471-byte primary request. An ordinary selector and TypeSafe received identical compact cards and common context; selected IDs were hydrated to complete original packets for authors. Their three-example selections differed by one example. The TypeSafe repeat retained the selected set, with maximum probability drift .03.

Three TypeSafe requests, including a marker preflight, used 19,700 input tokens; primary selection alone used 6,675 and cost **$0.00028035** at the recorded rate. Both fresh authors passed **116/116 independent checks**. Their final full suites passed 8,351 and 8,321 examples respectively, with zero failures and three existing optional-tokenizer pending examples; full suites and lint were independently repeated. Both implementations were viable. The TypeSafe-context implementation was retained for a narrowly preferred diagnostic design, not because the experiment demonstrated superior completion.

**Lesson:** acceptable equal-quality selection at tiny recurring cost is potentially valuable. Comparator token/billing data were unavailable, so savings were not measured. Compacting changed content as well as size; it did not diagnose the earlier HTTP 400. [Original failure](evidence/2026-09-16-typesafe-development-evaluation.md#19-prospective-context-selection-pilot-and-operational-stop), [retry and implemented reader](evidence/2026-09-16-typesafe-development-evaluation.md#20-compact-context-selection-retry-and-offline-reader).

## 7. Canopy retrieval, filtering, and executable coverage audit

This replay used 28 queries, 62 fixed runtime-extracted units, and 76 relevance pairs. There were 344 actual candidate judgments after native ranking/type fallback and before assembly. Existing extraction came from the corpus's documented older Woods revision, replayed through current retrieval; it was not claimed to be a fresh extraction-equivalence test.

At budget 1,200:

| Policy | Relevant-unit recall | Complete-source recall | Reference context tokens |
| --- | ---: | ---: | ---: |
| Native | 57.98% | 56.55% | 28,019 |
| Native top three | 57.98% | 56.55% | 25,574 |
| Ordinary reranking | 73.99% | 68.63% | 28,508 |
| TypeSafe reranking | 77.02% | 71.55% | 28,977 |
| TypeSafe filtering | 64.52% | 60.83% | 22,561 |

Pure reranking still lost a baseline-labeled ID on 7 queries and complete source on 10. Filtering lost IDs on 12 and complete source on 13. At budget 600, TypeSafe's higher ID recall gave **no complete-source recall gain** over native. Relevance labels describe evidence, not necessary/sufficient conditions for a correct patch.

Primary selection used 63 calls, 293,010 input tokens, and **$0.01230642**. Including four repeats: 67 calls, 312,062 input tokens, **$0.013106604**. All succeeded, with one credential lookup. Median primary HTTP time was about 389.8 ms. Small score changes altered packed evidence on repeats despite stable filter decisions.

A separate testbed audit proved that removing the latest-revision guard still passed the existing 32 tests. A new stale-assignment-after-resubmission regression passed correct code and killed that mutant. TypeSafe did not discover or author the regression. The static Woods map also helped identify inaccurate token accounting after context postprocessing. Issues: [testbed #23](https://github.com/lost-in-the/woods-testbed/issues/23), [Woods #354](https://github.com/lost-in-the/woods/issues/354).

**Lesson:** inexpensive ranking can improve evidence without compression. Threshold removal and native packing require separate analysis. [Full retrieval report](evidence/2026-09-16-typesafe-retrieval-evaluation.md).

## 8. Curated method-context coding repairs

Four controlled Woods regressions crossed lexical/TypeSafe ranking with whole-file/method-support representations at a 1,000-token source budget: 16 author attempts. The file universe was curated and editable paths were supplied. TypeSafe method contexts yielded **4/4 accepted repairs**, lexical method **2/4**, TypeSafe whole **3/4**, lexical whole **2/4**. There were eleven accepted patches, two behavioral failures, and three abstentions.

The two lexical-method failures lacked the edit site and changed unrelated visible logic. For retry delay, both whole-file policies omitted the site and abstained; both method policies repaired it. Smaller snippets alone were not sufficient: whole-file evidence fixed one recovery task that lexical method selection missed.

A posthoc audit found that one accepted lexical filename repair omitted `to_s`, changing five Symbol/custom-coercion probes. The documented helper takes Strings and inspected callers supplied Strings, so this was an observed generated-patch compatibility gap, not an established production contract bug. Frozen scores remained unchanged.

Selector totals: 16 calls, 72,411 input tokens, **$0.003041262**; the method policy alone used 49,919 input and **$0.002096598** across four tasks. Authors reported 163,882 input, 42,240 cached input, 5,129 output, and 3,022 reasoning output. Cache differences prevent attributing billed savings.

**Lesson:** method selection can help a separate author, but source provenance, missing declarations, author variability, and finite tests still matter. [Full span report](evidence/2026-09-16-typesafe-span-evaluation.md).

## 9. Description-only discovery, genuine features, budgets, and repeats

The final planned study removed curator-provided target paths and used fresh Woods self-maps plus fresh Canopy runtime extraction. A fixed description-only search and BM25 shortlist produced 80 cards per task. All four target files survived discovery and entered every context, but useful method delivery differed.

| Condition | Newsletter repair | Payment feature | Exclusion feature | SQLite repair | Total |
| --- | --- | --- | --- | --- | ---: |
| BM25 1,000, each of two draws | Pass | Pass | Pass | Abstain | 3/4 each |
| TypeSafe 1,000, each of two draws | Pass | Pass | Pass | Pass | 4/4 each |
| BM25 3,000 | Pass | Pass | Pass | Pass | 4/4 |
| TypeSafe 3,000 | Pass | Pass | Pass | Pass | 4/4 |
| BM25 8,000 | Pass | Pass | Pass | Pass | 4/4 |

All 26 submitted patches passed the frozen tests; the two abstentions remain in the 28-attempt denominator. The two new features passed every condition, so no feature-writing advantage was established. At the small budget, TypeSafe delivered the SQLite implementation while BM25 did not. At larger budgets, deterministic selection closed that observed gap.

Primary selection: 30 calls, 320 judgments, 167,660 input tokens, **$0.00704172**. A byte-identical repeat schedule doubled totals to 60 calls, 640 judgments, **$0.01408344**, using one credential lookup. All live requests succeeded. The 133 malformed/missing-score/freshness checks passed offline; none was a live failure.

Every full selector order changed on repeat. Packed contexts were identical on 3/4 tasks at 1,000 and 1/4 at 3,000; largest probability change .11. Repeated authors used original primary contexts, and acceptance agreed in all eight pairs. Entire submission JSON was identical in 1/8, replacement arrays in 3/8, including the empty abstention pair. Stable success is not deterministic code.

Primary validation ran 1,169 RSpec examples across overlapping suites, twelve standalone Ruby acceptances, and 29 syntax checks. Additional retrieval/ranker checks passed 696 examples across five repairs plus baseline. Authors used 332,359 input (119,680 cached subset) and 12,411 output (3,905 reasoning subset). These are repeated validations and four task blocks, not thousands of independent coding observations.

The posthoc audit quantified unsupported Unicode-folding changes and additional SearchExecutor edits. It also independently reproduced baseline NUL and Boolean search bugs. New issues: [newsletter coverage #24](https://github.com/lost-in-the/woods-testbed/issues/24), [NUL search #355](https://github.com/lost-in-the/woods/issues/355), [Boolean search #356](https://github.com/lost-in-the/woods/issues/356). These came from controlled audits, not an autonomous TypeSafe bug finder. [Full final report](evidence/2026-09-16-typesafe-four-tests-evaluation.md), [posthoc audit](evidence/four-tests-posthoc-review.md), [aggregate JSON](evidence/four-tests-metrics.json).

## Implemented, experimental, proposed

| Surface | Actual status at handoff |
| --- | --- |
| Offline materialized evidence reader | Implemented source-checkout Ruby API; bounded bytes, UTF-8 and hashes; no Git-lineage proof or CLI integration |
| Offline assertion replay and strict Choice/Noul responses | Implemented source-checkout tooling; failed veto retained for reproducibility; Score unsupported |
| Live selection, retrieval replay, isolated coding evaluations | Local experimental runners and captured results; not a supported packaged Woods feature |
| Portable examples in this archive | New illustrative reference, validated offline; separate from measured historical harnesses |
| Automatic general corpus/provenance/holdout framework | Proposed; not completed by the reader/replay slices |
| Benchmark applicability and performance-risk classifier | Proposed; no dedicated completed experiment |
| Blinded historical buggy/fixed replay | Proposed; natural PR claims and controlled mutants are different studies |
| Production TypeSafe dependency, CI gate, automatic patch acceptance | Not introduced |

The evidence supports an optional low-cost context-selection experiment with real code authorship and ordinary validation. It supports neither dismissal because the selector does not always beat a larger context nor default adoption based on a small winning comparison. [Cost and adoption](07-cost-and-adoption.md) explains the next decision.


## 10. Full Rails bank and downstream review (September 21)

The later [full-bank chapter](11-full-bank-review-lessons.md) and
[results report](evidence/2026-09-21-typesafe-full-bank-results.md) preserve the
original six-question implementation while evaluating all 204 supplied questions
on twelve defect/control pairs. There were 144 provider calls (three repeats per
candidate/arm), 1,291,578 input and 323,571 free output tokens, estimated $0.054246276.
One of 14,688 bank answers was invalid; all 432 baseline answers passed.

Several mechanism questions separated their pairs strongly. Maximum-Noul priority
also alarmed on 10/12 controls; those are unverified leads, not automatically false
positives. Two designated question/fixture mappings were invalid. The initial six
reviewer sessions had delivery limitations; a separate six-session recovery
comparison is reported without pooling. A full-bank-assisted reviewer identified
an additional conditional stale-transfer mechanism on the atomicity control,
verified by execution without changing that control's original label.

No general efficiency gain, cross-Rails/database compatibility or autonomous
whole-app packet construction is established. Aggregate reviewer tokens cannot
recover the intended tokens-to-first-finding metric. The full bank's low cost and
specific useful leads justify improving its interpreter rather than dismissing
its capability from an unsuccessful aggregate ordering.
