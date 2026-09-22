# Follow-up prompt: correct the instruments and narrow the first pilot

Read this as the coordinator's response to `REVISED-ASSESSMENT-AND-PILOT-PLAN.md`. Your corrections about cookbook attribution, action-worded levels, comparator instructions, candidate recall, and the SQLite audit are accepted. Preserve them. The revised handoff is useful, but its API statements, drift interpretation, and pilot decision rules still need correction before an outcome-bearing run.

This task is **offline evidence audit and protocol preparation**. Inspect retained artifacts and relevant source, perform clearly labeled retrospective calculations and synthetic interface checks, and write the deliverables below. Do not make new provider calls, run application/mutation/author trials, launch a human-labeling campaign, or change production as part of this response. Do not rewrite either study's frozen outcomes. We have reviewed your document and current official docs, not independently inspected your private raw corpus; your new numerical results remain attributed reports.

## 1. Correct the economic decision rule first

Pilot A currently rejects TypeSafe if an ordinary model ties it and calls the primitive redundant. This contradicts Pilot C and the investigation's explicit emphasis on **$0.042 per million input tokens, free output**. Acceptable quality at substantially lower recurring cost can be the whole benefit.

Use one consistent rule across pilots:

- Predeclare the minimum useful quality, false-reassurance/review-burden limits, and uncertainty needed for the intended advisory use.
- Permit either useful quality improvement at acceptable cost, or demonstrated acceptable/noninferior quality at lower measured cost, latency, or capacity use.
- Define any noninferiority margin from consequences before outcomes. A small observed tie or nonsignificant difference is not evidence of equal population quality.
- Prefer a deterministic alternative when it meets the requirements and offers the better measured operational tradeoff. Do not assume a hydration tie in ten cases establishes that conclusion for all strata.
- If comparator billing is unknown, report known costs and measured time/tokens/capacity separately. Do not invent a dollar saving. Fixed research/annotation effort and recurring production work are different costs.

Remove the automatic “ordinary model equals or beats us, therefore stop” rule. Also remove the unsupported “cheaper incumbent” assertion until its comparable quality and incremental cost are established. The study may conclude positive, negative, or inconclusive; none requires TypeSafe to win a pure accuracy contest against every more expensive model.

## 2. Separate the HTTP contract, SDK representation, and your cache

Your retained Score lists and stripped Noul objects do not establish the provider's wire format. Current official documentation describes:

| Layer | Documented representation |
| --- | --- |
| HTTP Score answer | `type`, `score`, `confidence`, `legend`, and a probability **map keyed by string level indices** |
| Python SDK Score | Probability/legend maps keyed by integer levels |
| HTTP Noul answer | An object such as `{"type":"noul","noul":0.06}`; no confidence field |
| Your cached projection | Whatever your adapter serialized; it may legitimately be a list or stripped object, but must be labeled as that projection |

Sources checked for this response: [HTTP API](https://docs.typesafe.ai/api), [Score reference](https://docs.typesafe.ai/primitives/score), and [Noul reference](https://docs.typesafe.ai/primitives/noul). Do not add the proposed list/scalar statement to the guide as an API fact.

Return the installed SDK/version, relevant serialization code, and one sanitized or synthetic example of each transformation: HTTP → SDK → cached value → feature. If an older raw response differs, preserve and version it rather than treating current docs or the old capture as interchangeable. If raw responses are absent, state that limitation. Locate where the `max(dict)` bug occurred and whether any historical result used that code; do not assume either harmlessness or contamination without tracing it.

A minimal offline contract check should distinguish `max(mapping)` from `max(mapping.values())`, order Score levels numerically, verify expected levels and finite valid probability mass, and preserve question/criteria identity. Your displayed probabilities imply a mean of **1.56**, while the cached score says **1.57**. This may reflect rounding of underlying probabilities; reconcile precision before calling it an error or choosing a tolerance. Clamp variance only for small numerical roundoff after validating the distribution, not to hide invalid input.

Your `test_evidence` instrument lacks an ordinal adequacy scale. Levels 0 and 3 are both favorable cases, not opposite quality judgments. Its mean/SD therefore lack the claimed strength interpretation. A learner could still exploit such numeric features; the bad scale does not prove they contain zero predictive information. Preserve the original result and mark the instrument problem.

For a new instrument, use coherent ordered descriptions or nominal Choice categories. Applicability can be a deterministic fact, explicit category, or separately evaluated judgment depending on the task. **Do not turn “N/A” into a mandatory Noul gate by default.** Another judgment introduces errors and another policy to validate. Likewise, `context_complete` cannot certify the absence of dependencies it never saw; keep known omissions as program-recorded facts and any completeness judgment diagnostic until separately evaluated.

## 3. Repair the retrospective drift interpretation

The displayed counts imply **41.0% identical and 59.0% nonidentical**, not “values move almost always.” Neither percentage is a causal upper bound on variation attributable to batch composition. Without matched controls, randomness, batch composition, time/model differences, and interactions remain unresolved; their effects need not add monotonically.

The **40/2,860 = 1.4%** figure concerns hypothetical Noul-at-.5 and Score-argmax policies. Your actual learner consumed Noul values and Score mean/SD; it did not act on Score argmax. Call these diagnostic threshold/argmax crossings, not observed stability of the deployed or intended consumer. Do not infer that a fixed-input crossing rate above 1.4% invalidates every threshold or consuming policy.

Make `drift_recheck.py` reproducible from its definitions:

- Define a comparison when one state/question has three or more observations: all pairs, first/last, maximum difference, or another rule. A repeated identity is not automatically one observation pair.
- State whether “identical” means scalar equality, mean-and-SD equality, or the complete probability vector; identify the Score quantity used for each delta.
- Report by question/primitive or explicitly normalized scales. Define the SD population, zero-SD handling, comparison weighting, and ties at exactly .5/argmax.
- Preserve subject/PR and question-family clustering. Thousands of judgments over 220 subjects are not thousands of independent subjects.
- Label sample maxima as observations, not guarantees about future decisions. If compatible saved feature vectors and a frozen learner exist, you may separately calculate retrospective prediction/ranking changes; do not reconstruct incompatible vectors and present them as observed outputs.

For a later **fixed-input stability** study, exact repeats alone answer that narrow question. For **batch attribution**, design contemporaneous matched blocks: the same effective state and focal question in compositions A and B, with exact repeats inside each, randomized/interleaved under the same model conditions. An `A,A,B,B` block is four calls, with no nonce inserted into repeated bodies. Do not subtract a new repeat rate from the old unmatched 1.4% and call the result a batch effect. Choose controls relevant to the proposed consumer; the old PR-feature instruments are not automatically a stability benchmark for a new assertion classifier.

## 4. Reconcile provenance and the actual call budget

Keep the bare judgment cache, original request records, and future attempt ledger distinct. Retain original files. A metadata sidecar may document recovered associations without overwriting values or fabricating timestamps, returned models, or sampling history. Unknown provenance stays unknown.

Return a small artifact census reconciling the previously reported **1,494** old whole-request entries with the current **834** surviving records, and approximately 11,700 answers with 14,756 cache files. These may represent different filters or populations; explain them rather than treating file counts as requests. Separate known retained input usage from the approximately 2.6M aggregate previously reported, without adding overlapping totals. Failed attempts were not journaled, so successful caches cannot verify a zero-400 failure rate; distinguish an operator's recollection from complete request accounting.

Also reconcile **194 human comments** with a mean of **0.66 inline comments per 220 PRs**: those cannot describe the same counted population, since 194/220 is about .882. Different comment types/filters may explain it. Define the population for each statistic before using it to motivate an alert budget.

The repeat budget currently contradicts itself:

| Proposed workload | Correct arithmetic at $0.042/M input |
| --- | --- |
| 100 fresh request pairs | **200 calls**, not about 100 |
| Stated 200k-input control | **$0.0084**; explain which calls/inputs produce 200k |
| 1,200 examples × 2,500 input tokens | **3M input, $0.126** before additional overhead |
| That primary study plus the stated 200k control | **$0.1344**, not about $0.26 |
| Primary plus 200 additional calls of 2,500 input tokens | **$0.147**; illustrative only if those are the actual control sizes |
| Repeating the entire 1,200-example study | **6M input, $0.252**; a different schedule |
| 100 matched `A,A,B,B` blocks | **400 calls**; cost depends on both compositions' request sizes |

Choose one schedule and count primary, repeated, comparator, failed, and optional diagnostic attempts explicitly. Use serialized state **and question** estimates, then replace estimates with actual returned usage. Do not double-count a primary call already in a pair. Reuse a frozen selection vector across context budgets when its inputs are unchanged. Author inference is also model cost, even though it is not TypeSafe selector cost. A much cheaper selector need not imply a cheap whole experiment.

## 5. Verify Pilot A's applicability before committing to 1,200 examples

The reported 19% theme is a model-assigned classification of comments about **missing scenarios**. Even if a human confirms it, it does not establish that weak assertions in **existing changed examples** caused those concerns. A missing example or a PR with no changed tests is outside Pilot A's proposed candidate population.

First inspect a bounded retained sample—roughly 20–30 test-related comments is sufficient for an exploratory check—and map each to:

1. Weak assertions in an existing changed example.
2. A concern in an existing unchanged example.
3. An absent scenario/example, including no-test-change PRs.
4. Another testing issue or insufficient evidence.

Record the link to an eligible triage unit and whether the mapping is an agent judgment or independently human-adjudicated. Keep this sample in development. If the overlap is poor, narrow A to a written-policy hypothesis or propose a separate scenario-gap task. Do not relabel one use case as evidence for the other.

Then revise A around these concrete contracts:

**Behavior and evidence.** Supply a scoped behavioral requirement/scenario independently of the model's answer. Example names are evidence, not automatically the complete contract. `have_received`, type equality, and generated-source assertions can each be appropriate for their intended behavior; include legitimate counterexamples and keep static pattern flags distinct from adequacy labels. Define resolvable helpers/hooks/shared contexts, overrides and omissions without promising complete arbitrary-Ruby closure.

**Human labels.** A second pass by the same engineer is intra-rater repeatability; human–human agreement needs a second independent annotator, blind to the first labels and model output. State actual availability, labeling budget, adjudication, and development/holdout counts. If 120 labels are divided 70/30, roughly 36—not 120—are held out. Model agreement below a small human–human point estimate does not prove the taxonomy is unstable. Also, the proposed 100-comment human taxonomy audit is currently absent from Pilot A, which annotates RSpec examples; separate these tasks and costs.

**PR-level alerts.** “At most one alert per PR” is a proposed product cap, not an empirically established preference inferred from zero median comments. Freeze eligibility, ranking, deduplication, threshold/no-alert behavior, insufficient-context handling and ties. Do not force an alert on every PR. Report actual alert volume and useful findings per intended PR, including silent/failed cases. Near-total abstention cannot win on precision alone.

**Holdout and alert precision.** Hold out complete PR/fix families or otherwise justify a split aligned with the intended deployment; avoid repeated example lineages crossing partitions. Spec-file splitting alone can put one PR in both sets. Report shared-helper exposure without merging the whole repository merely because it shares Rails helpers. A random 120-example annotation set does not measure precision of alerts selected from all 1,200 examples. Use a manageable fully labeled candidate set, or blind adjudication of the union of selected held-out alerts plus the declared diagnostic sample. Budget those annotations. Keep example agreement, alert precision, useful-findings yield, escalation, and mutation results separate.

**Mutants.** Before model outcomes, verify that the baseline passes, the relevant path is reached, and each mutation violates the same scoped requirement rather than an equivalent implementation or unrelated branch. Confirm that a kill is a relevant assertion failure, not syntax/boot/fixture/timeout failure. Unreached, equivalent, invalid, and unrelated mutants are not false reassurance. A survivor only supports that conclusion when the fault and the model's positive claim concern the same obligation. One killed mutant cannot prove complete protection either.

**Controls and decision.** Match state, task definitions and access for ordinary review; record actual access where possible. Define how each arm selects its PR alert. Your handoff contains no independent precision estimate for the existing automated reviewer on this endpoint. Remove that stop rule or specify the comparable evaluation still needed. Use section 1's quality-and-cost rule, not a requirement to outperform the ordinary model on label accuracy regardless of price.

## 6. Keep Pilot B small and make the comparison identifiable

Pilot B is a plausible next stage, but clarify the design on paper before preparing forty application tasks:

- Pin each historical starting commit, dependency/runtime configuration and task brief. “Pre-merge state” is ambiguous; final PR descriptions and diffs can reveal the solution. A reference diff is one implementation, not an acceptance oracle. Specify independent behavioral acceptance and baseline/reference controls. Private repository status reduces some exposure risks, but does not exclude prior agent/cache/study exposure.
- Separate base cards from hydration. Your current assembled cards already contain declarations, delegates, concerns, helpers and base contracts, while another arm claims to add them. A minimal three-arm design is **BM25/base cards; TypeSafe/the same base cards; BM25/frozen deterministic hydration**. This compares ranking on base cards and hydration under BM25, not their interaction. Alternatively use identical hydration for both rankers. Name whole-workflow comparisons honestly; a larger factorial study is unnecessary just to repair this pilot.
- Treat deliberately missing helpers as paired stress interventions across natural architecture strata, not an independent fourth population. Specify omission before/after hydration and which alternatives remain possible. A withheld preferred helper does not prove every valid solution requires it. Keep deliberate omissions out of natural candidate-recall stopping denominators.
- Define “discovery is binding” and retain all planned outcomes. Do not abandon hard cases posthoc or declare a deterministic winner from a small point-estimate tie. Measure both scope/compatibility and behavior. Complete-source recall remains a diagnostic, not a validated predictor of completion.
- Runtime extraction, mutation and author evaluation require disposable source plus a separate database/storage namespace and controlled side effects. The shared development database is not an isolated evaluation target. If isolation cannot be demonstrated, keep results at offline retrieval/design scope. Preserve exact per-span source identity and keep reference patches/acceptance outside scorer and author inputs.

The earlier Woods study did include AASM/concern-enriched cards; what is absent is a dedicated DSL/Phlex/delegator performance stratum. Likewise, no paired Canopy filtering/unfiltered author study exists, but the earlier compact top-three/threshold selector did feed an author. Keep those qualified statements.

## 7. Keep the prediction result descriptive and correct the proposed guide edits

The RMSE difference **1.494 − 1.531 = −0.037** and an interval spanning both improvement and harm support “no distinguishable improvement in this reported retrospective comparison.” Preserve that result, with these clarifications:

- Identify the predeclared primary arm, whether “best” was selected on development or held-out results, and the paired bootstrap/resampling unit. A fixed-arm interval does not account for selecting the best held-out arm.
- The 2.60-versus-.64 association with automated-reviewer participation does not alone establish causation by rollout. Support the “60% of labels” statement with actual event counts. Identify whether participation was known at the proposed prediction time and whether adding it was a posthoc analysis. Compare judgments against the same strengthened baseline if assessing incremental value.
- Post-review diffs/commits are inappropriate inputs for pre-review prediction. Their leakage does not necessarily favor every arm equally, so “the leak made it easier and still did not save it” is not a conservative capability conclusion. Define the prediction timestamp and human-versus-bot target before a future study.
- `none_of_these` competing with fifteen options gives no established direction of classifier bias. The model-assigned taxonomy suggests a hypothesis; human auditing would estimate agreement/uncertainty, not conclusively settle all checklist mismatch.

Accept the proposed guide's clearer headline limits, distinct execution/scope outcomes, prominence for failed composition and exact repeats, and replay/cache separation. Correct the API-shape and mandatory-Noul-gate proposals before incorporating them. Do not describe complete-source recall as a proved success predictor, one failed veto as a universal composition law, or the old 1.4% diagnostic crossings as actual consumer stability. Matched end-to-end timing ratios can legitimately measure speedup; the prohibition concerns dividing **unlike** timer boundaries, not all ratios.

## Deliverables and the next decision

Return one concise revision with supporting offline artifacts where available:

1. **Errata and provenance:** corrected schema/representation chain, drift definitions, cache/request census, comment populations, and explicit remaining unknowns. Preserve original evidence.
2. **Applicability audit:** the small comment-to-triage-unit mapping, exclusions and annotation provenance. Explain whether it actually supports assertion triage over changed examples.
3. **One freeze-ready first-pilot protocol:** target, intended unit/population, matched controls, human availability/label plan, alert rule, holdout, mutation validation, quality/cost decision rule, uncertainty/inconclusive outcome, and bounded request/token schedule. Design it; do not execute it in this response. If prerequisites are missing, name them rather than assuming they exist.
4. **Brief disposition for B/C and guide edits:** what remains useful, what is deferred, and which claims can be included only as reported external evidence.

The preferred immediate step is the **offline applicability and provenance audit**, not the full 1,200-example inference run or another global risk model. Recommend Pilot A next only if its scoped target matches the demonstrated need and its evaluation is feasible. Otherwise say which narrow alternative answers the actual developer problem. Judge value by useful outcomes and total cost—including the unusually inexpensive TypeSafe inference—not by a requirement that the cheap component always beat a larger model's accuracy.
