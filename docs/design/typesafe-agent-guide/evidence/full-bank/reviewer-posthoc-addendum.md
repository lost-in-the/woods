# Posthoc stale-input confirmation and correction-session telemetry

The initial adjudications remain unchanged. A separate, zero-inference Rails probe now confirms a narrow additional mechanism in `f9a470ec`: overlapping wallet instances loaded before the first transfer commits can overwrite persisted balances despite the enclosing transaction.

Two stale destination snapshots lose 10 credits (total 200 → 190); two stale source snapshots create 10 credits (100 → 110). Fresh finds before each sequential transfer preserve both expected balances and totals. These are deterministic admissible read/commit orderings on Rails 8.0.5.1, Ruby 3.3.1, SQLite—not simultaneous-thread testing or evidence that a live caller permits this input lifecycle. The fresh-load comparison does not establish a concurrency fix.

The probe source and service/model/schema digests match the recorded candidate commit. The original database digest and worktree remain unchanged. Its original validation-failure atomicity oracle still passes and keeps its label. Record bank-1 as **seven planted findings plus one posthoc conditionally confirmed additional mechanism**, without retroactively modifying planted-target metrics.

## First emitted finding later confirmed

Times are launcher-elapsed seconds to an emitted finding that was independently confirmed later. They are not timestamps of live verification or per-finding token costs.

| Run | First planted | First including posthoc conditional finding | Session seconds |
| --- | ---: | ---: | ---: |
| bank-0 | 15.36 | 15.36 | 68.49 |
| bank-1 | 23.87 | 17.11 | 99.60 |
| baseline-0 | 16.17 | 16.17 | 80.87 |
| baseline-1 | 19.33 | 19.33 | 91.78 |
| ordinary-0 | 16.60 | 16.60 | 91.14 |
| ordinary-1 | 17.79 | 17.79 | 84.03 |

Bank-1 emits the later-confirmed stale-input finding at **17.11 seconds**; its first planted finding appears at **23.87 seconds**. Retain both endpoints. This isolated additional lead does not establish a causal bank advantage.

## Reviewer usage across each arm’s two correction sessions

| Arm | Input | Cached input included above | Noncached input | Output | Input + output |
| --- | ---: | ---: | ---: | ---: | ---: |
| ordinary | 849,672 | 715,648 | 134,024 | 5,909 | 855,581 |
| baseline | 754,640 | 593,280 | 161,360 | 6,319 | 760,959 |
| bank | 905,285 | 739,840 | 165,445 | 6,032 | 911,317 |

Across these six sessions: **2,509,597 input tokens**, including **2,048,768 cached input tokens**, and **18,260 output tokens**. Input plus output is **2,527,857 tokens**; cached tokens must not be added again. Completed-turn usage cannot establish tokens consumed before the first finding. No model-price, invoice, or cache-savings claim is inferred.

All 46 helper outputs match expected raw event bytes, but bank-1 still reported client-side truncation. The correction sessions remain separate from the original pilot. Probe and adjudication setup labor was not measured; the isolated probe execution time is retained in JSON. No new inference was used.

Relative source/receipt paths, hashes, exact runtime results, first-emission IDs and raw usage counters are recorded in `reviewer-posthoc-addendum.json`.
