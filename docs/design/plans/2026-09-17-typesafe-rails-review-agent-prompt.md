# Follow-up prompt: run the ranking pilot and prepare a Rails review prototype

Read this as the coordinator's response to `INDEX-DIAGNOSIS-AND-NEXT-ACTION.md`, with a new investigation of [devagrawal09/jev-review](https://github.com/devagrawal09/jev-review). **Accept the reported resolution of the Phlex discovery problem. Proceed with the bounded shared-pool ranking experiment, and prepare an offline Rails review prototype using the useful parts of Jev Review.** These are related uses of an evidence adapter, but distinct evaluations.

The user specifically wants meaningful Jev-based code review considered for both Woods and your Rails project. Do not let this become only a retrieval study. Equally, do not require a complete reviewer, another extraction campaign, or another general audit round before running the small ranking comparison now supported by your data.

Your private results remain attributed reports: the coordinator has inspected your handoff and the relevant Woods implementation, not your full private artifacts. Preserve historical outputs and the sealed guide/archive. Existing owner authorization and environment changes stand; do not ask for the same permission again or automatically revert the application upgrade.

## 1. Close the index investigation with two small compatibility checks

The reported change from 8 to 946 indexed view paths, recovery of all four sampled Clay components, and discovery of Woods 1.5.0 in the actual index-producing checkout strongly support the known B-184 diagnosis. The directory-walk fix already exists upstream. Do not file a new “Phlex unsupported” issue or repeat the broad index audit.

Complete these checks while preparing the experiment:

**Typed variants.** Projecting only `nodes[].file_path` is not the complete 2.x graph contract. At your pinned revision **`cc3bd3eae5cbecb398cb208006037fe7492b432a`**, additional unit types sharing an identifier are represented in `variants`, with their own paths and edges. Count those records and affected paths in the actual snapshot. Add one synthetic fixture with the same identifier under two types, different paths, and different outgoing edges; preserve both through your adapter or use the native graph loader. If the real snapshot has no variants, say the omission has no impact on that snapshot and proceed. Recompute only affected results if it does. [Serialization](https://github.com/lost-in-the/woods/blob/cc3bd3eae5cbecb398cb208006037fe7492b432a/lib/woods/dependency_graph.rb#L728), [variant records](https://github.com/lost-in-the/woods/blob/cc3bd3eae5cbecb398cb208006037fe7492b432a/lib/woods/dependency_graph.rb#L814).

**Provenance.** Record the source/worktree commit and dirty-state fingerprint, full Woods revision, resolved generation/payload, graph hash, corpus hash and adapter revision. Resolve `generation.json` to its payload instead of guessing the newest `gen-N`. State whether the corrected adapter was used on both old and new graphs. Your old index came from a different worktree, and several file counts changed, so describe an observed upgrade/re-extraction improvement consistent with B-184; do not attribute an exact causal share to one fix or say only the index changed without matching evidence. No new extraction is needed merely to isolate those shares.

Preserve the Gemfile/lock backups and record the current container bundle and saved index location. The container bundle change belongs in the environment handoff, even though nothing was committed. A future rollback must keep Gemfile, lock, bundle and index compatible; do not roll anything back during this experiment without a reason.

## 2. Apply the ledger corrections directly

The revised boundary table implies this join:

| Current-snapshot status | Comment/file occurrences |
| --- | ---: |
| Exists and satisfies the corpus path/extension rule | **26** |
| Exists but outside that rule | 2 |
| Missing, but path/extension would otherwise qualify | 9 |
| Missing and outside the rule | 2 |
| Total | **39** |

Thus **35 is path/extension eligibility**, **28 is existence**, and **26 satisfies both**. Keep the 34 deduplicated PR/file pairs as a separate legitimate unit; do not substitute one denominator for the other. Derive exact eligible PR counts from the ledger and use deduplicated target sets per PR for the primary comparison. Comment-weighted figures may remain secondary.

BM25 reportedly returns 21 of those 26 existing eligible occurrences: eight in the top 20 and thirteen in the top 60. Five remain unreturned, and a top-60 pool still omits thirteen of the 26. Check whether “not returned at any rank” means the whole corpus was evaluated or a query/result cap was applied. Missing files, corpus exclusions, zero-match/query failures and rank cutoffs remain separate.

One wording repair: 89.1% is anchor paths **inside** the retained changed-path list, not outside it. It still does not measure source supplied in a diff. Also link the claimed previous 6,000-token run if it exists: it was not included in the last report reviewed here. These are artifact/label corrections, not reasons for another broad audit.

## 3. Run the small current-snapshot ranking comparison

Use the existing eligible development PRs. This is a current-source, historical-query mechanics experiment with weak evaluator targets, **not historical replay, a holdout, or a measure of reviewer usefulness**. Final PR descriptions or changed-path metadata may themselves reflect later revisions; record that exposure rather than silently calling them pre-review inputs.

Freeze before inference:

- The eligible PRs and deduplicated target paths; retain other ledger rows in coverage/accounting summaries.
- The current source/index/adapter identities and exact task queries. Review-comment text, cited constants and evaluator targets remain excluded from discovery and scoring.
- A naturally generated **BM25 top-60 candidate pool per PR**, or fewer when discovery returns fewer. Do not inject missing targets. An empty/failed pool remains an accounted outcome.
- Source cards and physical source spans, including any support attached by a fixed rule. If you attach Woods support, attach the same support for both ranking arms. Do not add a new hydration arm here.
- One packing policy and one actual delivered-token budget. Reuse the documented 6,000-token budget if its artifact supports it; otherwise prospectively declare 6,000 as this run's choice. Count headers, omissions and support source, and make truncation or oversized-card handling explicit.

Compare **BM25 order versus TypeSafe order on exactly the same pool and card contents**. Widening internal candidates from 20 to 60 is useful preparation; delivering three times as many files is not evidence of a reranking benefit. Record the top-60 target-availability ceiling separately from what each 6,000-token packet actually delivers. If a path is selected but the target's relevant source span is unknown, report file coverage without upgrading it to mechanism or source-sufficiency recall.

Use one narrow, consistent relevance judgment per candidate, with state and criteria referring to legitimate task inputs. Batch independent judgments where the actual request budget permits it. Include a no-useful-evidence outcome or an explicit low relevance definition; do not force every candidate to be useful. Freeze ties and failure/fallback handling, and preserve incomplete-context facts in code.

Prepare the request manifest and estimate from serialized state plus questions. Keep this run limited to the frozen top-60 pools, with a maximum of one fresh diagnostic repeat per primary request. A ceiling of **10M estimated input tokens across primary plus repeat** would be **$0.42** at the stated rate; the actual fixture may need far less. If the manifest exceeds that, reduce the development sample by a recorded non-outcome-based rule rather than clipping away selected evidence silently. Set a corresponding attempt cap; record SDK retries, failures and unknown failed-call usage. This estimate is not an invoice or a guarantee about unreported usage.

Use the existing authorized credential mechanism, retrieving once for the batch and keeping the secret out of artifacts. Pin the requested model and retain returned models, complete request/response identity, usage and timer boundaries. Exact repeats must reach the provider rather than replay a cache. Reuse recorded scores when only packing changes; this run has one primary output budget.

Report per-PR paired coverage, candidate ceilings, delivered source identity/size, omissions, operational failures/fallbacks, primary and repeat costs, matched timing components, and repeat effects on packed evidence. Keep all intended PRs in operational accounting and PR/family dependence in interpretation. Do not infer noninferiority, production precision or defect detection from a small observed tie. Equal useful quality at lower measured work can still be valuable; TypeSafe need not beat an ordinary model's accuracy to justify its low price.

## 4. What Jev Review contributes to a Rails reviewer

The coordinator audited **`31f89602797fb7bea007f8a480bf368bf564954e`** of [Jev Review](https://github.com/devagrawal09/jev-review/tree/31f89602797fb7bea007f8a480bf368bf564954e). Its staged design is concrete and adaptable:

```text
Five Noul concern signals
  -> select a bounded follow-up queue
  -> Choice of evidence span or no match
  -> Choice of mechanism or no supported issue
  -> Score conditional impact
  -> advisory specialist routing
```

It separates discovery, policy, model judgments, CLI and a local report dashboard. The implementation is MIT-licensed. It supplies a useful orchestration/UI example, **not measured evidence of review accuracy**. The coordinator's source/type/dependency checks passed, and seven offline probes used mocked SDK answers with zero network requests.

Important facts to carry into the adaptation:

- **Stock discovery is JS/TS-only.** RSpec's `spec/` and `_spec.rb` conventions are unrecognized. Adding Ruby extensions alone would misclassify specs. Working-tree change mode is `git diff HEAD`, not a pinned PR base/head comparison, and deleted files are excluded.
- **Evidence loss is real.** A six-line test is compacted to three declaration/setup lines, omitting its action/assertion without an omission marker. Later localization/classification/impact calls discard test context entirely. These are adapter/pipeline problems, not evidence that Jev cannot review tests.
- **Line chunking is not a request cap.** A 548,914-byte one-line fixture produced a 632,352-byte recorded screening payload. Profiles and localization also retained the large file. No live server rejection was tested.
- **Policy is unvalidated.** The project uses screening .70, location confidence .55, up to eight follow-ups, routing score 1.5 and a `request_changes` label at severity 2 on a 0–3 rubric. The severity question assumes the suspected issue exists. Those cutoffs and the label are not a Rails merge policy. In the stock project the label is only report data, not a GitHub action.
- **The saved report is not an experiment ledger.** It omits source hashes, model/usage/attempt accounting and full judgments. SDK 0.6.0 already has a ten-second per-attempt timeout and two applicable retries; `TYPESAFE_DEFAULT_MODEL` can override the default `jev-latest`. Do not say retries or model overrides are absent—make their use observable.

The coordinator reproduced quoted-path omission and test evidence loss offline. Two upstream issues were initially opened, then closed and withdrawn at the user's request. **Do not open or comment on GitHub issues unless the user explicitly asks.** Keep findings and reproductions in the local handoff.

## 5. Prepare a small Rails evidence adapter alongside the ranking run

Build a **local, opt-in prototype**, not a new production Woods feature. A practical first shape is a JSON packet producer using Woods and filesystem source, with a small TypeScript review runner adapted from Jev Review. Preserve the MIT notice if copying its code. There is no need to introduce TypeSafe into Rails request handling or the gem's default extraction path.

Use a few current, frozen examples to establish packet mechanics. Include a real Ruby source change, its RSpec/Minitest context, and one Phlex/concern-dependent case. Reuse retained matching indexes and already available testbed/source artifacts. Do not boot the private application again or run author/mutation trials for this preparation.

The packet contract must retain:

1. **Identity:** source/base/head when applicable, dirty-state fingerprint, Woods/generation identities, typed unit IDs, physical file paths, byte spans and hashes. A current fixture without historical base/head must say so.
2. **Behavioral evidence:** actual source/change plus bounded enclosing/support definitions. Relevant callbacks, associations, concerns, routes, inheritance or job/component relationships only when supported by the matching Woods extraction. Files outside extractor scope stay available through filesystem discovery.
3. **Test evidence:** recognize RSpec and Minitest separately; retain relevant complete examples and necessary hooks, helpers, factories or shared-example context when available. Record unresolved closure and omitted spans. Do not infer absence of coverage from absent selected tests. Test-only changes need an explicit supported or excluded mode.
4. **Stable candidates:** source-span IDs and explicit no-supported-issue/insufficient-evidence outcomes. When a stage selects a span, retain the relevant tests and contract rather than dropping them from subsequent calls.
5. **Operational limits:** actual serialized byte/token admission checks at every stage, freshness checks, clear per-stage failure/abstention records, requested/returned model, usage, retries and raw evidence hashes. Preserve successful work without pretending a partial run is complete.

Use `git ... -z` for path enumeration, handle new/deleted/renamed files deliberately, and bind the source reads to the frozen snapshot. Do not copy the assertion-dropping compactor or blindly follow source symlinks outside the authorized root. Prefer whole small definitions or Ruby-aware source spans with explicit omissions. Neither a model's “context complete” judgment nor a convention-resolved path proves Rails runtime closure.

For Woods itself, its self-map provides static ownership and conservative relationships. For Rails behavior, use the matching host extraction or an isolated Woods testbed. Do not turn the static map into evidence about runtime callbacks. Preserve graph variants and assembled source as separate physical spans where needed.

Initially omit purely decorative file profiles and focus on a queue a reviewer can act on. Jev can select concern category, evidence and priority; a reasoning agent or developer can establish a concrete failure mechanism and confirm it through appropriate isolated tests. A deterministic template must not invent an explanation that the selected fields do not support. Keep severity conditional on a suspected problem and distinguish it from confidence that the problem exists.

## 6. Define the first review-quality experiment without confusing it with retrieval

After the packet prototype is verified, propose a **small paired defect/fix fixture**, using independently verified behavior and legitimate negative controls from Woods and the testbed. Prepare a handful of pairs first rather than another 1,200-example campaign. Include some incomplete-evidence variants as separately labeled stress tests, not as confirmed defects.

Compare Jev screening and the cascade against the same evidence given to an ordinary reviewer, at a declared investigation budget. Retain each stage's rejected candidates so a missed real defect can be attributed to screening, localization, classification, missing evidence or a queue cap. An ablation of the cascade should test whether extra gates remove useful findings; our prior failed veto is a reason to measure that tradeoff, not a rule forbidding composition.

Measure accepted findings against the independent oracle, misses on known defects, false alarms on valid counterparts, actual downstream confirmation effort, abstention, latency and token usage. Keep the family/pair as the analysis unit. A deliberately balanced defect/fix fixture does not estimate production prevalence or production precision. Do not let finding a known target file count as detecting its bug.

The immediate authorization here is the bounded ranking run and offline Rails-prototype preparation under the existing session scope. Return the proposed review-quality fixture and its separately budgeted live comparison after the adapter is inspectable; do not silently fold a full reviewer/author/application trial into the ranking results. No automatic GitHub review submission or merge blocking belongs in this first adaptation.

## Deliverables

1. The small variant/provenance checks and corrected ledger labels, linked to artifacts rather than another full narrative audit.
2. The frozen shared-pool ranking protocol, primary/repeat results, paired PR-level accounting and cost/latency evidence, or the exact observed operational blocker if a run fails.
3. A minimal Rails evidence-packet fixture and adapter/runner design, with offline checks proving source identity, test preservation, bounds and no evaluator-target leakage.
4. A concise review-quality pilot proposal using the Jev Review architecture, with known-defect/fix pairs, ordinary-review comparator, scope and budget kept separate from retrieval mechanics.

The intended progress is now an actual small ranking result and a concrete path to cheap Rails review triage. Preserve the unusually low TypeSafe price in the decision: usefulness at acceptable quality and total cost is the criterion, not a requirement that Jev outperform every larger model in isolation.
