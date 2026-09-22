# TypeSafe retrieval and development evidence evaluation

Completed September 16, 2026 (local time), against Woods `55a74ea4f3a7c3e798493a92663003aab85a2301`. This is a separate experiment following the [development evaluation plan](2026-09-16-typesafe-development-evaluation.md). No packaged behavior, production source, dependencies, plugin guidance, or release surfaces changed.

## Decision

Continue evaluating **inexpensive relevance ranking and evidence-span selection for coding tasks**. The frozen TypeSafe reranker improved annotated-source retrieval substantially at very low estimated inference cost. Automatic filtering did not preserve existing evidence reliably enough to adopt. The trial establishes retrieval behavior on one exposed development corpus; it does not establish better generated code or lower cost per successfully completed task.

At the native 1,200 budget, TypeSafe reranking raised mean relevant-unit recall from **57.98% to 77.02%**, and complete-source recall from **56.55% to 71.55%**. It used 3.4% more delivered context. The 28 primary selections cost an estimated **$0.01230642**, using provider-reported input usage and the supplied $0.042/MTok rate. That is approximately **$0.000440 per query, or $0.44 per 1,000 similar queries**. This cost makes advisory ranking a credible direction even without context compression.

The prespecified primary compression policy—keep candidates with Noul > 0.5, then rank—saved 19.5% of context tokens but lost previously retrieved labelled sources on 12 of 28 queries. Aggregate recall gains do not cancel those per-query losses. It failed to demonstrate generally evidence-preserving compression.

A zero-inference control, preserving Woods order but keeping only the top three valid candidates, saved **8.7%** while preserving every baseline labelled ID and complete labelled source in this corpus. That deserves independent task validation before assuming an AI filter is the best way to shorten context. Unlabelled sources are not proven useless.

## What was tested

The [checked-in retrieval evaluation](../../EVALUATION.md) supplies 62 runtime-extracted units from the fictional Canopy Rails application, 28 queries, 76 relevant query/unit pairs, and captured real MiniLM vectors. The companion testbed checkout was clean at `f5f603f92a16f385d4fc825d72c7232a75014da4`, exactly the corpus's application revision. Extraction itself came from the corpus's older documented Woods revision; this trial replays that fixed extraction through current Woods rather than claiming fresh extraction equivalence.

The eligible pool was captured **after ranking, type filtering, and within-type fallback, immediately before context assembly**. It contained 347 candidate occurrences, including three missing-metadata placeholders; 344 actual units received judgments. Available candidate recall averaged 95%, with 19 queries dropping some available labels during normal assembly. One query had no relevant candidate available at this boundary, which reranking cannot repair.

TypeSafe received the query, explicit requested types, and candidate identifier, type, path, namespace, complete extracted source, and dependencies. It received no reference labels, original ranks/scores, strategy names, or prior outcomes. Complete cards were sorted by identifier and batched into 63 requests capped at 24 KiB; the largest was 24,449 bytes. There was no source cropping. Independent Noul questions asked whether each candidate supplied concrete implementation or relationship evidence useful for the query. This follows the [reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe) and [fan-out pattern](https://docs.typesafe.ai/patterns/fan-out) underlying the [smart-home demo](https://docs.typesafe.ai/demos/smart-home).

Four fresh ordinary-model agents scored the identical packets and rubric. They were instructed to read only their assigned packets; their access logs record no label or other-output reads. The files were not made inaccessible by a sandbox. Each saved a packet's answers before reading later packets. Their contexts accumulated within shards, so this is a comparison of complete scoring policies, not an isolated provider/model capability benchmark. Their exact model identity, token usage, and billing were not available; no provider cost ratio is claimed.

Both learned arms used the same descending-score/identifier tie rule. Rerank retained the full candidate pool; filter retained scores strictly greater than 0.5. Missing-metadata placeholders remained in all policies to preserve native section-budget behavior. The real assembler's partitions, truncation, stopping behavior, structural context, and final type-rank suffix were retained. Array reordering alone would not have tested ranking, because the assembler sorts by score.

Decisions were reused unchanged at budgets 1,200, 600, and 300. Controls included native Woods, native top one/top three, lexical ranking/filtering, and smallest-unit-first. The lexical filter required any exact query-token overlap; it was a distinct fixed heuristic, not a probability estimator. Label-first ordering supplied a feasible headroom diagnostic, not an exact oracle or deployable arm.

## Results

These are macro query metrics over all 28 queries. “Full recall” requires the complete formatted source body to be present in the returned context. Context counts use `cl100k_base` on the exact final string, including suffixes; they are a reference tokenizer, not observed downstream billing.

| Policy, budget 1,200 | Relevant-unit recall | Full recall | MRR | Context tokens | Queries losing baseline labelled IDs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native Woods | 57.98% | 56.55% | .8571 | 28,019 | 0 |
| Native top three | 57.98% | 56.55% | .8571 | 25,574 | 0 |
| Lexical ranking | 51.55% | 45.48% | .6310 | 28,793 | 14 |
| Lexical filtering | 47.98% | 43.69% | .6310 | 23,024 | 17 |
| Smallest unit first | 42.08% | 39.40% | .3238 | 29,696 | 16 |
| Ordinary reranking | 73.99% | 68.63% | .8571 | 28,508 | 6 |
| Ordinary filtering | 58.81% | 54.35% | .7143 | 22,501 | 11 |
| **TypeSafe reranking** | **77.02%** | **71.55%** | **.9286** | **28,977** | **7** |
| TypeSafe filtering | 64.52% | 60.83% | .8571 | 22,561 | 12 |

Reranking is promising, but is not lossless: TypeSafe displaced a baseline relevant ID on seven queries and lost or truncated a previously complete relevant source on ten. Filtering affected 12 and 13 queries respectively. Only five queries satisfied the primary strict savings rule: fewer tokens, no lost baseline labelled ID, and no lost complete labelled source. Three baseline queries with no labelled hits were ineligible for that preservation claim.

Lowering the budget makes source-ID metrics increasingly misleading:

| Policy | Budget | Relevant-unit recall | Full recall | Context tokens |
| --- | ---: | ---: | ---: | ---: |
| Native | 600 | 50.65% | 41.19% | 13,749 |
| Ordinary reranking | 600 | 59.17% | 42.98% | 14,276 |
| TypeSafe reranking | 600 | 56.73% | 41.19% | 14,708 |
| TypeSafe filtering | 600 | 49.58% | 34.05% | 12,209 |
| Native | 300 | 35.48% | 15.18% | 7,201 |
| Ordinary reranking | 300 | 43.69% | 21.73% | 7,663 |
| TypeSafe reranking | 300 | 42.62% | 24.23% | 7,513 |
| TypeSafe filtering | 300 | 37.26% | 18.87% | 6,837 |

At 600, TypeSafe reranking's higher ID recall brought **no complete-source recall gain** over native. These budgets are repeated evaluations of the same 28 queries, not independent trials. Source relevance annotations establish neither necessary evidence nor sufficient evidence for answering a question.

## What the losses mean

The source audit separates three causes rather than treating every miss as a general TypeSafe limitation:

- **Packing and relevance trades:** for `idempotency_key`, TypeSafe preferred refund code that really implements idempotency. Those units displaced a labelled payment model under native packing. The narrow annotation set and broad usefulness rubric partly disagree; the original labels were retained unchanged.
- **Threshold and intent mismatch:** an exact model name combined with a requested job type can leave deliberately weak fallback candidates. TypeSafe gave the expected delivery job 0.21 in one such query, and two expected fallback jobs 0.33/0.16 in another. Removing all scores at or below 0.5 discards those fallbacks. Borderline relationship candidates at 0.50 and 0.49 were also removed.
- **A concrete ranking error:** for the semantic stale-review query, `ReviewDecision` scored 0.79 while the actual guard in `EditorialWorkflow` scored 0.55. At 1,200 both sources fit; at 600 this ordering cuts away the guard. The full relevant source was available, so missing input cannot explain this case.

Across the 13 baseline-labelled ID losses under TypeSafe filtering, nine were threshold exclusions and four were retained candidates lost during assembly. Better task/context design may address part of this behavior, but this run does not establish a corrected configuration or a permanent model limitation.

## Cost, performance, and reliability

The estimate uses the vendor's [published introductory rate](https://typesafe.ai/blog/introducing-system-one-models-and-jev): $0.042 per million input tokens, free output. It is not an invoice measurement.

- All **67 requests succeeded** with HTTP 200, validated `jev-1.13.0` identity, exact answer IDs, valid probabilities, and reported usage. No retries, protocol failures, or fallback selections occurred.
- Primary selection: **293,010 input tokens**, estimated **$0.01230642** for 28 queries/344 judgments.
- Including four repeat requests: **312,062 input tokens**, 7,184 output tokens, estimated **$0.013106604** total.
- One 1Password lookup supplied the bounded process; the credential stayed in memory and was not written to artifacts.
- Primary HTTP attempts: median **389.8 ms**, range 283.56–587.42 ms, summed **24.68 seconds**. Summing each query's serial chunks gives a median of **812.7 ms**, range 287–1,644 ms. The attempt timer includes HTTP setup/I/O and response parsing/validation, but excludes initial request reading/parsing, initial/final capture persistence, and preparation. The full serial batch spanned approximately 31 seconds. These are not ordinary-agent latency comparisons; the generated cost artifact's broader timer label is imprecise.
- Repeats covered all four chunks of the first query, 20 judgments. Maximum probability change was 0.05, with no filter-threshold crossings. Ranking order nevertheless changed. Replaying the repeat scores changed delivered text at budgets 1,200 and 600; at 600 it displaced the initially included labelled `Billing::CollectPayment` with an unlabelled refund service. No primary result was replaced by the repeat. Do not call the probabilities, ranking, or packed evidence deterministic.

Filtering saved 5,458 reference context tokens. Its selector cost alone breaks even at about **$2.25 per million downstream input tokens**, assuming those reference-token savings translate to billing, no caching, and no additional preparation/escalation cost. At a purely hypothetical $5/MTok downstream rate, the gross net estimate is $0.015 saved across all 28 queries—but the evidence losses make this unsuitable as a quality-preserving savings claim.

Reranking increased context by 958 reference tokens across the batch. Its value would come from better coding evidence or avoided follow-up work, not this experiment's context compression. At the measured selection price, a small downstream benefit could justify it; that benefit still needs a completed-task experiment. The ordinary scorer's unknown billing prevents quantifying substitution savings.

## Testbed behavior audit

A separate protocol, frozen before selector outcomes, checked whether a specific source guard matters in actual Rails behavior. It used an isolated application copy and fresh SQLite test database inside the existing Canopy container. Live application source and databases were left unchanged.

The existing stale-review test edits an article and then attempts an old approval. That already fails because editing resets the article to `draft`; it does not isolate the latest-revision check once the article returns to `in_review`.

The new regression submits a revision, edits and resubmits another revision, then attempts approval through the old assignment. It requires the stale exception, no review-decision write, unchanged `in_review` state, and successful approval through the current assignment afterward.

| Executed check | Result |
| --- | --- |
| Original application, existing suite | 32 examples, 0 failures |
| Original application, new regression included | 33 examples, 0 failures |
| Remove only latest-revision comparison; existing suite | 32 examples, 0 failures |
| Same controlled mutation; new regression | 1 failure: obsolete approval raised nothing |
| Restore original code; new regression | 1 example, 0 failures |

This confirms a **coverage gap**, not an existing application defect. TypeSafe did not discover or author this test; the testbed audit did. It supplies an executable target for evaluating evidence selection.

For two existing stale-review queries, native retrieval omitted `EditorialWorkflow`. Both learned policies at budget 1,200 supplied the source containing all four prospectively fixed indicators: revision creation, current-revision guard, stale rejection, and decision creation after the guard. At 600, the stale-rejection and decision-write indicators were absent; at 300, none of the four indicators was present. A source attribution therefore did not establish that all four predeclared indicators survived. Their absence is not proof that every remaining token is useless or that all four indicators are necessary for every downstream task.

## Woods self-scan and next experiment

The disposable Woods self-map was also queried through the packaged MCP launcher: status, search, three exact method lookups, and a bounded dependency lookup. It was ready and the returned method source matched current Woods. `Retriever#build_result`, `#append_type_rank_context`, and `ContextAssembler#build_result` explain why the final returned context can exceed reported assembler tokens: the retriever appends a type-rank table afterward. The dependency query returned only its root and supplies no outgoing-edge evidence. The static map establishes source structure, not runtime Rails facts.

The next bounded experiment should use **method or guard spans as evidence candidates**, with two task families:

1. Canopy behavior tasks whose success is checked by executable regressions and controlled mutations, starting with stale approval after resubmission.
2. Woods gem-development tasks built from the self-map, starting with final-context token accounting and the existing focused retrieval specs.

The two starter tasks above are now exposed development examples, suitable for building the next harness. Use additional unseen tasks for validation. Freeze those tasks, candidate spans, exact source/hash/range verification, mutation checks, and success criteria before selection. Compare native context, the cheap top-three control, ordinary selection, and TypeSafe selection. Keep incumbent evidence available while judging additional spans; measure both added evidence and the total downstream context. An independently checked coding task must then pass the intended regression and existing tests. Record actual author input/output usage, tool reads, retries, elapsed time, and selection cost. Do not use retrieval labels as a substitute for task completion.

Do not retrofit tuned thresholds or strategy switches to this exposed corpus and report them as a fresh validation. In particular, semantic usefulness filtering conflicts with some deliberately weak within-type fallback cases, and native packing can replace one relevant component with another. The next task design should make the required relationship and downstream operation explicit.

## Validation and artifacts

The frozen protocol passed an independent prospective methods review after duplicate-JSON and malformed-output handling were corrected. Ninety-eight source/input/scoring bindings were frozen before selection; 104 bindings, including complete ordinary outputs and the review, were checked before live calls. Missing or malformed whole-query decisions would have fallen back to native behavior under the frozen rules.

Validation included native/instrumented equivalence for all 28 queries at all three budgets, the existing captured retrieval gate, identity-score replay, invalid membership/order/probability rejection, whole-query failure handling, duplicate JSON rejection, actual delivered-source ledgers, and final-string tokenizer recounts. Focused Woods retrieval/MCP specs passed: **166 examples, 0 failures**. The full gem suite and Rails compatibility matrix were not rerun because production code was unchanged; the separate Canopy behavior checks are listed above.

Local ignored artifacts under `tmp/typesafe-retrieval-pilot/` preserve the experiment:

- `protocol.md`, `prospective-freeze.json`, `live-go.json`: prospective decisions and bindings.
- `capture/`: boundary snapshots, provenance, native equivalence, headroom and replay harness.
- `requests/`, `mapping.json`, `baseline/`: exact provider inputs and ordinary decisions.
- `capture.json`, `decision-status.json`, `decisions/`, `replays/`: validated provider outcomes and native replay.
- `measurements.json`, `summary.json`, `costs.json`: per-source delivery, paired quality, reference tokens and costs.
- `operational-diagnostics.json`, `repeat-assembly-diagnostic.json`: repeat scope, probability-order changes and actual delivered-context changes.
- `behavior/`: isolated runner, portable regression spec, red/green logs, span results and independent isolation audit.
- `self-map-probe.json`, `method-review.md`, `outcome-review.md`, `candidate-outcome-audit.md`: source evidence and independent reviews.

These local captures are not bundled with the gem. No secrets, generated Woods index, or runtime integration were added to tracked source.
