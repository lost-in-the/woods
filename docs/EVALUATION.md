# Evaluating Woods

Three harnesses, three questions.

| Task | Question it answers | Command |
|---|---|---|
| Retrieval evaluation | Does `codebase_retrieve` return the right units for a query? | `bin/rails woods:evaluate` |
| Baseline comparison | How does a naive strategy score on the same queries? | `bin/rails "woods:evaluate:baseline[grep]"` |
| Agent-level ablation | Does an agent resolve real tasks better, or cheaper, with the index on? | `bin/rails "woods:evaluate:ablation[config/eval_ablation.json]"` |

## Retrieval evaluation

`woods:evaluate` runs a ground-truth query set (`config/eval_queries.json`, `EVAL_QUERY_SET`) through the retrieval pipeline and reports precision at 5 and 10, recall, MRR, context completeness, and token efficiency. `EVAL_BASELINE_FILE` (a versioned thresholds file, see `Woods::Evaluation::Baseline`) turns it into a gate; `EVAL_MIN_PRECISION`, `EVAL_MIN_RECALL`, and `EVAL_MIN_MRR` override single thresholds. It needs an embedded index; set `embedding_provider = :fake` for an offline run. Output: `tmp/eval_report.json` (`EVAL_OUTPUT`).

`woods:evaluate:baseline[grep|random|file_level]` scores a naive strategy on the same query set for comparison.

## Paired lexical comparison (#404 / #227)

`bench/evaluation/lexical_comparison.rb` runs **all 28 existing questions at their
existing budgets** through semantic retrieval, lexical-only retrieval, a fixed
query-seeded graph experiment, and the existing identifier-substring grep baseline.
Unlike the strategy groups below, these conditions answer the same questions.
The semantic condition replays the same captured real MiniLM vectors; labels,
source snapshot and the original quality floors are unchanged.

```bash
bundle exec ruby -Ilib bench/evaluation/lexical_comparison.rb /tmp/woods-paired.json
# Use the pinned tokenizer environment described below:
python bench/evaluation/capture_tokens.py /tmp/woods-paired.json lexical_comparison_capture.json
```

The second command writes `bench/evaluation/lexical_comparison_capture.json`.
It retains every query's outcomes, context hash and exact token count, including
misses. Raw returned contexts remain in `/tmp/woods-paired.json`. The capture binds
its corpus/vector hashes and tokenizer provenance. It is reviewed experimental
evidence, not a replacement for the required semantic gate.

Initial Ruby 4.0.6 comparison (five warm pipeline repetitions per question):

| Condition | Precision@5 | Recall | MRR | Mean actual context tokens | Median query latency (ms) |
|---|---:|---:|---:|---:|---:|
| Existing semantic pipeline | 0.536 | 0.580 | 0.857 | 1,000.7 | 2.908 |
| Explicit lexical | 0.462 | 0.720 | 0.789 | 1,143.9 | 0.386 |
| Lexical + query-seeded graph experiment | 0.414 | 0.492 | 0.750 | 1,152.8 | 3.132 |
| Existing identifier grep baseline | 0.342 | 0.288 | 0.336 | 593.6 | 0.598 |

Lexical retrieval improves recall on this small set while losing precision and
first-hit rank against the semantic pipeline. This supports an explicit offline
option, not semantic equivalence or a new default. The seeded graph condition
loses on these measures and stays **evaluation-only**. It uses 20 iterations,
restart probability 0.15, normalized positive lexical seeds, bidirectional
recorded relationships within type eligibility, and no seeds for a no-match
query. These choices were fixed before scoring; no weights were tuned to labels.
The grep baseline matches identifiers, not source text; it retains its existing
ordering, with eligibility applied before its limit and the same budgeted renderer.

Latencies are warm in-process measurements over 62 units. They exclude lexical
snapshot construction, live embedding/network latency and Rails extraction; they
are not host-scale performance claims. Exact tokens count returned context only,
using the existing `cl100k_base` capture machinery. Agent task outcomes were not
measured. Ambiguous typed identities, concern/callback metadata and unrelated-hub
controls also have targeted regressions; those synthetic controls do not replace
representative host evaluation. Broader production/provider/agent evidence remains
open under #227.

## Checked-in Canopy retrieval gate

The required CI `coverage` job runs this offline command before its test suite:

```bash
bundle exec ruby -Ilib bench/evaluation/runner.rb
# Report: tmp/retrieval-evaluation.json (uploaded by CI)
```

`bench/evaluation/` contains a versioned, deliberately small baseline:

- **Corpus:** 62 runtime-extracted Canopy units and 28 annotated queries covering
  publishing, billing, newsletters, and support. Source and relationships come
  from the committed fictional `woods-testbed` Rails application; no application
  records are included. Exact application/Woods revisions are in `corpus.json`.
  This snapshot selects models, services, jobs, controllers, Pundit policies, and
  mailers; it does not represent every extractor or a large production index.
- **Embeddings:** real `all-MiniLM-L6-v2` ONNX inference, captured with a pinned
  model revision and file hashes. CI replays those vectors through the current
  production classifier, stores, graph, ranker, type fallback, and assembler.
  No hash-based fake embeddings or expected-answer vectors are used.
- **Gate:** per-strategy precision at 5, recall, and MRR must remain at least 95%
  of the first observed score (floors rounded down to six decimal places).
  Corpus/vector/token-provenance mismatches, missing strategies, and unexpected
  strategy selection also fail. The baseline format is developer-only and is
  **not** the `EVAL_BASELINE_FILE` aggregate-threshold format.

B-190/B-191 recapture on Ruby 4.0.6 (five warmed pipeline repetitions per query; Ruby 3.3.1
and 3.4.10 replay the same answers):

| Strategy | Queries | Precision@5 | Recall | MRR | Mean actual context tokens |
|---|---:|---:|---:|---:|---:|
| Keyword | 4 | 0.292 | 0.500 | 0.750 | 1,020.8 |
| Vector | 4 | 0.313 | 0.375 | 0.625 | 1,041.2 |
| Graph | 8 | 0.813 | 0.519 | 1.000 | 1,041.1 |
| Hybrid | 4 | 0.750 | 0.396 | 1.000 | 1,058.8 |
| Direct with type filtering | 4 | 0.375 | 0.750 | 0.625 | 551.0 |
| Within-type vector fallback | 4 | 0.400 | 1.000 | 1.000 | 1,250.8 |

Precision@5 divides relevant hits by the actual returned slice size (up to five),
not always by five. Recall divides retrieved relevant units by all annotated
relevant units. MRR is the mean reciprocal rank of the first relevant hit; a
query with no relevant hit contributes zero.

`profiles.json` binds six measured Ruby runtimes to a shared context capture:
Ruby 3.0.7, 3.1.7, 3.2.11, 3.3.1, 3.4.10, and 4.0.6. Other Ruby engines or
major/minor versions fail with a recapture instruction. All six produce identical
retrieved identifiers, context bytes, token counts and quality metrics for every
query. The original positive per-runtime quality floors remain unchanged in
`baseline.json` and `baseline_legacy.json`.

B-191 orders equal PageRank scores lexically by identifier. B-192 orders hybrid
candidates by descending score, identifier, then source before truncation and
RRF; the same ordering selects the three vector seeds for graph expansion.
Only `hybrid-2` changes from the prior Ruby 3.3–4.0 capture: `Newsletter::DeliverJob`
now precedes `Newsletter::Delivery`, matching the prior Ruby 3.0–3.2 answer.
No quality metric or exact token count changes. This is production retrieval
ordering, with no answer reordering in the evaluation harness.

These are separate annotated query groups, **not a controlled comparison of six
strategies on identical questions**. Relevance annotations were written from
fixture source and its functional contract before scoring. Initial graph and
direct probes remain in the corpus; additional probes exercise the supported
snake-case graph roots and actual within-type fallback. The B-190 fix now
resolves all four originally empty graph queries, including `trace Billing::Invoice`
and `trace ReviewAssignment`. The B-190 change affected those four graph answers. B-191 additionally
changes vector and within-type fallback ranks or membership; all original queries,
relevance labels, vectors, and quality floors remain unchanged. Graph precision/recall/MRR increased from 0.417 / 0.238 / 0.500 to
0.813 / 0.519 / 1.000. Low semantic recall and editorial misses are
also retained. The floors prevent further regression; they are not release
quality targets or evidence that retrieval is already good enough.

`capture_report.json` records per-query ranks, quality, latency ranges, and exact
`cl100k_base` counts of the returned context. Those counts are bound to context
SHA-256 values; the tokenizer vocabulary asset hash, pattern, special-token map,
and package version are recorded alongside them. Changed context requires explicit recapture and review. Woods'
`tokens_used` remains a separate character-ratio estimate. Neither number counts
agent prompts, generated answers, or total agent usage. Vector capture records
actual model-input token counts (including special tokens after truncation),
separately from output-context tokens. The model truncates inputs to 512 tokens,
so long source units are only partially represented.

Pipeline latency excludes model loading, downloads, live embedding requests, and
network time. `vectors.json` separately records the warm embedding batch time,
input counts, model/package provenance, and SHA-256 of each model asset. Timing
is observational and has no shared-runner CI threshold. This baseline does not
validate OpenAI/Ollama quality, their latency, production-scale storage, or agent
outcomes; #227 remains open for broader representative-provider evidence.

### Reproduce or review a new capture

Ordinary CI needs only the Ruby bundle and the checked-in files. Model refresh is
an explicit maintenance operation with isolated Python dependencies:

```bash
uv venv /tmp/woods-eval-venv
uv pip install --python /tmp/woods-eval-venv/bin/python -r bench/evaluation/requirements.txt
/tmp/woods-eval-venv/bin/python bench/evaluation/capture.py /tmp/woods-eval-model
```

This overwrites `vectors.json` with real inference from the pinned Apache-2.0
model. To capture changed context after an intentional pipeline change:

```bash
bundle exec ruby -Ilib -r./bench/evaluation/runner -e \
  'r=RetrievalBaseline::Runner.new; File.write("/tmp/retrieval-capture.json", JSON.pretty_generate(r.run))'
/tmp/woods-eval-venv/bin/python bench/evaluation/capture_tokens.py /tmp/retrieval-capture.json
```

Replay all six measured Ruby lines before replacing the shared capture. Retain
the exact capture runtime in the report and preserve each runtime’s original
quality floors. A newly observed runtime difference needs separate reviewed
captures rather than being hidden by answer reordering.

Review every changed answer and score before updating the matching baseline digests or
floors. Never lower a floor merely to make CI pass. Keep labels independent of
rankings and preserve hard or failed queries. When changing the application
snapshot, use a fresh runtime `woods:extract` into a disposable output directory,
retain only deliberate source/relationship fields, and record both repository
SHAs. Do not copy a host's live index or application records into the repository.

## Agent-level ablation

Retrieval scores say whether the right units come back. They do not say whether an agent finishes the job. The ablation runs the same task set twice per task, once with the Woods MCP server available and once without, and compares resolution rate, tokens, cost, and turns.

**This is a harness for collecting paired on/off runs, not a source of causal evidence.** Sample size, task selection, and agent nondeterminism all bear on what a result means. Treat it as one input, alongside the retrieval evaluation and manual review, not as a controlled experiment on its own. It is the on/off comparison "Code Isn't Memory" (arXiv 2606.22417, June 2026) reported, where gains concentrated in multi-file changes.

### Disposable checkouts

Every trial (one task, one condition) runs in its own disposable `git worktree` checkout, created from a single baseline SHA resolved once at the start of the run (the current `HEAD` of the application repository), never in the caller's own working directory:

1. `git worktree add --detach <tmp-checkout> <baseline-sha>`
2. the task set's optional `reset` command, inside the checkout
3. the agent command, inside the checkout
4. the task's `check` command, inside the checkout
5. `git worktree remove --force <tmp-checkout>`

Both conditions for a task start from the identical commit, so a difference between them is not confounded by one trial running against a dirtier tree than the other. A `reset` failure aborts the trial and is counted as an error; it is never silently ignored. The checkout is removed whether the trial succeeded, failed, or timed out.

### Provenance

Every result carries the agent command that ran, the model the agent's JSON payload reported (when present), the MCP wiring in effect (`--mcp-config <path>` or `--strict-mcp-config`), the Woods generation number found in the checkout's `tmp/woods/generation.json` (when present), and the baseline SHA the checkout came from. Compare results only across runs sharing the same baseline SHA and Woods generation.

### Woods availability preflight

Before a trial runs, the harness checks that Woods is actually available or actually absent, distinguishing "MCP enabled" (the agent command is wired to reach the Woods MCP server) from "index present" (an index exists on disk in the checkout):

- `on` requires both: an `--mcp-config` reference in the agent command, and a materialized index in the checkout.
- `off` requires confirmation that MCP is truly unreachable: `--strict-mcp-config` present, and no `--mcp-config` reference at all. Both flags together still fail, since `--mcp-config` wires the agent to Woods regardless of strict mode.

A failed check aborts the trial and is counted as an error, the same as a reset failure. The default probe is injectable (`woods_probe:` on `AblationRunner.new`) for a host app with a different wiring convention.

### Task set

```json
{
  "schema_version": 1,
  "agent_on":  "claude -p {prompt} --output-format json --mcp-config .mcp.json",
  "agent_off": "claude -p {prompt} --output-format json --strict-mcp-config",
  "reset": "git checkout -- . && git clean -fdq",
  "tasks": [
    { "id": "comment-count", "prompt": "Add a comments_count counter cache to Post.", "check": "bin/rspec spec/models/post_spec.rb" }
  ]
}
```

| Field | Meaning |
|---|---|
| `agent_on`, `agent_off` | Shell command templates; `{prompt}` is replaced with the shell-escaped prompt. The agent must print one JSON object on stdout in the `claude -p --output-format json` shape (`usage`, `total_cost_usd`, `num_turns`, `duration_ms`, optionally `model`). `EVAL_AGENT_ON` and `EVAL_AGENT_OFF` override them. |
| `reset` | Optional command run inside each trial's disposable checkout before the agent runs, so both conditions start from the same tree |
| `tasks[].check` | Command whose exit status decides resolution (a spec file, a script, `bin/rails test`) |
| `tasks[].workdir` | Relative to the checkout root; default `.` |

`spec/fixtures/evaluation_ablation_tasks.example.json` is a format fixture only.

### Running it

```bash
bin/rails woods:extract                                     # index the tree under test
bin/rails "woods:evaluate:ablation[config/eval_ablation.json]"
# EVAL_ABLATION_OUTPUT=tmp/eval_ablation.json
```

`woods:evaluate:ablation` never boots Rails: it shells out to the agent command and the task set's own `check` commands, and never touches `Rails.application`.

The report holds every attempt (`task_id`, `condition`, `resolved`, `total_tokens`, `cost_usd`, `turns`, `duration_ms`, `error`, `provenance`) and a summary per condition (`resolution_rate`, `mean_tokens`, `mean_cost_usd`, `mean_turns`, `tasks`, `errors`) plus a `delta` (on minus off, present only when both conditions ran). Tokens are the sum of input, output, cache-creation, and cache-read tokens. `mean_tokens` is `null` when every trial in that condition errored before the agent produced JSON.

A timeout (`AblationRunner.new(..., timeout: seconds)`, default 600) bounds every command a trial runs, applied independently to each one rather than as a single budget shared across the trial: worktree add/remove, the optional `reset`, the agent invocation, and the check. A timed-out `reset` or `check` counts as an error the same way a timed-out agent invocation does. When the default subprocess executor is in use, a timed-out command is terminated (`TERM`, then `KILL` if still alive after a short grace period) so it never outlives the trial that started it.

### Where to get tasks

The Rails Foundation's "Agents on Rails" benchmark (announced 2026-08-13, built by Evil Martians) is a ready-made task set once its tasks and checks are checked into a host app. Any set of tasks with a deterministic `check` works.

### Reading the numbers

A negative `delta.mean_tokens` with an equal or higher `delta.resolution_rate` is the result that sells the index, on the tasks actually run. It does not, by itself, establish that the index causes the difference: run at least ten tasks, two conditions on five tasks is noise, and remember that agent runs are not perfectly reproducible even at a fixed baseline SHA. Keep the baseline SHA and Woods generation fixed across a comparison (both are recorded per result), and do not let the `on` agent run `woods:extract` mid-task.
