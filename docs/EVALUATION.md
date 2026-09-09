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
- `off` requires confirmation that MCP is truly unreachable: `--strict-mcp-config`, or no `--mcp-config` reference at all.

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

A per-trial timeout (`AblationRunner.new(..., timeout: seconds)`, default 600) aborts a hung agent invocation and counts it as an error rather than blocking the run indefinitely.

### Where to get tasks

The Rails Foundation's "Agents on Rails" benchmark (announced 2026-08-13, built by Evil Martians) is a ready-made task set once its tasks and checks are checked into a host app. Any set of tasks with a deterministic `check` works.

### Reading the numbers

A negative `delta.mean_tokens` with an equal or higher `delta.resolution_rate` is the result that sells the index, on the tasks actually run. It does not, by itself, establish that the index causes the difference: run at least ten tasks, two conditions on five tasks is noise, and remember that agent runs are not perfectly reproducible even at a fixed baseline SHA. Keep the baseline SHA and Woods generation fixed across a comparison (both are recorded per result), and do not let the `on` agent run `woods:extract` mid-task.
