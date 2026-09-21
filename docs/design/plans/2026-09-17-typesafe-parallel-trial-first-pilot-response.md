# Follow-up prompt: establish a useful retrieval target before building the pilot

Read this as the coordinator's response to `AUDIT-AND-FIRST-PILOT-PROTOCOL.md`. **Accept the decision to defer assertion triage. Proceed with a small offline feasibility check for evidence selection.** The new audit resolves several earlier questions, but section 3 does not yet establish the outcome or comparison needed to justify its proposed implementation.

This response authorizes inspection and bounded offline work over retained artifacts: a development-only replayability/target audit, minimal source-card fixtures, deterministic retrieval comparisons, and a revised protocol. Do not make new provider calls, launch application/mutation/author trials or a human-labeling campaign, change production, or build a general assembled-source framework for this step. Preserve historical outputs. The coordinator has reviewed your report and current official documentation, not independently inspected your private corpus; your new counts and code-tracing conclusions remain attributed reports.

The immediate deliverable is evidence that the proposed decision is useful and measurable. It is not another comprehensive audit of every previous experiment.

## 1. Keep the resolved corrections; narrow the new claims

Accept and preserve the HTTP/SDK/cache distinction, reported containment of the audit-session `max(dict)` error, artifact census, unknown orphan provenance, withdrawal of the zero-error-rate claim, and separation of hypothetical threshold crossings from actual consumer stability. Link the supporting local artifacts where available; do not repeat the entire investigation.

Make these remaining corrections:

**Score precision.** Your retained vectors are consistent with quantization, but they do not prove that the provider rounds probabilities to two decimal places or computes `score` from higher-precision internal probabilities. The projection can also silently insert or discard levels. The current [API reference](https://docs.typesafe.ai/api) and [Score reference](https://docs.typesafe.ai/primitives/score), checked September 17, describe a probability map summing to one and a probability-weighted score; neither checked page specifies the proposed rounding contract.

Replace “rounding, not an error” with “a representation discrepancy consistent with rounding; its exact source is unresolved.” A stored sum of .99 is not by itself evidence of corruption, but neither does it certify every vector or eliminate the need for a tolerance policy. Four probabilities rounded to hundredths can have total mass above or below one. If surviving unprojected answers exist, check expected keys, legend/question identity, finite values, and mass before the adapter transformation. If only the flattened cache survives, leave projection effects versus provider precision unresolved.

For future code, retaining and consuming the returned `score` is reasonable when that is the intended feature. Preserve the original map and rubric as well. Describe the 43.1% as discrepancies, not proven accuracy errors, and do not call the returned field higher precision without evidence. The signed mean difference does not establish that absolute discrepancies are smaller than the reported mean drift. Preserve historical features and results. Any normalization must be an explicit derived representation; calculate vector-derived spread with internally consistent vector-derived moments, not a returned mean mixed with rounded/subnormalized second moments. Neither unconditional variance clipping nor blindly rejecting every approximate sum is the right resolution.

**Applicability.** The defensible finding is: “Among 25 agent-reviewed comments sampled from 37 model-screen-positive comments, two were judged to match Pilot A. This does not establish sufficient demand to prioritize A.” Keep the decision to defer it. Remove “two in a month” and the approximately five-per-month extrapolation. Twelve screen-positive comments and the screen-negative population were not audited, and the 15 spec anchors are not the denominator of the 25-item semantic sample. An application-file comment can request a stronger existing test. Do not infer the model's reason for firing, or the error rate of the other nine themes, from anchor location alone.

No additional labeling campaign is needed to justify this prioritization decision. However, distinguish preparation/annotation effort from inference cost: the previously proposed 1,200 × 2,500-input-token run costs an estimated **$0.126** at the stated rate. A small number of important findings could still be valuable; the audit does not prove their net value is low.

**Provenance language.** The 138 filtered inline comments describe a particular cohort, not an established product alert budget or review capacity. Call the 2,860 drift units repeated identities/groups where their statistic is a range over multiple observations, and retain repetition counts. State label provenance per result: numerical drift does not require correctness labels, and mechanically counted review events are distinct from model-assigned themes.

Also scope the access uncertainty by experiment. The latest Woods author study used disabled-tool configuration and checked all 28 author event logs, with no tool events observed. That is evidence for its closed-evidence protocol, not an OS sandbox or proof about an earlier selector/comparator. The early comparator's actual access remains a separate uncertainty. The distributed guide's `evidence/2026-09-16-typesafe-four-tests-plan.md` and matching evaluation report document this distinction.

## 2. Establish what the evidence-selection task actually needs

The proposed target does not yet demonstrate the stated developer problem. The 123 comments are anchored on **application or documentation** files. An anchor tells us where a comment was left; it does not establish which files a reviewer opened or what additional evidence supported the finding. The assertion that an expensive selection turn occurs many times daily also needs an existing trace or must remain a hypothesis.

More importantly, the task already supplies its PR diff. That diff may contain the target filename and the very source lines under review. A selector can appear successful by returning information already present. Before inference, distinguish:

- A target path mentioned in a diff header or card metadata.
- The relevant source content already present in mandatory diff/context.
- Additional source needed beyond that context, if an existing trace or separately attributed assessment identifies it.

Run a **diff-only coverage baseline**. Do not count a filename mention as delivered source. Historical anchors can provide mechanically extracted weak targets, but they do not exhaust useful review evidence or prove defect detection, reviewer usefulness, or avoided work. Uncommented files are not automatically irrelevant. Replace “needs no labels” with “can measure an explicitly limited historical proxy without a new annotation campaign.” If human adjudication remains a prerequisite for a stronger claim, name its availability and cost; otherwise defer that claim rather than pretending adjudication happened.

Freeze the review timestamp and inputs. Identify base/head commits representing the state to be reviewed **before the evaluated comments or their fixes**. Use only descriptions, diffs, configuration, source, and relationships available then. Keep later review text, anchor targets, fixes, final descriptions, and outcome-derived queries evaluator-only. “Merged PR plus its final diff” would reintroduce the temporal leakage you just withdrew. Record renamed/deleted paths, old/new diff sides, line mapping, and unavailable snapshots instead of silently borrowing the current index.

Define the eligible population and target aggregation. There are 162/220 PRs without filtered inline comments in your reported census; a sample of 60 PRs need not yield 60 evaluable tasks. An explicitly restricted commented-PR proxy cohort is acceptable, but it does not represent every review. Keep anchorless and unreconstructible tasks in the eligibility/accounting table; do not count absence of a target as retrieval success or failure. For multiple anchors, predeclare deduplication and whether the endpoint is any target, all targets, or per-PR target coverage. Do not count several comments on one file as independent PRs.

## 3. Separate corpus size, candidate coverage, and the intended comparison

An 80-card shortlist from a 7,111-unit index is a small corpus fraction. It does **not** establish low recall of relevant evidence. The later Woods trial already compared rankers on the same 80-card shortlist drawn from more than 4,000 physical cards. The earlier Canopy candidate-recall statistic described coverage of labeled relevant units, not the fraction of the corpus retrieved. Different card/unit definitions also prevent a direct size comparison.

Measure the following boundaries for each development task: target source exists at the chosen snapshot; is represented in the index/cards; survives discovery; survives the shortlist; and is actually delivered by packing. Attribute misses to the relevant boundary. If anchor-to-unit relevance has not been established, use names such as **eligible anchor-source coverage** instead of claiming general relevant-unit or complete-source recall. A partial path match, an arbitrary snippet from the same file, and the needed source span are different observations.

The [official reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe) separates fast discovery from scoring its shortlisted candidates. Its relevance to this pilot is that separation; its outcomes do not establish performance on your codebase. Neither ranker can recover a source item absent from its candidate evidence. Hydration can expand that evidence, so report its support-source coverage separately from base-pool coverage.

Your three arms are a valid starting point for an **offline retrieval comparison**:

1. BM25 over base cards.
2. TypeSafe reranking the same base cards.
3. BM25 with deterministic hydration.

They do not test replacement of a costly model selection turn, because that selector is absent. Choose one objective:

- **Retrieval improvement:** retain these arms and assess whether a useful measured gain justifies TypeSafe's small incremental cost. Do not require a remote inference step to be cheaper than BM25 itself.
- **Selector substitution:** identify the actual incumbent from retained traces and include it in the later protocol with equivalent information, task semantics, selection permissions, and output budget. Record actual tool access and costs. This need not become a large factorial study; defer the hydration arm if that keeps the substitution question focused.

If the actual workflow allows iterative lookup outside the frozen shortlist, a closed-pool comparator tests a bounded component substitution, not whole-agent equivalence. State that scope. Unknown model billing remains unknown; report measurable calls, tokens, latency, and capacity without inventing dollar savings. Equally useful quality at materially lower cost remains a valid reason to use TypeSafe.

Specify hydration operationally: rank base cards then attach support, or rank hydrated cards? Either can be useful, but they are different pipelines. Freeze traversal depth, byte/token caps, deduplication, ordering, missing support handling, and the packing rule. A runtime-assembled base card may already include concern source; avoid counting that source as a new hydration intervention. Apply the same final context budget, including support, headers and truncation markers. Identify mandatory diff tokens separately and make their treatment identical across arms.

## 4. Use an exploratory design that can answer its stated question

Three tasks out of 60 is a five-percentage-point margin, but the proposed final holdout contains only 20 tasks. Development and holdout cannot be pooled to establish that margin. Clarify whether “at least as many successes” is an additional observed-sample requirement or whether the intended quality rule permits a deficit. A consequential margin needs justification beyond restating that a missed file is undesirable.

Keep the first study exploratory if the sample is small. For intuition, even zero observed regressions in 20 independent tasks leaves a one-sided 95% binomial upper bound of approximately **13.9%** on that simple regression probability. This is not the paired quality-difference interval or a full power calculation, but it shows why an observed tie cannot establish a narrow noninferiority claim. PR-family dependence further limits information. Do not demand a larger campaign now just to avoid an inconclusive result.

Use development tasks for endpoint and instrumentation work. Freeze family splits, strata rules, prompts, ranking, packing, metrics, and decision rules before inspecting held-out outcomes. Prior exposure to the 220-PR corpus should be recorded; a new split does not erase earlier analysis. Architecture quotas support targeted coverage, not an unweighted population-frequency claim. Report the actual number of eligible held-out families after reconstruction and target checks.

Revise the proposed stopping rules:

- Define when discovery is limiting the chosen endpoint. Missing some relevant material is not identical to making every useful selection impossible. A development-stage finding can justify redirecting effort to discovery; a completed evaluation must retain its misses and operational failures, with conditional analyses clearly secondary.
- Unmatched timer boundaries prevent a speedup ratio, not a quality comparison. Preserve component measurements and distinguish cold extraction/card construction from warm recurring selection.
- Different packed bytes or card order do not by themselves establish harmful instability. Report score/rank changes, source-set and token-allocation changes, target coverage, and fallback/abstention changes separately. Repeats are diagnostics, not extra independent tasks. Do not automatically discard quality results because half the contexts differ.
- A small hydration point-estimate win does not prove a model is unnecessary everywhere. Likewise, difficulty building an assembled representation does not prove TypeSafe cannot help Phlex/delegator code or half the codebase. Preserve uncertainty and measured scope.

## 5. Keep the cost schedule, but size requests from actual payloads

Your new arithmetic is correct under its stated assumptions:

| Workload | Calls | Estimated input tokens | Estimated cost |
| --- | ---: | ---: | ---: |
| 60 tasks × 4 primary chunks | 240 | 2,040,000 | $0.08568 |
| One fresh exact repeat of each primary request | 240 | 2,040,000 | $0.08568 |
| 100 four-call composition blocks | 400 | 3,400,000 | $0.14280 |
| Total | 880 | 7,480,000 | **$0.31416** |

These are estimates at **$0.042/M input, free output**, not invoices. Primary recurring selection is about $0.001428 per task under this schedule; repeat/composition research costs are separate. This is inexpensive inference. The feasibility questions concern the usefulness of the target, source reconstruction, and validation effort.

Four 8,500-token chunks do not prove an unchunked request exceeds the budget: each chunk may repeat the same diff and instructions. Measure the actual assembled state/questions and choose bounded chunks with headroom. The current [primitives documentation](https://docs.typesafe.ai/primitives) describes an approximate 32,000-token shared budget; tokens, English-character estimates, and encoded JSON bytes are different quantities. Record the estimator and local cap rather than treating either as a provider byte limit.

For the later live protocol, pin the requested model, retain the returned model and full effective request identity, freeze question wording and cross-chunk sorting/ties, and count failed/retried attempts. Exact-repeat controls must reach the provider rather than replay a cache. An `A,A,B,B` block denotes two exact copies of each composition; randomize/counterbalance execution order so A is not always earlier. Keep the same effective state when testing question-composition effects. Changing neighboring source cards tests a different context intervention. There is no need to commit to 100 composition blocks before the target and consuming policy exist; retain it as a separately justified diagnostic budget.

## 6. Do the smallest useful offline check now

Use **8–12 fixed development PRs**, selected by a recorded rule to exercise the proposed architecture strata and include ambiguous/missing-target cases. This is a feasibility sample, not a prevalence estimate or holdout. Do not expand it to a 60-task implementation during this step.

Produce a row per task with:

1. PR/family ID, architecture tags, intended review time, recoverable base/head commits, source/index identity, and prior study exposure.
2. Eligible anchor paths/sides/spans, mapping confidence or failure, and whether the relevant source is already in the mandatory diff. Separate mechanical mapping from agent inference about useful extra context.
3. A query derived only from information available at review time; deterministic discovery/shortlist rules; target coverage at each boundary; and a reason for each missing target.
4. One declared extra-context token budget; diff-only, BM25, and already feasible deterministic-hydration results. Record source actually delivered, not only IDs. If hydration needs new infrastructure, mark it unavailable rather than implementing the general framework now.
5. A retained trace of the incumbent selection step, if one exists, and its observable inputs, outputs, tools, timing and usage. Otherwise mark the substitution premise unverified.

Start with whole-file cards or existing verified physical spans where sufficient. Preserve commit/path/file digest and exact byte identity; a whole file can simply be one span. For assembled content, retain separate physical support spans and their relationship rather than assigning concatenated text invented offsets in one file. Record unsupported dynamic relationships as unknown. A minimal fixture can establish whether the endpoint is useful without proving complete semantic closure of every DSL.

Reuse suitable Woods/testbed fixtures and the guide's existing source-provenance approach where they help validate mechanics, but do not treat those results as private-app performance. Woods' self-map is static evidence about the gem; it cannot substitute for a historical host Rails extraction. Do not boot the private application against its shared development database to fill a missing snapshot. If retained material is insufficient, report the exact missing artifact and the smallest isolated reconstruction needed for a later step. A current-source fixture may test mechanics if labeled as such; it cannot stand in for historical replay.

Return these four deliverables:

1. **A short errata note** applying section 1 and linking existing provenance evidence.
2. **The development feasibility table**, eligibility totals, minimal reproducible fixture/script or exact commands, and source/metric definitions. Keep private source local; the handoff can use sanitized identifiers and aggregate counts.
3. **One revised protocol**, explicitly choosing a retrieval-proxy, bounded-selector-substitution, or discovery question. Include a concrete primary endpoint, actual eligible population/holdout, credible comparator, shared input/output budgets, uncertainty, failures/fallback, and revised estimated attempt/token schedule. If the endpoint is saturated by the diff or cannot identify useful extra evidence, report that result and the smallest missing evidence; do not manufacture a positive study.
4. **A brief recommendation** stating what the offline check supports, what it cannot establish, and the single next action. Proposed guide edits should distinguish reproducible integration lessons, unresolved hypotheses, and attributed private-corpus observations; do not rewrite the sealed guide/archive or historical outcomes in this step.

Leave Pilot A deferred and the application-authoring pilot deferred until its isolation and outcome requirements are met. The next decision should turn on useful evidence and measured operational tradeoffs, while preserving the possibility that TypeSafe's very low price makes an equal-quality bounded decision worthwhile.
