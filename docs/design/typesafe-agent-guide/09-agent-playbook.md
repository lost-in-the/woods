# An agent playbook for another project

This file turns the handbook into an implementation workflow. Adapt the repository conventions and risk level; do not assume Woods is installed or the TypeSafe experiments shipped a product integration. Read [status and evidence](06-trial-ledger.md) before treating an idea as validated.

## First session: understand the host and choose one decision

1. Read the host's agent/contributor rules and current diff. Identify the existing source search, tests, model client, credential pattern, and deployment boundary.
2. State one concrete developer outcome: for example, “select source methods needed for this authorized change,” rather than “find every bug.”
3. Keep decisions already answerable by code in code: exact identifiers, source hashes, numeric comparison, schema checks, test results, path validation, and authorization.
4. Read current TypeSafe documentation for the chosen primitive, API/SDK, state, and closest cookbook. The relevant skill is useful orientation; live docs define current API shapes and model availability.
5. Choose a measurable no-TypeSafe baseline. Existing retrieval, exact lookup, BM25, or the normal reviewer is often more useful than a deliberately weak heuristic.
6. Decide what evidence is allowed to leave the machine. A code index can contain private source and comments even when it contains no business-table rows. Do not include secrets, raw production records, hidden tests, or evaluation labels by accident.

For Woods itself, create a disposable static self-map before broad investigation. For a Rails host, inspect the existing runtime index with `woods_status`; boot and extract the application when runtime facts are required. The two sources answer different questions. See [Woods integration](05-woods-integration.md).

## Implement an offline seam before inference

Create a source-only companion module or script with four replaceable functions:

```text
discover(task, snapshot) -> candidates + completeness diagnostics
prepare(task, candidates, rubric) -> exact request bytes + private sidecar
select(validated answers | operational failure) -> ordered candidate IDs
render(ordered IDs, verified source, budget) -> context + byte-span ledger
```

These are conceptual interfaces, not APIs already present in Woods. Keep the selector independent of extraction, author execution, and patch application. Test invalid inputs and deterministic fallback before sending a real request. A missing capture should never silently trigger a live call.

Use the [examples runbook](examples/README.md) for exact runnable commands. Its synthetic capture validates plumbing only. Passing that test does not establish relevance accuracy, candidate recall, or a production-ready HTTP service. Explicitly review the starter's documented omissions before integrating it.

A useful first artifact set is:

| Artifact | Contents |
| --- | --- |
| Protocol | Task, endpoint, baseline, candidate policy, budgets, failure handling, model/rubric identity |
| Public task | Behavior requested and constraints; no private solution |
| Source ledger | Repository/index identity, physical paths, file hashes, byte ranges, completeness |
| Prepared requests | Exactly the bytes that will be transmitted, plus size totals |
| Private labels/oracles | Kept outside provider and author serializers |
| Capture | Validated answers, request hashes, known usage, status, latency, model |
| Author evidence | Exact rendered context and source-coordinate ledger |
| Result | All intended outcomes, tests run, compatibility notes, costs and unknowns |

A manifest hash proves byte consistency, not that a source is trustworthy, correctly labeled, or historically authentic. If you need source lineage, verify it separately against a pinned repository object and record transformations.

## Run a bounded feasibility test

Choose several task families with realistic negative and missing-context cases. For a repair, prove the regression on an isolated incorrect implementation and its resolution on correct source. For a new feature, prove the API is absent without deleting an existing implementation, then show the reference behavior passes. Test adjacent behavior and at least one plausible wrong implementation so the oracle is not merely a success printer.

Freeze the tasks, oracle, rubric, candidate discovery, budgets, author settings, and comparison rule. Have another reviewer inspect the **actual outgoing state**, not only the plan. Check for reference filenames, comments, outcome labels, and private target paths that disclose the answer. If a generic representation correction is necessary, archive the earlier preparation and revise before inference.

Resolve the credential once for the bounded process and reuse it. Run the primary selection once, persist results, and perform analysis offline. If the purpose includes stability, declare an exact independent repeat and preserve both; do not take the better result. A service failure is an operational result with possibly unknown cost, not an abstaining semantic judgment.

For writing-code evaluation, use a separate author with identical policy and context budget across arms. Record tool access and actual usage. Provide no hidden test feedback before the first submission freezes. Review patches before executing them, apply only exact authorized source replacements, and run behavior plus existing tests in isolated copies. If you allow editing any delivered file, ensure review and supplemental tests cover the files actually touched.

## Interpret the first result correctly

A selector can fail at discovery, input representation, relevance judgment, ranking, packing, source freshness, operational reliability, or downstream authoring. Keep these stages separate. The last actor is not automatically the cause of every failed test.

Ask:

- Was the needed evidence available to the selector? Was it complete and interpretable?
- Did the question ask the proposition the policy later consumed?
- Was the correct candidate ranked poorly, or did packing remove its useful code?
- Did the author obey the evidence contract, and did it preserve unrelated behavior?
- Did the oracle actually exercise the scenario and report its expected positive test counts?
- Does the estimated benefit survive selector, author, cache, retry, escalation, and review costs?
- Which facts are directly observed, which are judgments, and which remain untested?

Do not call an unsupported historical claim contradicted merely because evidence is absent. Do not equate a graph edge with test coverage. Do not infer a performance regression from a plausible source-level concern without a benchmark. Do not replace original primary scores with a posthoc compatibility test; report the new finding separately and improve the next protocol.

## Reusable implementation prompt

Give another agent this brief after choosing a concrete task:

> Read this guide's README, architecture, selection, and evaluation chapters. Inspect this project's current search/index and test workflow. Propose one optional TypeSafe decision stage for **[specific authorized developer outcome]**. Keep deterministic checks and execution outside the model. Define the exact public state, primitive/rubric, candidate coverage diagnostics, no-match behavior, source fingerprint, fallback, and measured quality/cost endpoint. Mark every proposed capability that has not been tested here. Implement the smallest offline seam and meaningful contract tests first, preserving unrelated changes. Then prepare exact bounded live requests for the authorized scope and validate against a fixed baseline. Do not infer approval to upload unrelated private data, execute selected commands, alter normal CI, or introduce runtime dependencies.

## Reusable independent-review prompt

> Review the exact prepared protocol, source cards, outgoing JSON, hidden-label separation, deterministic comparator, and executable oracles. Check that question IDs are not carrying missing semantics, Noul polarity matches policy, independent questions do not secretly depend on answers, and truncation/coverage are disclosed. Confirm that failed/missing calls remain in intended denominators; repeated budgets and authors are not counted as new tasks. Inspect credential lifetime, stale-source behavior, complete-vector fallback, and exact patch guards. Distinguish blockers from useful future improvements. Report concrete edits without retuning anything against test outcomes.

## Reusable findings/report prompt

> Recount raw captures, every planned author outcome, test summaries, and usage. Preserve original scores. Report accepted behavior separately from code-review and posthoc compatibility findings. Compare against every prespecified baseline and show feature/repair strata. Keep provider tokens and dollar estimates separate from actual author billing, cached subsets, and unmetered study work. For an actual baseline bug or test gap, verify current source, reproduce narrowly, check existing issues, and follow the user's authorized issue-reporting workflow. Do not file seeded mutants or generated-patch-only mistakes as production bugs.

## A small production proposal after successful evaluation

If fresh tasks justify integration, ship the companion behind an explicit option with an observable deterministic fallback. Keep source snapshots and score keys versioned, add clear stale/partial indicators, and retain the original retrieval path. Publish a short operational runbook with model/rubric versions, costs, retries, privacy, and rollback.

For a Woods project, do not add or rename public extraction identifiers, graph relationships, generated layout, MCP schemas, configuration, or plugin promises merely to host an experiment. If the proposal really requires a public change, follow Woods' surface inventory, canonical docs, plugin pairing, changelog, and release-task requirements. The successful studies in this guide did not require those changes.

Advance one workflow at a time. Context selection has promising evidence; assertion gates, broad PR verification, benchmark recommendation, learned feature discovery, and autonomous routing require their own validation. Consult [economics](07-cost-and-adoption.md) so a useful low-cost substitution is not rejected merely for producing equally good code.
