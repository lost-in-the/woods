> Portable evidence copy. Historical status and proposed commands are preserved; this is not a promise that the planned APIs were implemented. Links and the installed-skill location were normalized for portability. Raw ignored captures and external source snapshots are not included.

# TypeSafe: discovery, context budgets, new features, and repeatability

Completed September 16, 2026 local time (September 17 UTC), against Woods `55a74ea4f3a7c3e798493a92663003aab85a2301` and woods-testbed `f5f603f92a16f385d4fc825d72c7232a75014da4`. This follows the [frozen four-test plan](2026-09-16-typesafe-four-tests-plan.md) and [method-context pilot](2026-09-16-typesafe-span-evaluation.md). Production source and packaged behavior are unchanged.

## Decision

TypeSafe remains promising as an inexpensive, optional source-context ranker. At a 1,000-token source budget, its selected contexts produced accepted patches on **4/4 tasks on each author draw**, compared with **3/4 for BM25 on each draw**. Both rankers reached **4/4 at 3,000 tokens**, and BM25 also reached 4/4 at 8,000. The difference came entirely from one SQLite repair: BM25's small context lacked the SQLite implementation, and both authors appropriately abstained.

The two genuinely new features succeeded under every tested condition. This demonstrates that TypeSafe-selected evidence can support writing new code, but establishes no feature-completion advantage over deterministic selection. TypeSafe supplied relevance judgments; a separate coding model wrote every patch.

Primary selection cost an estimated **$0.00704172 across four tasks**, or **$1.76 per 1,000 similar selections**. That price is low enough to justify further optional use without demanding compression as its sole benefit. Here a smaller TypeSafe context matched the observed completion count of the larger BM25 context, but four tasks do not establish equal population quality, actual billing savings, or a validated production policy. Prefer a strong deterministic baseline, retain ordinary code review and tests, and evaluate the selector as a replaceable advisory stage.

## What the four tests measured

The four questions share **four task blocks and 28 author attempts**, not four independent datasets. The questions address description-only source discovery, evidence budgets, genuine features, and selector/author stability plus failure handling.

| Task | Kind | Baseline and independent oracle |
| --- | --- | --- |
| Newsletter publication isolation | Controlled repair, Canopy | Original/reference: 32 existing and 3 hidden examples pass. Removing only publication scoping keeps 32 existing green but fails 2 hidden examples. |
| Payment `refundable_cents` | Additive feature, Canopy | No implementation was removed. Existing 32 examples pass; absent feature fails all 6 hidden examples. Reference passes both suites, including STI, fresh persisted-refund sums, cached/unsaved association cases, zero clamp, and no writes. |
| Query `exclude_tags:` | Additive feature, Woods | Existing 29 examples pass without feature; hidden acceptance fails on unknown keyword. Reference passes exclusion/inclusion composition, exact equality, order/identity, immutability, and JSON-loaded queries. Four wrong feature variants fail. |
| Literal metadata punctuation search | Controlled repair, Woods | Correct/reference pass 91 existing examples and hidden acceptance. Removing underscore escaping fails 3 existing examples and hidden acceptance. Other escaping mistakes are rejected. |

Each incomplete Woods snapshot received a fresh static self-map; each Canopy snapshot received a fresh ordinary booted Rails extraction with 392 units and successful index validation. Runtime extraction establishes Rails structure; Prism source segmentation supplies exact physical source spans. The Woods map remains static evidence, not Rails reflection.

No private target filenames, reference patches, hidden tests, or labels entered selection or author prompts. Public briefs described required behavior, and ordinary source comments remained visible. Authors could edit any delivered existing Ruby file under `lib/` or `app/`; curator target files were diagnostics, not hidden edit restrictions.

## Test 1: automated discovery and candidate availability

A fixed tokenizer built an escaped OR search from the task description alone, using packaged MCP search over identifiers and source. Eligible source/type families were fixed prospectively; tests, documentation, configuration, and other runtime types were excluded. The query retained the packaged 500-source scan cap and a 1,000-result limit; no response reported partial scanning or reached the result cap.

| Task | MCP hits | Discovered eligible files | Segmented cards | Shared shortlist |
| --- | ---: | ---: | ---: | ---: |
| Newsletter | 59 | 59/65 | 174 | 80 |
| Payment | 59 | 59/65 | 172 | 80 |
| Query exclusions | 267 | 258/261 | 4,189 | 80 |
| Literal search | 271 | 261/261 | 4,192 | 80 |

Every private target file was indexed, discovered, represented in the shortlist, and at least partly delivered in every enrolled context. This is file availability, not sufficient-evidence recall. The broad OR search touched nearly the entire Woods source inventory, so it does not demonstrate efficient localization for large repositories.

BM25 used fixed k1=1.2 and b=.75 over identifiers, paths, namespaces, and source, with deterministic ties. Both rankers received the same top-80 pool. This BM25 baseline differs from the prior pilot's unique lexical overlap; their rates must not be pooled. No shortlisted card required the prospective 16 KiB clipping rule.

Before inference, review caught a representation defect: the initial segmenter dropped bare visibility declarations without carrying visibility metadata. Version 1 was archived; version 2 retains actual `public`/`private`/`protected` lines as support source. Queries, scoring, budgets, packing, and prompts were unchanged. Keeping declarations in the corpus does not guarantee the shortlist or budget delivers them.

## Tests 2 and 3: evidence budgets and code completion

All conditions used the same ordered-prefix packer: append whole rendered cards until one does not fit, deliver its marked feasible prefix, then stop. No hidden hydration, oversized-card skipping, or oracle-based repair was added. Headers and truncation markers count toward the cl100k_base source budget. The 8,000-token arm is a larger reference, not a claim of full repository evidence.

| Task | BM25 1k draw 1 | TypeSafe 1k draw 1 | BM25 3k | TypeSafe 3k | BM25 8k | BM25 1k draw 2 | TypeSafe 1k draw 2 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Newsletter repair | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| Payment feature | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| Query-filter feature | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| Literal-search repair | Abstain | Pass | Pass | Pass | Pass | Abstain | Pass |
| **Accepted / intended** | **3/4** | **4/4** | **4/4** | **4/4** | **4/4** | **3/4** | **4/4** |

All 26 submitted patches passed exact application, Ruby syntax, hidden behavior, and existing focused tests. Two abstentions remain in the 28-cell denominator. No submission was retried, corrected, excluded, or rejected for hazards. There were no author tool events, malformed telemetry, process failures, syntax failures, or behavioral failures.

TypeSafe's small SQLite context included the search implementation but omitted its escaping helper. Both authors replaced the SQL matching expression with parameterized `instr(lower(...), lower(?))`. TypeSafe 3k and BM25 8k delivered the helper and restored underscore escaping directly. BM25 3k also produced a SQL rewrite. The selected evidence therefore affected implementation scope, not merely whether the target file appeared.

Private tests and task briefs were curated. This remains a source-only, closed-evidence experiment with ordinary code comments, controlled regressions, four fresh evaluation tasks, and at most two author draws—not an unrestricted agent benchmark or statistical holdout study.

## Test 4: stability, fallback, and freshness

An exact second selector pass was diagnostic only; all author contexts used the original primary ranking. Repeated 1k authors received byte-identical original prompts and source, separating author variation from selector variation.

| Task | Largest Noul change | Entire rank order unchanged | 1k context unchanged | 3k context unchanged |
| --- | ---: | --- | --- | --- |
| Newsletter | .05 | No | Yes | No |
| Payment | .05 | No | Yes | No |
| Query exclusions | .11 | No | No | No |
| Literal search | .05 | No | Yes | Yes |

Acceptance agreed in all 8 first/repeat author pairs. Exact submission JSON, including its summary, was identical in only 1/8; the replacement arrays were identical in 3/8 (the two newsletter pairs and the empty BM25 SQLite abstentions). Equivalent success is not deterministic generation. Replaying one capture is not a new selector repeat.

All 133 offline fallback/freshness checks passed. Missing chunks, wrong model, missing/extra answer IDs, wrong answer type, Boolean/nonfinite/out-of-range probabilities cause whole-task BM25 fallback; partial scores are not mixed with baseline ranks. Tested fallbacks reproduce baseline packed bytes at all three budgets. A changed source fingerprint stops the workflow. These are fault-injection checks, not observed service incidents: all 60 live requests succeeded, and no live fallback occurred.

## Usage and economic interpretation

The rate is the supplied and [published introductory estimate](https://typesafe.ai/blog/introducing-system-one-models-and-jev): $0.042 per million input tokens, free output. These are token-derived estimates, not invoices.

| Selector scope | Requests | Judgments | Input | Output | Estimated USD |
| --- | ---: | ---: | ---: | ---: | ---: |
| Primary | 30 | 320 | 167,660 | 6,200 | $0.00704172 |
| Diagnostic repeat | 30 | 320 | 167,660 | 6,200 | $0.00704172 |
| Total | 60 | 640 | 335,320 | 12,400 | $0.01408344 |

All responses reported `jev-1.13.0`, passed exact response validation, and returned HTTP 200. One 1Password lookup supplied the entire process in memory. No credential was stored in artifacts. Primary HTTP timers had median 434.43 ms, p95 615.08 ms, and summed 13.72 seconds. The serial two-pass batch spanned approximately 57 seconds including repeated integrity checks and persistence. HTTP timers do not measure end-to-end preparation or whole-agent latency.

Primary scores were reused for each budget and author draw; a recurring selection would not pay for the diagnostic repeat or all comparison arms. Automatic discovery and request construction now exist in this experiment, but curation, reviews, task/oracle preparation, and integration maintenance still cost time and were not metered.

| Author condition | Input | Cached input subset | Output | Reasoning output subset | Process seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| bm25_1000_r1 | 41,175 | 7,040 | 1,303 | 478 | 44.87 |
| bm25_1000_r2 | 41,169 | 14,080 | 1,575 | 744 | 52.43 |
| bm25_3000_r1 | 49,215 | 21,120 | 1,864 | 446 | 54.43 |
| bm25_8000_r1 | 69,295 | 21,120 | 1,874 | 646 | 58.66 |
| typesafe_1000_r1 | 41,167 | 21,120 | 2,076 | 499 | 58.01 |
| typesafe_1000_r2 | 41,165 | 21,120 | 1,940 | 559 | 55.87 |
| typesafe_3000_r1 | 49,173 | 14,080 | 1,779 | 533 | 54.10 |

Total author usage was **332,359 input**, of which **119,680 cached**, **12,411 output**, including **3,905 reasoning**; cache writes were zero. Do not add cached or reasoning subsets again. All 28 attempts are included. The author configuration was Codex CLI 0.153.0, existing `gpt-5.6-sol`/low settings, verified by configuration hash before every launch. This is configured identity, not independently returned provider identity. Actual subscription billing and capacity use were unavailable.

For the primary TypeSafe-1k versus BM25-3k comparison, observed author input decreased by 8,048 tokens across four tasks, but output increased by 212. Both arms reported 21,120 cached input. If U and O are hypothetical dollars per million uncached input and output, the observed four-task cost difference (TypeSafe minus BM25) would be `$0.00704172 - 0.008048U + 0.000212O`, before preparation, escalation, review, and maintenance. This is sensitivity arithmetic over one run, not a savings estimate or a demonstrated noninferiority result. Other arms have different cache hits. Ordinary repeated authors with identical prompts also report slightly different total inputs.

## Supplementary compatibility audit and filed issues

All five accepted literal-search patches and the untouched correct baseline also passed `spec/retrieval/search_executor_spec.rb` plus `spec/retrieval/ranker_spec.rb`: 116 examples per run, 696 repeated validations. This extra lane matters because three submissions edited SearchExecutor as well as the originally targeted metadata store. The frozen primary tests did not cover that additional file.

A separate 19-case-per-adapter probe, plus field-attribution checks, found that all five patches narrow InMemory's Unicode case folding. Three also change matched-field attribution and a sample keyword score from .5 to .25. The existing interface explicitly makes non-ASCII folding backend-specific; these are observed compatibility changes, not established violations of the promised ASCII contract. No primary score was revised. SQL-rewrite performance remains unmeasured.

The audit also independently reproduced two bugs in unmodified Woods, after matching remote main/source and checking all-state issues. Three SQL-rewrite submissions incidentally avoid the NUL bug; direct underscore fixes retain it. This unplanned behavior does not receive additional primary credit.

New issues filed during this experiment:

- [woods-testbed #24](https://github.com/lost-in-the/woods-testbed/issues/24): newsletter publication-isolation regression coverage. Current application code is correct; the controlled mutant proves the test gap.
- [Woods #355](https://github.com/lost-in-the/woods/issues/355): SQLite NUL queries broaden matches and cannot find substrings after a stored NUL.
- [Woods #356](https://github.com/lost-in-the/woods/issues/356): field-scoped Boolean searches use different representations across InMemory and SQLite.

Earlier findings remain [Woods #354](https://github.com/lost-in-the/woods/issues/354), final-context token accounting, and [woods-testbed #23](https://github.com/lost-in-the/woods-testbed/issues/23), stale-review regression coverage. These findings came from deterministic/source/execution audits, not autonomous TypeSafe bug discovery. No production fixes were applied.

## Validation, artifacts, and next use

Prospective methodology, final representations, selected contexts, and execution harnesses received independent review. The harness has 47 checks plus 14 independently exercised adversarial checks; all four reference patches passed the actual evaluator. Source/selection freezing bound 11,867 files, and the author freeze bound 11,929. All prior retrieval and span-study bindings and final artifacts remain unchanged.

Primary execution ran 1,169 RSpec examples across 40 processes with zero failures/pending, plus 12 passing standalone Ruby acceptance invocations and 29 Ruby syntax checks. Those repeated examples validate 26 submitted patches; they are not independent coding tasks. Posthoc retrieval checks add 696 examples. Full gem/lint and the Rails compatibility matrix were not rerun for these research artifacts because no production source changed. Canopy cases ran actual Rails 8.0.5.1/Ruby 3.3.1 in isolated copies and fresh databases; Woods cases used Ruby 4.0.6.

Local ignored evidence is under `tmp/typesafe-next-four/`: protocol/reviews, v1 archive and representation revision, fresh indexes and source-snapshot manifests, discovery/input/request ledgers, capture, contexts, author events/patches/validation, cost and outcome analysis, posthoc compatibility logs, and issue reproductions. The complete incomplete-source snapshots live in external disposable `/tmp` checkouts referenced by those manifests. The durable plan/results summarize this evidence; raw personal execution logs and complete generated indexes are not portable deliverables.

The next implementation direction is a small optional companion selector with exact-source cards, strong deterministic ranking, complete-vector validation/fallback, generation/source freshness checks, and an ordinary author/review/test workflow. Keep the current baseline available and avoid uncalibrated source filtering. For evidence budgets large enough to make BM25 reliable, the extra model stage may offer little completion value; for tight budgets or displaced expensive selection, its low recurring price is attractive. Measure new task families, actual repair/escalation/review effort, and acceptance at equal total cost before changing a default. Broader assertion/PR approval, performance prediction, test skipping, and automatic merging remain unsupported by these trials.
