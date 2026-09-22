# TypeSafe guide validation pass 1: evidence and completeness

Reviewed 2026-09-17. Read-only review of the complete portable guide, including all ten main pages (README and chapters 01–09), operations/example runbooks, transfer/validation records, all nine exported evidence Markdown files, aggregate metrics, and the source manifest. Cross-checked the historical and pattern research, original reports, current four-task capture/stability/aggregate artifacts, and the canonical Woods index/MCP documentation.

**Verdict: evidence coverage and factual interpretation pass. No blocking scientific, numerical, attribution, or implementation-status concern found. The one small portability correction identified during review has now been applied and verified.** Technical transport/security execution and final ZIP validation remain the separate second pass; this review does not imply those checks already passed. No provider calls, credential reads, author runs, product edits, or sealed-artifact edits were performed.

## Findings and exact requested changes

### P1-1 — Minor portability correction, resolved during review

`05-woods-integration.md:232` links the completed evaluation to `../plans/2026-09-16-typesafe-four-tests-evaluation.md`. That resolves inside the Woods checkout but leaves the portable guide directory, so it will fail in the promised standalone archive.

The coordinator changed the target to `evidence/2026-09-16-typesafe-four-tests-evaluation.md`; this reviewer verified the correction. The bundled copy exists and its export hash matches the manifest. This does not change the scientific conclusions.

### P1-2 — Optional historical-record clarification

The copied prospective four-test plan preserves two original shorthand statements: `No task/reference/test bytes enter selector or author state` (line 23), and `a stronger, NEW deterministic baseline` (line 37). Taken literally, the first excludes the public task brief that was in fact supplied; the second could be read as a measured comparison against the earlier lexical baseline. The completed report and current chapters correctly describe public-task input and an unmeasured difference between the baselines.

The copies are explicitly historical, so this is not a blocker and must not trigger editing the sealed original plan. If desired, add an editorial note in `evidence/README.md` explaining that the completed report/current chapters govern interpretation: the excluded material was private task/reference/oracle metadata, and BM25's relative strength against the earlier baseline was not directly measured. Preserve the original text and hashes.

## Trial coverage checklist

| Historical or current evidence | Guide coverage and fidelity |
| --- | --- |
| Six-case assertion smoke | Ledger §1 and historical appendix retain 6/6, one family, six calls/4,461 input, assistant references, and result substitution rather than implementation mutation. |
| Expanded assertions | Ledger §1 includes 32/40 exact, 12/12 direct, 0/28 false direct, eight weak-to-absent disagreements, four families, 44 calls/27,821 input, 36/40 pre-review agreement and four corrected labels. The weak 26/40 matcher and its 14 false-direct cases remain visible. |
| Confidence, missing helpers, injection and early repeats | Confidence .52/.94 counterexamples and limitations are retained; four missing-helper decisions are preserved in the historical appendix. Small obvious injection/repeat controls are not presented as security or determinism guarantees. |
| Decomposition and failed veto | Ledger §2 and chapter 08 retain 15/16 standalone versus 16/16 batched, the .49/.49 tie, 0/4 useful direct retention, 56 calls, actual implementation controls, and failed-policy status. The source-tooling appendix retains the RSpec-wording/standalone-Ruby format-transfer limitation. |
| Shared-state batching | Same five questions/four packets, 3,172 versus 9,012 input, 64.8% reduction, and sequential 1.74 versus 7.48 seconds are properly scoped; no claim that extra questions are free or that this measures concurrent throughput. |
| Constructed claims | Ledger §3 preserves 23/24, all six supported retained, 0/18 falsely supported, one contradicted/unsupported error, 42 calls, omission-marker adaptation, separate quote/arithmetic/execution checks, and the all-abstaining substring comparator. |
| Natural PR claims | Ledger §4 and chapter 08 preserve 7/11 and 11/12 versus 11/11 and 12/12; one taxonomy exclusion; all six positives retained; 15 calls; instruction/reference/antecedent confounds; missing contradiction-positive cases/historical oracle; .39 supported versus .61 combined other classes and .18 confidence. No retrospectively corrected gate is claimed. |
| Instruction/context/narrow diagnostics | Ledger §5 retains 68 calls, matched eligible denominators, original-arm repeat improvement, no argmax changes from adjacent narrative, probability/confidence shifts, and both narrow dimensions' primary/repeat results. It correctly refuses to attribute success to Noul alone. |
| Large context failure | Ledger §6 and chapter 08 retain 180,409-byte HTTP 400, the small ten-question success/full-state one-question failure, lost error-body limitations, unknown rejected-call usage, and no authors. Current approximate 32k-token documentation is separate from the local byte cap and cannot diagnose the old failure. |
| Compact retry and actual reader | Ledger §6 includes 24,471 bytes, 41 spans, identical compact inputs/hydration, differing selected example, three calls/19,700 input, primary 6,675 input/$0.00028035, both 116/116 acceptance outcomes, full-suite results, and maintenance preference rather than selector superiority. The reused task, missing comparator billing and implementation limits remain explicit in the appendices. |
| Canopy retrieval | Ledger §7/chapter 03/appendix preserve 28 queries, 62 units, 76 qrels, 344 judgments, candidate recall limits, all major baselines, 1,200/600/300 budget results, relevance-versus-complete-source recall, and filtering/ranking losses. The cheap native top-three control and exposed development corpus are not hidden. |
| Retrieval mechanisms and repeats | Threshold/intent mismatch, actual stale-review ranking error, packing losses, duplicate/invalid-output handling, repeat order/context drift, and no live fallback are represented. Aggregate gains are not called lossless. |
| Runtime stale-review test and self-scan | Testbed #23's guard-removal mutant survives existing tests; new test distinguishes it while correct app passes. Woods #354 is final-string accounting, not a proved hard-budget violation. Static source orientation is never called Rails runtime extraction. |
| Curated method repair trial | Ledger §8 and full appendix preserve all four arms (2/4, 3/4, 2/4, 4/4), four blocks/16 attempts, two behavior failures/three abstentions, curated three-file universe/editable paths, one author draw, source-delivery differences, and actual token/cache costs. |
| Prior filename coercion gap | Chapters 06/08 and appendix correctly attribute missing `to_s` to the generated filename-helper patch, retain five of eight failing non-String probes, distinguish documented String contract from observed compatibility, and keep the original primary score. It is not misattributed to Evidence.read. |
| Final discovery test | Chapter 03/05/ledger §9/report retain description-only queries, fresh incomplete-state maps, source-only roots/types, shared top 80, packaged scan/result caps, 59/59/267/271 hits, near-enumeration limits, and file presence versus delivered implementation. No target rescue is claimed. |
| Final budgets/features | The 28-attempt table is complete, with 26 passes/two abstentions. TypeSafe 1k is 4/4 on both draws, BM25 1k 3/4 on both; larger budgets close the observed gap. Both additive features pass every arm, so no feature advantage or population noninferiority is asserted. BM25 8k is not called full source. |
| Selector/author repeatability | Full rank changes on all four tasks, .11 maximum drift, context equality 3/4 at 1k and 1/4 at 3k, eight equal-acceptance author pairs, 1/8 equal submission JSON and 3/8 equal replacements are accurate. Repeated authors use original primary contexts; cached replay is not a repeat call. |
| Fallback, freshness, harness and containment | 133 offline faults are distinct from 60 successful HTTP calls/no live fallback. Whole-vector fallback, stale-source stop, two freezes, exact same-file original-coordinate edits, simultaneous application, all-failure denominators, expected positive test counts and containment limits are explicit. The stronger patch guard is not retroactively attributed to the earlier trial. |
| Current compatibility and actual issues | Five Unicode-folding changes, three SearchExecutor edits/.5-to-.25 score changes, six runs/696 repeated examples, unmeasured SQL performance, actual NUL/Boolean baseline defects, and testbed #24 coverage gap are represented. Primary labels remain frozen; no autonomous TypeSafe bug discovery is claimed. |
| Implemented versus proposed | Offline Ruby evidence/replay slices, experimental live runners, new illustrative Python reference, deferred corpus/holdout/capture service, untested Score validator/performance classifier/historical paired replay, and absent production/CI integration are consistently distinguished. |

No meaningful positive or negative trial was found omitted from the handoff. Short chapters appropriately defer detailed tables and historical controls to included evidence rather than silently dropping them.

## Documentation-pattern coverage

All **27 requested documentation/demo URLs** appear in chapter 01 and have substantive development interpretations: use-case map, System One, state, primitives, patterns, fan-out, confidence routing, composite scoring, both consistency cookbooks, parallel questions, rerank, semantic find, autoformat, function calling, skill suggestion, entity alignment, RAG passage classification, citation checking, SDE cascade, date extraction, pre-parsed values, hierarchical classification, autoresearch feature discovery, confidence classification, intent routing, and smart-home.

The chapter matches the independently prepared live-primary-source pattern research. It keeps vendor examples separate from local evidence; state/question independence, invisible question IDs, Noul polarity/no confidence, Choice alternative-relative probabilities, Score intensity and unsupported local validation, and approximate combined context guidance are accurate at the documented research date. Untested routing, extraction, learned features and broader gates are marked as proposals. No cookbook outcome is imported as a Woods guarantee.

## Numerical and source cross-checks

- All nine original-report SHA-256 values and all nine exported-copy SHA-256 values match `evidence/source-manifest.json`.
- `evidence/four-tests-metrics.json` is exactly equal as parsed JSON to the sealed `tmp/typesafe-next-four/outcome-analysis.json`.
- Independent aggregate recount gives 28 intended/26 accepted; 332,359 author input, 119,680 cached-input subset, 12,411 output, 3,905 reasoning-output subset, zero cache writes; 40 RSpec processes/1,169 examples; author-repeat agreement 8/8, full-JSON equality 1/8 and replacement equality 3/8.
- Raw TypeSafe capture gives 30 primary and 30 repeat HTTP-200 attempts; each pass has 320 judgments, 167,660 input and 6,200 output. All 30 repeated request hashes equal their primaries. Primary median is 434.43 ms and summed HTTP time 13.72132 seconds. The separate stability artifact agrees with the reported rank/context drift.
- Recomputed primary estimates at $0.042 per million input: $0.00028035 compact choice; $0.01230642 retrieval; $0.002096598 curated methods; $0.00704172 automatic top-80. Per-1,000-selection estimates are respectively $0.28035, $0.439515, $0.5241495 and $1.76043, using task/query rather than HTTP-request denominators.
- The four-task illustrative sensitivity expression at U=$5/O=$15 is -$0.03001828, correctly rounded to -$0.03002. Filtering's selector-only break-even is $2.25475 per million reference downstream tokens, correctly reported as about $2.25. Its quality loss is not hidden by this arithmetic.
- Unknown rejected usage, unmetered curation/review, subscription billing, reference tokens versus actual provider input, cached/reasoning subsets, and primary versus diagnostic costs remain separate throughout.

## Woods and implementation boundaries

Canonical `PUBLISHED_INDEX.md`, `INDEX_LAYOUT.md`, `AGENT_GUIDE.md`, and `MCP_SERVERS.md` support chapter 05's described 14 registered/15 conditional schema distinction, required embeddings for semantic retrieval, regex/literal search options, partial traversal meaning, runtime/static separation, published payload retention pin, typed unit lookup, checksum meaning and thread-safety limits. Its Ruby block example uses the documented API. Container source mapping, coherent generations versus mutable checkout, and separate Console access are correctly distinguished.

The reference example is described as a synthetic standard-library adapter, not a reproduced historical harness, no-live-call proof, production service or shared cache. Operational omissions and source transmission are plainly disclosed. Whether its code fulfils every stated technical property belongs to pass 2. The current working `VALIDATION.md` correctly says final checks are pending rather than presenting this in-progress review as completed archive validation.

## Pass-2 handoff

P1-1 is resolved; proceed to the independent technical/security/portability pass. Verify exact live request compatibility against current docs, CLI/transport behavior, malformed and freshness cases, archive inclusion/exclusion, all links, and the final extracted ZIP. No additional scientific retuning, inference, or changes to sealed experimental outcomes are warranted by this review.

The reviewer authored chapters 04 and 08 earlier; that authorship is disclosed. This pass nevertheless read all chapters and appendices, emphasizing the other agents' chapters and independently recounting the current raw aggregates. It is one reviewer perspective, not independent revalidation of its own prose by a second person.

## Reviewed main-page identities at completion

SHA-256 identifies the reviewed bytes, not authentication. Later pass-2 corrections legitimately change these identities.

| File | SHA-256 |
| --- | --- |
| `01-concepts-and-patterns.md` | `d2d7bb8d4d0f7f651fb6d589906ab7d0bd8e7c7718523e07fda30aa7d893eeb5` |
| `02-architecture-and-operations.md` | `e680bc473db3919f713c4ab6c173d0c56d9cbf354d163124b964d9a23616c86e` |
| `03-evidence-selection.md` | `4dcc4b19269b5dfabf3f13139f274ee39cffcbd0f39c28bb1cec30490c89ca20` |
| `04-code-authoring-and-evaluation.md` | `f66e30ea3e1c90c1fdd0c289177d385fd7de9d01f62d8d69a5985db138d93d52` |
| `05-woods-integration.md` | `7d79f0f24f7e65f895533b79003444870a634ec654c5ca89314385f2dd055c51` |
| `06-trial-ledger.md` | `8413ff9cfa896c324e919b5e7c101567404885a66ee015a9f688469d565109ed` |
| `07-cost-and-adoption.md` | `7d695d040e768301076834e1e0bb1d774131ba0e65ab4904e79504370f0256e3` |
| `08-pitfalls-and-diagnostics.md` | `e3c8d90ad98e24d0f80bce885309bc080d356a3f0485f0a1a7b186de93f55b9e` |
| `09-agent-playbook.md` | `03bfe79e1c3068ebdceff8f2860f4e10b7f441350820347030181ae54740a493` |
| `README.md` | `807e6cc5746968ee406dcdedae361d95a0a796fa39b34141c22d8b6b3fc08f8c` |
| `TRANSFER.md` | `47dfb31befaebb151978fa3628054c45d3a18f75949658d0592a739c3a2e135d` |
