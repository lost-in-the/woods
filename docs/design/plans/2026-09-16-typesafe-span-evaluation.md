# TypeSafe method-context coding repair evaluation

Study baseline: Woods `55a74ea4f3a7c3e798493a92663003aab85a2301`, September 16, 2026 local time. This follows the [retrieval evaluation](2026-09-16-typesafe-retrieval-evaluation.md). Production source, dependencies, MCP schemas, plugin guidance, and release surfaces are unchanged.

## Decision

Continue evaluating **TypeSafe as an optional method-context selector for coding agents**. Under this frozen test protocol, TypeSafe-ranked method evidence led to accepted repairs on **4/4 tasks**, versus **2/4** for lexical-ranked method evidence. Whole-file policies scored **3/4** with TypeSafe and **2/4** with lexical ranking. TypeSafe selected evidence; the separate Codex author wrote each patch.

The estimated selector cost is small enough that better repairs could justify it without context compression: all TypeSafe selections cost approximately **$0.00304**, and the method policy averaged **$0.000524 per task**. This four-task study supports a larger trial, not default production integration or a claim of general coding superiority. Passing the frozen tests is the primary endpoint, not proof that a patch preserves every behavior.

## Purpose and design

The previous experiment showed inexpensive relevance ranking could improve annotated retrieval, but did not measure generated-code quality. This experiment tests executable repairs under a fixed source-context budget.

Cross two rankers (deterministic lexical overlap and TypeSafe Noul relevance) with two representations (whole files and methods plus supporting source). Each of four controlled regressions receives all four policies: **four task blocks, 16 intended author attempts**. The circuit-breaker and retry-delay cases share a resilience theme.

| Controlled regression | Editable source | Existing focused examples |
| --- | --- | ---: |
| Flow filename identity | `lib/woods/filename_utils.rb` | 7 |
| Interrupted circuit-breaker recovery | `lib/woods/resilience/circuit_breaker.rb` | 20 |
| Publication-catalog visibility | `lib/woods/published_index/generation_catalog.rb` | 24 |
| Server-directed retry delay | `lib/woods/resilience/retryable_provider.rb` | 29 |

These mutations simulate regressions of already-correct code; they are not new Woods bugs. Before selection, every baseline passed both its independent behavioral acceptance and matching existing specs, while every mutant failed both for the intended assertion. Each acceptance also checks nearby preserved behavior.

Both representations receive the same curated three-file universe per task. Woods' disposable static self-map supplies method names, coordinates, namespaces, and visibility; candidate source bytes come exclusively from each mutant. The resulting packets contain 12 whole-file candidates and 104 method/support candidates (85 methods, 19 support spans). One Struct method missing from the static method map remains in supporting source. Only whitespace, closing `end`, and bare visibility lines are omitted. This use of the self-map establishes static source boundaries, not Rails runtime behavior.

Both rankers see neutral symptoms, preserved behavior, editable paths, and candidate source. Neither receives the original target implementation, mutation diff, tests, outcomes, or private edit-site labels. Contract comments remain in the source. Lexical matching includes editable paths as well as the task description. TypeSafe uses the same pointwise usefulness criterion for both granularities, following the [reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe) and [semantic-find pattern](https://docs.typesafe.ai/cookbooks/semantic_find).

All policies rank their full pool with the same tie rule and ordered-prefix packer. There is no filtering, candidate-count cap, oversized-item skipping, or oracle repair. Each context is capped at **1,000 cl100k_base reference tokens**, including source headers, fences, and truncation markers. A candidate fits completely or contributes a deterministic feasible prefix, after which packing stops. This is one prospective operating point; it was not tuned against these outcomes.

## Author and validation protocol

The configured author is Codex CLI 0.153.0 with the user's existing `gpt-5.6-sol`/low setting. Configuration bytes are hashed and verified before every launch; this records configuration rather than an independently returned model identity. All 16 prompts and contexts are frozen before authors. Each receives one fresh, opaque temporary working directory and one attempt, in a fixed shuffled order. Tools, MCP, plugins, browsing, shell access, memory, and delegation are disabled through transient CLI flags. Shared user/system instructions may remain; this is a closed-evidence protocol, not proof that all host files are physically inaccessible.

Authors return at most eight exact replacements or abstain. No follow-up, test feedback, output repair, or retries are allowed. Replacements must match visible evidence and a unique original occurrence in an allowed mutant file, without overlap. Empty replacement text permits deletion. The evidence rule checks the literal anywhere in the rendered context; it does not itself prove the target occurrence was visible, so file-scoped mutation-site visibility is recorded separately.

The coordinator reviews submitted patches for execution hazards or evaluator bypass only. Ordinary incorrect fixes proceed to tests. Each eligible patch is applied to a separate verified copy of the frozen mutant tree. Acceptance requires valid application, Ruby syntax, independent behavioral acceptance, and existing focused RSpec all to pass. Failures and abstentions remain in the 16-cell denominator.

Actual CLI token usage is retained for every attempt. Missing or invalid required usage is a protocol failure, with raw events and any partial known counts preserved. Missing optional counters are unknown, not zero. No author statement about test execution substitutes for executed tests.

## Primary repair results

“Pass” requires exact patch application, syntax, independent acceptance, and the matching existing specs. “Fail” means a valid, syntactically correct patch failed both behavioral lanes. Abstentions remain failed intended attempts.

| Task | Lexical whole | TypeSafe whole | Lexical method | TypeSafe method |
| --- | --- | --- | --- | --- |
| Flow filename identity | Pass | Pass | Pass* | Pass |
| Interrupted recovery probe | Pass | Pass | Fail | Pass |
| Publication catalog | Abstain | Pass | Fail | Pass |
| Server-directed retry delay | Abstain | Abstain | Pass | Pass |
| **Accepted / intended** | **2/4** | **3/4** | **2/4** | **4/4** |

All 16 author attempts completed with valid usage telemetry and no observed tool events. Thirteen submitted patches passed format, evidence, application, and syntax checks; eleven passed both behavioral lanes. Two failed both, and three authors abstained. There were no retries, repaired submissions, hazard rejections, timeouts, or operational exclusions.

Both lexical-method behavioral failures occurred with the mutation site absent from the selected context; their submissions were valid and syntactically correct. The circuit-breaker patch modified ordinary failure accounting, leaving the interrupted-probe bug intact. The catalog patch changed current-payload filtering, leaving the future-generation allowance intact. TypeSafe method ranking supplied the complete relevant methods in both cases.

For retry delay, both whole-file policies omitted the relevant edit site and abstained, while both method policies repaired the mutant. Conversely, whole-file context repaired the probe under both rankers, while lexical method selection missed its interrupted-cleanup path. Smaller snippets alone were not sufficient.

| Policy | Mutation sites visible | Complete containing candidates | Delivered context tokens across four tasks |
| --- | ---: | ---: | ---: |
| Lexical whole | 2/4 | 0/4 | 3,999 |
| TypeSafe whole | 3/4 | 1/4 | 3,998 |
| Lexical method | 2/4 | 2/4 | 3,948 |
| TypeSafe method | 4/4 | 4/4 | 3,926 |

“Complete containing candidate” means an entire file in whole-file arms and an entire method/support span in method arms, so these counts are not equivalent units of evidence. Coverage is diagnostic, not the acceptance definition. Whole contexts were byte-identical across rankers for flow identity, interrupted recovery, and retry delay; all six intended attempts remain included. Actual context sizes ranged from 934 to 1,000 reference tokens.

*The accepted lexical-method filename patch receives a separate posthoc compatibility audit below; primary labels remain frozen.

## Posthoc compatibility audit

The lexical-method filename patch passed the frozen tests but omitted the original `to_s` coercions. Eight additional probes showed baseline and the other three filename repairs agreed throughout. This patch alone raised `NoMethodError` in five probes involving Symbol or custom `to_s` inputs. Its ordinary String behavior remained correct.

This is a generated-patch compatibility gap missed by the String-only oracle. The helper documents String arguments and inspected normal callers supply Strings, so this is not established as a promised public-contract violation or an existing production bug. It does demonstrate why passing tests should not replace patch review. The **2/4 lexical-method primary score is retained**, with this qualification, rather than silently rescored after outcomes. No GitHub issue was filed for a defect present only in an experimental generated patch.

The independent audit also confirmed that the two lexical-method behavioral failures reproduce their intended regression assertions; they are not syntax, environment, or grading failures.

## Actual author usage

These are raw CLI-reported totals for all four attempts in each policy, including failures and abstentions. Reasoning is reported separately and is not added to output again. Shared instructions and protocol overhead remain in input usage; the 1,000-token cap concerns selected source, not the whole invocation.

| Policy | Input tokens | Cached input | Output tokens | Reported reasoning output | Author process seconds, summed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Lexical whole | 41,010 | 7,040 | 894 | 510 | 44.06 |
| TypeSafe whole | 41,005 | 7,040 | 925 | 423 | 35.45 |
| Lexical method | 40,936 | 21,120 | 2,250 | 1,519 | 72.10 |
| TypeSafe method | 40,931 | 7,040 | 1,060 | 570 | 43.59 |

Total reported author usage: **163,882 input**, **42,240 cached input**, **5,129 output**, and **3,022 reasoning output**. All cache-write counters were zero. Author processes summed to 195.21 seconds; the serial batch took approximately 206.39 seconds from author-freeze approval to completion, including harness overhead.

Author input was essentially unchanged across policies, as expected under a common source budget. Lexical-method calls happened to receive more cache hits despite the fixed shuffled launch order; the table does not establish lower billed author cost for TypeSafe. Output and elapsed-time differences are also single-run observations, not causal performance estimates.

For a conditional API-style cost calculation, let U, C, and O be dollars per million uncached input, cached input, and output tokens. Across these four tasks, method selection plus authors would cost `(33,891U + 7,040C + 1,060O) / 1,000,000 + $0.002096598` for TypeSafe and `(19,816U + 21,120C + 2,250O) / 1,000,000` for lexical ranking, treating cached input as a subset of input. This is a price sensitivity formula, not actual CLI billing or subscription consumption. The measured benefit here is accepted repairs under a fixed evidence limit, not proven token or billing savings.

## Selector cost and reliability

All 16 TypeSafe requests completed with HTTP 200 and valid `jev-1.13.0` responses: 116 judgments, no retries or lexical fallbacks, and one 1Password lookup. Total provider usage was **72,411 input / 2,268 output tokens**, costing an estimated **$0.003041262** at the supplied $0.042 per million input tokens with free output. The rate is also described in the vendor's [introductory pricing announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev); this calculation is not an invoice measurement. Curator/reviewer agent usage and development time are not included; this is the selector inference estimate, not the total cost of conducting the study.

| Selected representation | Requests for four tasks | Input tokens | Estimated total | Average per 1,000 similar task selections |
| --- | ---: | ---: | ---: | ---: |
| Whole files | 5 | 22,492 | $0.000944664 | $0.236 |
| Methods/support spans | 11 | 49,919 | $0.002096598 | $0.524 |

A deployed policy would pay for its chosen representation, not both experimental arms. Method ranking costs more here with additional candidate/question framing and repeated task state across chunks, but remains inexpensive. These figures support judging the feature by repair quality and latency, not requiring it to save source tokens merely to justify the selector bill.

Median request latency was 446.7 ms; recorded selector call timers summed to 7.694 seconds across both representations and four tasks. These timers include HTTP setup, transfer, and response validation; they exclude surrounding request reads and persistence, curation, mapping, packet construction, reviews, author execution, and tests. Request wire size totaled 279,279 bytes, with a 24,199-byte maximum. Pointwise scores are relevance judgments, not calibrated probabilities of a successful repair.

The two task-free CLI setup calls consumed 18,094 input / 62 output tokens, with zero reported cached input. They are excluded from the 16-cell usage analysis. CLI billing or subscription capacity consumption was not measured; TypeSafe tokens and author tokens are never added as equal-cost units.

## Confirmed findings filed separately

- [Woods #354: Retriever reports token counts before final context postprocessing](https://github.com/lost-in-the/woods/issues/354). The final string can contain more tokens under the same estimator than reported in `tokens_used` and trace, after postprocessing appends content. The reproducer distinguishes inaccurate accounting from the documented assembly-budget contract.
- [woods-testbed #23: Add regression coverage for stale approval after editing and resubmitting](https://github.com/lost-in-the/woods-testbed/issues/23). Current application behavior is correct; this is a coverage gap. The existing 32 tests also passed a guard-removal mutant; the proposed 33rd test passed correct behavior and caught the mutant. The testbed worktree remains clean.

These findings came from the preceding retrieval/testbed audit. Deliberate mutations and local experimental harness corrections are not filed as product bugs.

## Evidence and scope

Ignored local evidence lives under `tmp/typesafe-span-pilot/`: `protocol.md`, the candidate/task manifests, requests and capture, selected contexts, author events and exact patches, validation logs, analysis, and independent reviews. The prospective freeze binds 3,541 files, including the four complete 870-file mutant trees. A second freeze binds final contexts before authors. Earlier retrieval results remain immutable.

The 13 submitted repairs ran 238 focused examples across repeated task suites: eleven suites passed, and the two incorrect repairs each failed their existing regression example. Both also failed independent acceptance. These are repeated validations of four tasks, not 238 independent coding observations. Validation commands summed to 23.72 seconds, with 37.53 seconds of evaluator wall time. The staged run from selector freeze to primary results took 529.54 seconds, including inter-stage reviews; it excludes initial curation and subsequent reporting and is not an automated production-latency benchmark.

The evaluator passed 36 offline parser/patch/telemetry checks. An independent preflight exercised eight disposable controls through the real evaluator: all four known restorations passed both behavioral lanes; four harmless edits retaining the regressions failed both. These controls and two task-free CLI operational preflights are excluded from the experimental outcomes.

This is a small, curated repair study with known editable files, visible contract comments, a supplied file universe, and one author draw per cell. It does not measure unrestricted repository localization, novel bug discovery, new feature implementation, production Rails behavior, or calibrated success probabilities. Identical selected contexts remain separate attempts. Full gem, booted-Rails, and live-backend suites are not rerun because production code is unchanged; the relevant focused suites execute within isolated mutant copies.

## Recommended next experiment

Use fresh Woods and woods-testbed development tasks to test the method selector under more realistic retrieval and author conditions. Keep this trial unchanged as development evidence.

1. Freeze held-out task briefs and behavioral tests before selecting context. Include a genuine small feature addition as well as repairs; audit input-shape and nearby-behavior preservation so acceptance is not limited to the visible symptom.
2. Generate candidate pools through Woods lookup/search and testbed runtime extraction, removing the curated three-file localization advantage. Include exact identifier lookup and deterministic ranking as controls. The static Woods self-map remains useful for gem code; Rails behavior must come from booted application extraction.
3. Compare the fixed method selector with deterministic selection and a larger/full-source reference. Predeclare context budgets and repeat author draws so a single author response or cache pattern cannot carry the conclusion. Preserve complete selected methods and mechanically defined supporting context; test packing separately from scoring rather than tuning it against held-out outcomes.
4. Keep TypeSafe advisory, with deterministic fallback on service failure and no automatic rejection of sources based on an uncalibrated Noul threshold. Continue exact-source provenance, one-process credential lookup, independent execution, actual author telemetry, and separate selector pricing.

Promotion would require replicated repair/feature success without meaningful losses against the deterministic control, preserved compatibility under broader tests, and measured end-to-end latency. TypeSafe's very low selector price makes this worth testing even if author input tokens barely change. No runtime dependency, default retrieval policy, or automatic patch application is proposed by this study.
