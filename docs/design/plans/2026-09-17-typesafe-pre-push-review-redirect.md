# Replacement assignment: build a useful TypeSafe-assisted pre-push reviewer

This replaces the direction of the earlier ranking, retrospective PR, and plan-time prediction assignments. Read `PLAN_TIME_RESULT.md` as the latest supplied report; `RANKING-RESULT-AND-RAILS-PACKET.md` is older context with substantial work since it. Preserve completed artifacts and reuse working code. Do not restart completed experiments.

## The user's actual objective

**Help a coding agent find meaningful mistakes in new code before the user pushes it.**

The original request to find issues caught during code review was guidance about **which mistakes to look for**. Historical reviews can suggest failure modes and examples. Predicting which old PRs receive particular comments was never the product objective or the required evaluation method.

Stop expanding the retrospective PR corpus, relabeling review comments, analyzing PR-size correlations, or calculating how many historical reviewer catches are needed. Those activities are no longer the next step. Close that branch of research with its existing results and limitations in a short note.

Build and exercise a local reviewer on actual code changes. Judge it by whether it surfaces a supported defect mechanism, makes a useful test suggestion, or saves review work while retaining acceptable defect detection. A PR-level average of five situation scores does not measure that behavior. Its disappointing result does not establish that TypeSafe cannot help with code review.

Do not assume the opposite either. Demonstrate a useful capability, or report a specific failure of the tested design with enough evidence to identify what failed.

## What to build now

Provide one **opt-in, advisory pre-push review command**. Extend the existing implementation where practical. It should accept an explicit base/head change range, prepare evidence, run focused TypeSafe judgments, and produce a short actionable report plus a reproducible local JSON ledger. Use explicit snapshot/working-tree mode if the existing tool cannot yet review committed ranges; do not describe a working-tree-only command as reviewing all outgoing commits.

The first command need not install a Git hook, change CI, submit reviews, or block a push. Do not open, comment on, close, or otherwise modify GitHub issues or reviews. Do not push anything. Existing authorization for local implementation, tests and bounded TypeSafe experiments stands; use the already authorized credential mechanism.

The first user-visible result should answer:

> “Here is the changed behavior that may fail, the concrete input or operation sequence that triggers it, the code supporting that concern, and how to check it.”

A risk score, a list of broad questions, a high-degree model, or a list of unmentioned class names is not yet that result.

### 1. Prepare evidence about the actual change

- Record the explicit comparison base/head or snapshot identities, dirty-state fingerprint when applicable, and exact bytes/digests. Retain before/after code and the patch. Treat renames, additions, deletions and test-only changes explicitly. Use NUL-safe Git path enumeration.
- Include the changed definition and relevant surrounding contracts, callers, callbacks, associations, scopes and tests. Use Woods to locate/support that context where it is reliable. Keep physical source separate from extracted source that inlines concerns or generated context.
- Start with complete small definitions or files and complete relevant test examples, including available hooks/helpers. Never repeat the assertion-dropping compaction from stock Jev Review. Record unresolved support and omitted bytes. Missing selected tests are not proof of missing coverage.
- Bound the **serialized provider request**, not just lines or characters in a file. Split work along meaningful review units when necessary; if the needed evidence will not fit, request more context or mark that check incomplete rather than silently cutting its premise or assertion.

Use current, isolated fixtures if authentic historical snapshots are unavailable. There is no requirement to reconstruct past PRs to demonstrate a pre-push reviewer.

### 2. Make TypeSafe perform a concrete semantic review task

Start with a few narrow checks tied to the changed code and its visible contract. For example:

- Can the shown operation be retried or invoked twice and create a duplicate persistent effect contrary to the stated contract?
- Can the shown scope/query admit another owner or tenant after this change?
- Can a rollback or failed save leave the shown external effect inconsistent with the database?
- Can an update or alternate operation order leave the shown cached/derived state stale?

These are review directions, not fixed universal prompts. State the actual operation, relevant contract, and necessary conditions in the evidence. Include valid behavior and unsupported-context outcomes. Do not ask whether a PR “seems risky” or whether some problem might exist somewhere in the application.

Jev supplies typed judgments rather than free-form review explanations. Use Noul for a specific supported yes/no proposition, Choice when selecting among concrete alternatives/evidence/mechanisms, and Score only where a defined degree or priority is genuinely needed. Code owns interpretation and policy. A Noul is not a severity measurement, and low probability is not proof that the whole change is safe. [Noul contract](https://docs.typesafe.ai/primitives/noul), [confidence guidance](https://docs.typesafe.ai/confidence).

Give each question its own complete meaning and relevant state. Independent checks over the same evidence may share a request; they do not see one another's answers. If a later judgment needs selected evidence or a newly obtained fact, construct that state in a later step. Read the current SDK/API contract before changing request code.

The preferred first path is **direct checks of concrete code behavior**. If candidate generation is the obstacle, a reasoning agent may formulate a bounded set of plausible hypotheses for Jev to assess. Record that work and its cost. Demonstrate what Jev contributes; do not have the reasoning agent find and confirm every bug and then claim that Jev discovered them by attaching scores.

### 3. Turn suspicions into inspectable findings

Retain relevant tests and contracts through follow-up stages. Evidence selection must permit no supported location/mechanism, and missing evidence must remain distinguishable from an assessed absence of a concern.

Use a reasoning agent or developer to explain and verify the promising mechanisms. Prefer an isolated executable counterexample, regression test, or mutation check when feasible. TypeSafe's typed output or a high probability alone does not verify a bug. Do not execute reviewed source merely to render a report.

A useful finding records:

- changed path and exact source/evidence identity;
- the input, precondition or operation sequence;
- the required behavior and the suspected deviation;
- supporting code and test references;
- a concrete verification step and its result, if run;
- status such as suspected, reproduced, unsupported, or insufficient evidence.

If the explanation is generated by another model, label it as that model's interpretation and check its references. Deterministic templates must not invent a causal story from a bare score.

Avoid the stock cascade's unvalidated sequence of discard gates. Initially keep all judgments and inspect which checks support useful findings. Bound the displayed investigation queue, but record what the cap leaves unreviewed. Do not average unrelated probabilities into a “safe to push” number, and do not equate a quiet report with safety.

## A bounded build-and-test assignment

Do this before proposing another research campaign:

1. **Make the command run end to end.** Freeze one small real or controlled code change and inspect the complete outgoing evidence. Verify that the source, assertions and relevant contract survive every stage. If a usable reviewer already exists, demonstrate and repair it instead of replacing it.
2. **Create four small defect/fix pairs** spanning the most relevant review mistakes. Use executable, independently checked behavior as the oracle. Woods and its Rails testbed are available sources of controlled cases. Prefer state/sequence, isolation, lifecycle and stale-state mistakes over syntax errors a linter already finds. Existing completed fixtures can be reused as development cases; label that reuse honestly.
3. **Add two incomplete-evidence cases.** These test abstention/context handling, not whether the missing code contains a defect. Keep oracle labels, mutation names and expected outcomes out of model requests.
4. **Run a frozen first comparison.** Give an ordinary reasoning reviewer and the TypeSafe-assisted workflow the same admissible evidence and a declared comparable investigation budget. Use separate reviewer runs to avoid answer sharing. Preserve standalone Jev judgments as well, so its semantic contribution is visible. Count candidate-generation and confirmation work in the assisted workflow.
5. **Diagnose misses locally.** For a representative miss, compare the exact complete minimal evidence with the naturally assembled packet. Inspect the proposition/options, polarity, selected span, missing support and any queue/gating decision. This separates input or orchestration failure from a model judgment error. Change one substantive element at a time and record it. Do not tune until every visible development case passes and call that validation.
6. **Check a few untouched changes.** After fixing the first implementation, freeze two to four additional defect/fix pairs or suitable fresh changes before scoring. Then show a representative local pre-push report. Fresh natural changes without a confirmed oracle can show usability, but cannot establish missed-defect rates. Do not hold the prototype hostage to collecting 30–40 historic PR catches.

The initial target is **a reproducible useful capability**, not a statistically conclusive production claim. Report which known defects were surfaced, which were missed, false alarms on valid counterparts, incomplete-context handling, and whether the report identifies the actual failure mechanism. A selected target file is not a detected defect; a generic warning is not a confirmed finding.

Measure total review effort and cost as well as output quality: TypeSafe input usage, other-model work, attempts/retries, confirmation/test work, latency, and reviewer attention. At the stated **$0.042 per million input tokens with free output**, ten million input tokens cost about **$0.42**. The initial bounded comparison should normally need far less. Use ten million as a planning allowance for this initial pilot, record actual usage, and account for uncertain failed-call usage; it is not a provider context limit or an invoice guarantee. Additional narrow diagnostics within the existing experiment authorization are reasonable when tied to a specific observed failure. Avoid an open-ended prompt sweep.

Retrieve the credential once per batch, keep it in process memory, and preserve reusable captures. Keep requested and returned model identities, full request hashes and retry accounting. `jev-latest` is an alias, not an immutable model pin. Use explicit repeats only where they answer a concrete stability question.

## Woods facts that matter to this implementation

**Callback extraction must come from the corrected producer.** Woods [#401](https://github.com/lost-in-the/woods/pull/401), commit `87b7c66159c231e40f1f8589875790f7b94859f6`, fixes model callback extraction through Rails event chains. Earlier extraction could silently omit callbacks. The old and fixed revisions both identify as `2.0.0.beta2`, so the version string alone does not prove the fix was used. Before a callback-dependent trial, use a matching source snapshot and a full extraction with a producer containing that fix, writing a separate index. Record its exact revision and generation/artifact hashes. Upgrading an MCP reader or exporting old metadata does not repair it. An empty side-effect list still does not prove absence of effects after the fix.

**Graph relationships are evidence with specific meanings.** The serialized `reverse` adjacency is identifier-only, but typed forward edges retain `via`. Native `DependencyGraph.from_h` rebuilds relationship-filtered reverse lookup; `dependents_of(identifier, via:)` is already available. A Python adapter may build the equivalent map once per pinned graph, including variant edges and owning types. A reference is not proof of a callable entry point or of breakage. Navigation, migration and factory references can be relevant to some changes; grouping or prioritizing them is a policy choice, not a universal exclusion theorem.

**Preserve every relevant typed unit.** `file_map` includes all associated units, including file-scoped caching profiles. It is not a list of Ruby constants. Use unit types when deciding which records are callable candidates, and retain profiles as supporting evidence where useful. Do not strip them from the graph merely because their identifiers look like paths. No public graph schema change is required for this prototype.

**The coordinator has added an optional offline exporter.** In the Woods source checkout, `script/typesafe/export_review_packet.rb` joins explicitly selected whole files to typed graph units from one pinned generation. Its guide is `script/typesafe/REVIEW_PACKETS.md`. It preserves hashes, full selected files, typed forward edge records and explicit missing-context status. It performs no reverse-dependent expansion or entry-point counting; full unit JSON can nevertheless contain an original unfiltered `dependents` array. It marks source lineage unverified and does not yet capture diffs or verify historical commits. Reuse its contract/tests where helpful, or keep your existing stronger packet implementation. It is development-only, uncommitted source-checkout tooling, not a newly shipped gem feature. Do not block your work waiting for it.

The coordinator's earlier export smoke used 83 selected typed units from the static Woods self-map and three units/nine forward edges from an older Rails testbed index. Those were byte-preservation/adapter checks, not validated dependent counts or fresh callback evidence. The frozen four-task development trial used Woods `55a74ea4f3a7c3e798493a92663003aab85a2301`, before #401. Preserve those historical artifacts and their executed-test results; do not reuse them as proof of complete callback context.

## Reporting and confidentiality

Return:

1. The runnable command and a concise sanitized example of an actionable report.
2. A per-case table of concrete findings, confirmed mechanisms, misses, false alarms and incomplete evidence, with comparator work/cost.
3. The failure diagnosis and changes made to the first design, including what Jev itself contributed.
4. A practical recommendation: keep the successful component, revise a specific failing step, or state the narrowly demonstrated limitation. Do not conclude “TypeSafe cannot do code review” from a failed PR-level scoring instrument.

Use historical reviews only as examples for choosing checks or explaining known failure modes. If discussing existing results, retain their scope: the older same-PR, same-pool ranking comparison is distinct from between-PR risk prediction, and neither establishes bug-detection quality.

Prepare a **sanitized companion** to the latest feedback for handoff. Use generic model/case names; omit employer class names, private paths, private PR identifiers, URLs and source excerpts. Keep any mapping and raw evidence local to the authorized project. Public Woods commit and issue references may remain. The coordinator has received the original attachment; do not redistribute it as a generic guide. This assignment itself intentionally contains no employer identifiers.

**Proceed with the prototype and the bounded tests. The next update should show code being reviewed and what the reviewer actually found, not another proposal to mine old PRs.**
