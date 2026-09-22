# Code authoring and evaluation

TypeSafe can select evidence for a coding agent. The coding agent still writes the patch, and executable checks still establish whether it meets the task. Evaluate that complete sequence: a good relevance score is useful only if the resulting evidence helps development at an acceptable cost.

This chapter describes a reproducible evaluation method. Experiment-specific author runners and acceptance harnesses were used in the Woods studies; they are not a packaged TypeSafe integration or an automatic CI approval service. See [implemented boundaries](05-woods-integration.md), the [trial ledger](06-trial-ledger.md), and [examples](examples/README.md). Broader adoption criteria below are proposed practice, not a gate already satisfied by these trials.

## Define the endpoint before collecting answers

Write down the intended decision, its reference evidence, and what failure means. Keep these endpoints separate:

| Question | Suitable evidence and endpoint | Insufficient substitute |
| --- | --- | --- |
| Does this assertion require an invariant? | Independently reviewed assertion labels; relevant helpers; a wrong implementation that the assertion rejects | A covered line, a test name, or merely calling the target method |
| Is this claim supported? | The exact scoped claim plus its source, test, or execution evidence | A genuine quote beside an unrelated conclusion |
| Does ranking help source retrieval? | Candidate availability, required evidence delivered, and downstream task results | A target identifier appearing in the context header |
| Can an author repair or implement behavior? | Valid patch application, syntax, independent acceptance, and existing regressions | The author's statement that tests would pass |
| Is a change faster? | A suitable controlled benchmark and measured results | A relevance judgment, plausible complexity narrative, or HTTP latency |

For the recent coding studies, the primary endpoint was:

```text
accepted = valid_source_bound_patch
           AND syntax_passed
           AND independent_acceptance_passed
           AND declared_existing_tests_passed
```

That definition means “accepted by these checks.” It does not mean complete compatibility, minimum patch scope, production readiness, or measured performance. If those matter, define additional endpoints prospectively or report later audits separately.

## Build independent task blocks

Use public briefs that explain required behavior without supplying the private implementation location. A feature can legitimately name its intended public API. Hidden target paths, reference patches, mutation locations, and grader code must not influence discovery queries, ranking, tie breaks, or author prompts.

Group related examples before splitting development and evaluation data. Ten variants of one assertion, or a bug and its fix, belong to the same family. Keeping siblings together prevents an apparently held-out case from repeating the development example. A repeated author draw, larger budget, or extra RSpec invocation does not create another independent task.

Distinguish three task sources:

- **Controlled regression:** deliberately change correct code and establish that the intended behavior breaks. This tests recovery from a known fault; the mutation is not a newly discovered product bug.
- **Additive feature:** start from code that never implemented the requested behavior. A private reference implementation establishes feasibility; ordinary behavior must remain intact.
- **Real defect:** reproduce the failure in untouched repository code. Verify the revision, environment, contract, and relevant issue history before reporting it.

Historical buggy/fixed replay needs an additional check: both revisions must run against the same verified oracle. Merely reading a historical PR or seeing a record that describes an old run is not paired runtime replay. Public historical fixes may also have appeared in model training. The larger historical-replay framework remains deferred; the completed controlled mutations do not substitute for it. [Historical evidence audit](evidence/typesafe-guide-history-audit.md).

## Validate the oracle before inference

Prepare tests independently of the selector and author. An agent-written oracle can still omit important behavior, so give a reviewer the public brief, source contract, and tests before any model outcome exists.

For each task, establish these controls through the actual evaluator:

1. The correct baseline or reference implementation passes the intended behavior and existing tests.
2. The incomplete feature or defective snapshot fails for the intended behavioral reason. A missing dependency, syntax error, or database boot failure is not a valid negative control.
3. A harmless edit that leaves the defect intact still fails. Where warranted, add plausible wrong implementations that exercise distinct requirements.

Choose compatibility cases from the contract: empty and missing inputs, accepted input types, exact versus normalized equality, duplicate identities, order, mutation of caller objects, persistence, exception behavior, and concurrent or cached state. Do not invent hidden requirements the public brief cannot communicate. A payment feature whose result must ignore unsaved refunds and observe newly persisted refunds needs both conditions stated and tested.

Result substitution and implementation mutation answer different questions. Replacing a test's returned value checks whether its assertion rejects that value. Changing the implementation and running the real path checks whether the test detects that implementation fault. Neither proves general test completeness.

An experiment oracle is immutable once inference starts. If a later audit finds a gap, preserve the primary score and add a clearly labeled supplementary result. For future trials, improve the oracle before freezing fresh tasks.

## Freeze the complete chain of evidence

Use two checkpoints: one before selection, another after contexts are assembled but before authors launch. The source-selection method in [chapter 03](03-evidence-selection.md) should produce exact cards and reproducible packing.

| Record | Model-visible content | Private audit content |
| --- | --- | --- |
| Task | Description and generic permitted source root | Task family, hidden tests, reference patch, mutation labels |
| Candidate | Identity, path, source bytes, relevant scope and range | Original file digest, provenance, diagnostics |
| Selection | Frozen task and candidate state | Request bytes/hash, complete responses, usage and failures |
| Author input | Selected exact source and public task | Policy name, selection scores, private targets, oracle outcomes |
| Evaluation | No feedback during a one-attempt trial | Original tree manifest, patch hash, execution logs, expected counts |

Bind the algorithms and dependencies too: tokenizer, parser version, prompt, question meanings, ranking ties, packing rule, schema, expected model policy, author configuration, source snapshots, indexes, and evaluator helpers. A Docker wrapper's helper is part of the evaluator even when it lives in another directory. A request hash alone does not establish source lineage or correct labels.

Freeze deterministic baseline contexts before TypeSafe results, then assert they remain unchanged. This catches accidental comparator drift. Preserve superseded preparation artifacts when a generic representation defect is corrected before inference; state the correction and zero-outcome status explicitly.

## Require exact same-file source evidence

For a closed-evidence trial, store original byte intervals separately from rendered context. A minimal conceptual ledger entry is:

```json
{
  "file_path": "lib/example.rb",
  "start_byte": 120,
  "end_byte": 136,
  "source_text": "def answer\n  42\n",
  "complete": false
}
```

The example contains 16 source bytes and intentionally omits the method's closing line; it illustrates the fields rather than supplying a complete fixture. Validate actual UTF-8 source bytes, not character counts or reformatted snippets. For every ledger entry, verify that the original file slice equals the delivered source text and that this text was rendered to the author. Record the whole-file digest and the exact snapshot. A truncated method is partial evidence even if its header shows the original full range.

For an exact-replacement patch, the later Woods harness enforced:

```text
old_bytes must occur exactly once in the untouched target file
old_start ... old_end must lie inside a delivered span of that SAME file
path must be a delivered existing file inside the generic permitted source root
replacement intervals must not overlap
```

Apply all replacements against original offsets in descending order. Otherwise an early replacement can move the target of a later one. Permit an empty replacement value for deletion; reject an empty old value, ambiguous matches, path escapes, and changed source digests. A literal occurring in some other file's displayed source is not sufficient evidence.

This strict evidence rule is an evaluation constraint, not a universal coding workflow. An unrestricted development agent may fetch more source or create new files. If you allow that, define a separate experiment and include tool use, retrieval, and extra author work in its budget. Do not repair an invalid closed-evidence submission using knowledge unavailable to its author.

## Contain authors and isolate execution

Give each controlled attempt a fresh session and opaque working directory, the same configuration, and one declared opportunity to respond. Disable browsing, shell, MCP, plugins, memory, and delegation when testing source-only authorship. Strip inherited credentials from author/test environments and keep hidden tests outside the author context. Inspect event streams for prohibited tool activity rather than relying on the prompt alone.

These controls reduce contamination; they do not prove host files are physically inaccessible or all shared system instructions disappear. A configuration hash records the configured model, not an independently attested backend identity. Stronger isolation requires a separately engineered sandbox. See [operations and trust boundaries](02-architecture-and-operations.md).

Review submitted code for execution hazards and evaluator bypass before running it. Ordinary wrong fixes should reach the test lane; rejecting them by intuition would improve the apparent score unfairly. Preserve exact submitted bytes, and never silently fix syntax, an old-text match, or formatting after the attempt.

Run eligible patches in fresh verified copies. Rails tests need their own app copy and database; use ordinary booted extraction where runtime behavior matters. Validate syntax, independent acceptance, and existing suites separately. Record commands, exit status, timeout, stdout/stderr, expected positive example counts, failures, and pending examples. An empty suite or process exit zero alone cannot pass. Test results claimed in generated prose are not execution evidence.

Choose existing tests for the complete edited scope. In the four-test study, three literal-search authors also edited SearchExecutor. The frozen metadata-store lane did not cover that file; a separate posthoc retrieval/ranker run was required. Production integration should follow the repository's broader test policy rather than treating an experimental acceptance lane as sufficient. [Four-test results](evidence/2026-09-16-typesafe-four-tests-evaluation.md).

## Compare policies without changing the question

Use the same candidates, author task, source budget, packing, and execution checks for paired ranking comparisons. To compare budgets, reuse one primary score vector. To measure selector variability, repeat identical request bytes separately. To measure author variability, repeat identical original prompts for both the deterministic and TypeSafe policies; do not replace a primary context with a more favorable selector repeat.

Keep every intended case in the denominator. Record abstention, invalid patch, tool use, timeout, missing usage, syntax failure, behavioral failure, and rejected execution hazards separately. A pipeline that escalates everything may avoid false acceptance while providing no useful decisions. Report retained useful work and review burden, not just precision among the few cases that survived.

Measure actual author usage, including failed attempts. Cached input and reasoning output may be subsets of larger counters; do not add them twice. Keep selector and author tokens separate. At $0.042 per million input tokens with free output, source selection can be worthwhile without reducing context size, but total value still depends on authoring, review, escalation, and latency. Subscription billing cannot be inferred from token counters alone. [Cost and adoption](07-cost-and-adoption.md).

## Advance narrowly

The completed studies support further optional evidence selection. They do not support automatic PR approval, skipping tests, broad correctness certification, or performance prediction. A proposed progression is: validate offline mechanics; run reviewed development tasks; freeze policies; evaluate fresh task families against strong deterministic controls; then try an advisory companion workflow with observable fallback and ordinary review. Any later default or CI gate needs its own evidence and explicit implementation.

Use the [agent playbook](09-agent-playbook.md) for the execution sequence and [diagnostics](08-pitfalls-and-diagnostics.md) when a result surprises you. Do not turn a successful small study into a broader claim than its endpoint measured.
