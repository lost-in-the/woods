# Economics and an adoption decision

TypeSafe's observed selection cost was very small. Treat that as a material advantage when deciding whether a workflow is useful. Requiring it to outperform a larger coding model on every judgment—or requiring compression in every successful use—would miss inexpensive substitution, better evidence, and avoided follow-up work. Equally, cheap inference cannot compensate for a workflow that loses necessary evidence or creates more repair work.

## Price basis and scope

Calculations in this guide use **$0.042 per million input tokens and free output**, the rate supplied for the investigation and checked against the vendor's [introductory pricing announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev). This is an estimate as of the September 2026 investigation, not an account invoice or a promise of future pricing. Recheck your account and current rates before budgeting a deployment.

```text
TypeSafe estimate = reported input tokens / 1,000,000 × 0.042
```

Output usage still belongs in logs even when its assumed price is zero. A failed request without returned usage has **unknown** usage/cost. Request bytes do not provide a hard spend ceiling; escaping and tokenization differ. A request-count cap limits attempts, not exact charges.

| Measured selection policy | Primary input | Primary estimate | Similar selections per batch | Estimate per 1,000 similar selections |
| --- | ---: | ---: | ---: | ---: |
| Compact implementation-example choice | 6,675 | $0.00028035 | 1 | $0.28035 |
| Canopy relevance reranking | 293,010 | $0.01230642 | 28 | $0.439515 |
| Curated method-context ranking | 49,919 | $0.002096598 | 4 | $0.5241495 |
| Description-discovered top-80 method ranking | 167,660 | $0.00704172 | 4 | $1.76043 |

These are different workloads with different source/question volumes, not a price trend or a normalized model comparison. The larger automatic candidate pool cost more than a curated three-file pool, but remained inexpensive. One selection may require several chunked HTTP calls. The denominator is a task/query selection, not an individual request.

A deployed policy normally pays for the chosen representation and one primary score vector. It does not pay for every experimental comparison arm, diagnostic marker, repeated selector pass, or posthoc study. Reusing a score vector for another context budget is legitimate when the evidence and question meanings are unchanged. Deliberate repeatability testing must bypass that reuse.

## Evaluate the whole recurring workflow

Use a ledger rather than a single model bill:

```text
recurring task cost
  = evidence discovery and construction
  + selector inference
  + downstream context input
  + author output and tool work
  + failed attempts and follow-up repair
  + escalation and review
  + storage/operational maintenance allocation
```

Keep research investment separate: designing the study, labeling cases, writing oracles, freezing snapshots, independent audits, and running comparison arms are not all recurring production expenses. They also do not disappear for free. State a plausible amortization volume if claiming an engineering-investment payback.

For N future tasks and one-time implementation cost H, compare:

```text
new workflow = H + N × measured recurring cost per task
```

Do not invent a monetary value for an agent subscription's marginal tokens or a maintainer's time. Report measured quantities first and show sensitivity to explicitly supplied rates. For an already-paid subscription, saved tokens may mean available capacity or lower latency rather than an immediate cash saving. Ordinary scorer usage was unavailable in several early experiments, so no honest savings ratio against it can be calculated.

## Four useful sources of benefit

**Replace a costly bounded decision.** An ordinary agent may spend a whole turn selecting among known examples or classifying a known incident. If TypeSafe provides acceptable decisions and replaces that turn, the low selector price matters even when the final implementation is identical. Running both selectors forever adds cost; a shadow phase is an evaluation expense, not the intended steady state.

**Improve evidence at the same source budget.** The curated method trial saw four accepted repairs with TypeSafe versus two with lexical selection. The later different BM25 study saw four versus three at 1,000 source tokens. These small task sets justify interest, not a population effect estimate. A single avoided long debugging cycle could dominate the selector bill, but that avoided work must be measured.

**Reduce context while preserving acceptable outcomes.** In the later trial, TypeSafe at 1,000 tokens and BM25 at 3,000 each passed four primary tasks. This motivates a cost-quality comparison across budgets. It does not establish noninferiority from four tasks, and actual provider inputs differ from reference source counts.

**Batch repeated judgments.** The assertion experiment used 64.8% fewer input tokens for the same five questions when batching shared state. This is a direct measured improvement to that request design. It does not show that extra speculative questions are literally free, or that every application should ask every conceivable question.

## Worked comparisons without fictional billing

For the primary TypeSafe-1k versus BM25-3k arms in the final study:

| Counter across four tasks | TypeSafe 1k authors | BM25 3k authors |
| --- | ---: | ---: |
| Input | 41,167 | 49,215 |
| Cached input subset | 21,120 | 21,120 |
| Output | 2,076 | 1,864 |
| Accepted by frozen tests | 4/4 | 4/4 |

Let U be hypothetical dollars per million uncached input and O dollars per million output. Cached counts happen to cancel in this observed comparison. Including the selector, the arithmetic difference is:

```text
TypeSafe minus BM25 = $0.00704172 − 0.008048 × U + 0.000212 × O
```

Negative means lower estimated inference cost under those supplied rates. For purely illustrative U=$5 and O=$15, the expression is approximately **−$0.03002 across four tasks**. This is not the actual CLI charge, a confidence interval, or a validated quality-preserving saving. It excludes preparation, review, maintenance, and escalation. Different cache conditions or author outputs can reverse the difference.

The earlier filtering experiment illustrates the opposite danger. Filtering saved 5,458 reference context tokens, with a primary selector cost of $0.01230642. Ignoring caching and all other costs, selector-only break-even was roughly **$2.25 per million downstream input tokens**. But the policy lost baseline-labeled IDs on twelve queries. Positive arithmetic does not make that evidence loss acceptable.

For pure ranking in that same trial, context grew by 958 reference tokens. The value hypothesis was improved evidence, not compression. Treating that as automatically useless would ignore the inexpensive selector and possible downstream benefit; treating it as already cost-effective would assume an unmeasured benefit.

## Latency and reliability are separate axes

Later successful TypeSafe HTTP attempts had medians around 0.39–0.45 seconds. A task with several serial chunks took longer than one call; the final four-task primary selection summed 13.72 seconds of call timers. The two-pass batch spanned about 57 seconds with integrity checks and persistence. These observations exclude parts of discovery, source construction, reviewer work, authors, tests, and final reporting.

Do not divide an ordinary agent's entire turn time by a TypeSafe HTTP timer and call it model speedup. Concurrency, shared-state batching, caching, connection reuse, and different task definitions all matter. Measure end-to-end p50/p95 for the workflow the developer actually waits for, plus failures and unknown completions. A reliable fallback may be preferable to retrying a slow call with ambiguous billing.

The current examples use a deliberately small synchronous reference adapter. Connection pooling, distributed cache coordination, adaptive concurrency, circuit breaking, hard process deadlines, quotas, and service-level objectives are production decisions to add only when the deployment needs them. The historical no-retry experimental protocol is not a universal ban on bounded backoff for explicit rate-limit responses.

## Choose a low-consequence initial integration

A suitable first project integration is an **optional companion context selector**:

1. Keep the current deterministic search/context path available.
2. Generate exact-source candidate cards automatically and preview what leaves the machine.
3. Run TypeSafe ranking behind an explicit experimental option.
4. Present source and provenance to the normal coding agent; retain code review and executed tests.
5. Log quality, latency, usage, fallback, stale-source rejection, and follow-up work.
6. Remove the selector stage immediately if it fails operationally or its measured benefit disappears.

This adds semantic assistance without making it a source of truth for extraction or permissions. It does not require TypeSafe inside Rails boot, the published Woods format, every MCP request, or normal CI. A project without Woods can use parser/search adapters with the same contracts.

Potentially useful next experiments include exact-lookup-plus-ranking, declaration/helper hydration, graded Score relevance, complementary evidence selection, and bounded read-only diagnostic routing. These are proposals. Broad “is this PR safe?” approvals, test skipping, automatic code execution, performance claims without benchmarks, or autonomous merging do not follow from our results.

## Define advancement before new outcomes

For a cost-quality study, predeclare:

- The actual developer tasks and family/chronological split, with unseen tasks reserved for the final decision.
- The incumbent baseline, candidate access, context budgets, author model/settings, retry/escalation policy, and independent acceptance criteria.
- A quality floor and an acceptable noninferiority margin tied to consequences; choose sample size from the desired uncertainty, not convenience.
- Total recurring-cost categories, applicable rates, treatment of unknown usage, acceptable latency, and reporting of failures.
- How to handle new compatibility defects, ambiguous labels, unavailable infrastructure, and model/rubric/source changes.

The original advisory-review plan proposed at least 30 held-out families per profile, multiple adverse and clean families, family-level resampling, and stringent precision/false-assurance criteria. Those requirements were **not fulfilled** by these development trials and were not a retrospectively passed cost study. Use a prospectively justified criterion for the actual new workflow instead of transplanting a number as a universal standard.

Report every planned condition, including losers and operational failures. Once an evaluation outcome changes a rubric, threshold, candidate policy, or test, that dataset becomes development evidence. Preserve the old result and obtain a fresh test set. The goal is useful accepted work at an acceptable total cost, with uncertainty visible—not a chart that makes one model win.
