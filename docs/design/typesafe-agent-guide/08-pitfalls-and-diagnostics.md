# Pitfalls and diagnostics

Diagnose the earliest broken stage before attributing a result to model capability. Typed output can be well formed and semantically wrong; an excellent judgment can also be lost through missing source, packing, stale state, or an overrestrictive decision rule. The [trial ledger](06-trial-ledger.md) records the studies summarized here; the [evaluation chapter](04-code-authoring-and-evaluation.md) explains how to test the complete workflow.

## Locate the failure

| Layer | Check first | Appropriate interpretation |
| --- | --- | --- |
| Task and reference labels | Public meaning, label overlap, reviewer instruction parity, family leakage | Possibly an underspecified task or disputed reference |
| Source and discovery | Correct snapshot, runtime/static distinction, index coverage, candidate availability | Missing evidence cannot be repaired by reranking |
| Request | Exact outgoing state, complete instructions, question polarity, model and API shape | A configuration defect may invalidate the comparison |
| Transport | Status, sanitized error category, elapsed deadline, size, attempt ledger | An operational failure, not a semantic negative |
| Response | Model policy, exact answer IDs/types, finite values, usage | Invalid responses must not become ordinary scores |
| Composition | Thresholds, Boolean grouping, tie rules, retained useful decisions | A good primitive can produce a bad workflow |
| Packing and author | Actual delivered bytes, partial spans, repeats, prohibited tools | Identifier presence is not sufficient context |
| Oracle and report | Expected tests executed, wider edits, input shapes, denominators | Passing declared checks is narrower than full compatibility |

Preserve the original request and outcome before running a diagnostic variant. A variant is new evidence, not permission to rewrite the original result. Use [operations](02-architecture-and-operations.md) for response validation, bounded calls, credential handling, and proposed cache behavior.

## Confidence did not establish correctness

In the expanded assertion trial, one correct direct judgment had confidence **0.52**, while a **0.94** judgment disagreed with the reviewed weak/absent taxonomy. The reference labels themselves were agent-reviewed development labels, so call this a demonstrated disagreement rather than an absolute theorem about correctness. The important result is that confidence did not cleanly separate useful from disputed decisions.

Choice/Score confidence summarizes the returned distribution; Noul has no separate confidence field. A Noul near 0.5 expresses uncertainty about its yes/no proposition, not medium assertion strength or moderate severity. A high relevance Noul is not the probability that a resulting patch will pass. [TypeSafe confidence](https://docs.typesafe.ai/confidence), [Noul reference](https://docs.typesafe.ai/primitives/noul).

If you need routing thresholds, declare the loss you are trying to avoid and evaluate both error and retained utility on fresh families. Do not fit a threshold to these examples and call it validation.

## A conservative veto removed every useful direct decision

The decomposition pilot's batched Choice matched **16/16** reference labels. Its composed veto nevertheless escalated **all four correct direct cases**, retaining **0/4**. It required all auxiliary judgments to meet fixed cutoffs; combining several plausible questions did not improve the useful decision.

The failure belongs to the composed policy, not an API/schema failure. Preserve raw labels, routed labels, correct-direct retention, and review count separately. “No false direct outputs” is not sufficient success when nothing is allowed through. The policy remains in offline replay for reproducibility; it is not an adoption recommendation. [Historical audit](evidence/typesafe-guide-history-audit.md).

Batching itself was useful in a different sense: the same five questions on four packets consumed 3,172 input tokens together versus 9,012 separately. That 64.8% reduction compares equivalent question sets. It does not mean five questions cost less than one, or establish concurrent production throughput.

## The 0.39/0.61 claim example changed with the decision rule

One natural-claim result selected `supported` with probability **0.39**, while the other categories together held **0.61**; reported confidence was **0.18**. The largest individual category and an aggregated supported/not-supported decision answer different questions. Code must choose that grouping prospectively. Do not reinterpret it after seeing the reference label and count the reinterpretation as another correct prediction.

The natural-claim trial had further confounds: reviewers did not initially receive equivalent instructions; antecedents were sometimes missing; historical observations were confused with current code implications; unsupported and insufficient-context labels overlapped. It lacked contradiction-positive natural cases and a new historical execution oracle. Review found no demonstrated API/model/schema defect. Later aligned and narrower questions performed well, but an unchanged original also improved on repetition, so the data did not isolate a configuration cure or a model ceiling. [Historical audit](evidence/typesafe-guide-history-audit.md).

Keep “the code implies this,” “this test asserts it,” “a supplied record says it happened,” and “we executed and observed it” as different evidence types.

## HTTP 400 did not identify an exact provider limit

The first context-selection request was **180,409 bytes** and returned HTTP 400 before authors began. A small-state ten-question marker worked; the original full state still failed with one marker question. The original error body was not preserved sufficiently to establish a cause, and rejected-request usage remained unknown.

A later compact **24,471-byte** request worked. It changed content and representation as well as size, so success did not prove which earlier property caused rejection. The vendor's current primitives documentation describes an approximate **32,000-token shared state-plus-questions budget**. The later experiments' **24 KiB JSON request cap** was a conservative local rule, not a discovered vendor byte limit. Tokens, Unicode characters, and encoded JSON bytes are different measurements. [Current primitives documentation](https://docs.typesafe.ai/primitives).

On a new failure, preserve safe structured error codes, status, request hash/size, known usage, and timings without storing credentials or echoing sensitive input. Bound diagnostics and vary one factor where possible. Report an unknown cause honestly. Do not infer that a rejected request was free or retry indefinitely. Exact retry behavior belongs to the declared workflow, not a guess about SDK defaults.

## Some defects were in our harness

An earlier replay policy could accept reversed Noul question meaning when a matching new request hash was supplied. Invalid UTF-8 could also escape the intended sanitized CLI handling. Regression tests failed before fixes; the current local replay implementation binds the complete supported question semantics and rejects malformed encoding. These were harness defects, not evidence of a provider misclassification.

The current source-checkout validator supports its defined Choice/Noul profiles; Score support is not implemented there. Do not pass a documented vendor primitive into a local validator that has no corresponding contract and mislabel the refusal as an API limitation. Similarly, the implemented materialized evidence reader checks exact bytes, digests, bounded reads, and confined resolved paths. It does not prove Git lineage, prevent hostile filesystem races, or implement the complete original corpus pipeline. [Woods integration boundaries](05-woods-integration.md).

The portable Python reference's second review found additional client-boundary defects that the original 20 offline tests missed. These were synthetic local probes, separate from the historical provider trials:

- A 401-digit integer could crash probability validation or usage-cost arithmetic. Check the probability range before converting to floating point, and explicitly bound accepted usage counters as a local policy. Also reject exponent overflow such as `1e309`; rejecting literal `Infinity` alone is insufficient.
- An array or null where a manifest, capture, or receipt object was expected could produce a traceback. Validate local containers explicitly. Validate the complete replay sequence before consuming it, including terminal failure records; the writer stops on failure, so a capture containing later successes is inconsistent.
- A filesystem read error after a successful response could erase already-known usage from the stopped result. Source drift must suppress ranking while retaining valid counters from completed attempts. A later local failure does not make earlier requests free.
- POSIX-only path checks accepted Windows drive-qualified source paths that could escape the manifest root on Windows. Reject drive-qualified and alternate-data-stream syntax as well as POSIX traversal; do not treat ordinary path checks as a hostile-filesystem sandbox.

The corrections and independent rechecks are recorded in [guide validation](VALIDATION.md). These failures illustrate why a typed provider response is only one part of a reliable integration. Exercise replay and local I/O failure paths as well as successful requests; preserve observed costs without converting invalid counters into invented zero usage.

## Source representation can remove the answer before selection

Before the four-test trial, review found that Prism segmentation dropped bare visibility declarations without preserving visibility metadata in method headers. That could hide whether an insertion site is private. The initial discovery artifacts were archived, the generic omission rule was corrected to retain actual declarations, and all preparation was regenerated before any measured call. No target-specific rescue or outcome tuning occurred.

Retaining a declaration in the corpus does not ensure ranking or packing includes it. Test every boundary separately: source exists; index can identify it; discovery returns it; shortlist retains it; context contains its actual bytes; required surrounding semantics are available. Static parsing also does not prove Rails runtime behavior. [Evidence selection](03-evidence-selection.md).

In the four-test results, every target file appeared in every enrolled context. BM25's 1,000-token SQLite context still lacked the relevant implementation, and both authors abstained. TypeSafe supplied the SQLite search method but not its escaping helper, leading to broader SQL rewrites. At larger budgets, some authors restored escaping directly. File/identifier recall alone would conceal these differences.

The earlier retrieval study likewise distinguished retained identifiers from complete source. A truncated candidate may count as present while omitting its decisive guard. A low-cost ranker cannot compensate for a context assembler that discards the required evidence. [Four-test results](evidence/2026-09-16-typesafe-four-tests-evaluation.md), [retrieval study](evidence/2026-09-16-typesafe-retrieval-evaluation.md).

## Passing tests did not prove complete compatibility

In the method-context pilot, a filename-identity repair passed frozen String-based tests but dropped existing `to_s` coercions. Five of eight later Symbol/custom-coercion probes raised `NoMethodError` only for that patch. The helper documented String arguments and normal inspected callers used Strings; the audit therefore recorded an observed compatibility gap, without inventing a guaranteed non-String public contract or rewriting the primary score. This was the filename helper, not the materialized evidence reader. [Method-context study](evidence/2026-09-16-typesafe-span-evaluation.md).

In the four-test follow-up, all five accepted literal-search patches narrowed InMemory Unicode case folding. Three also changed SearchExecutor field attribution and a sample keyword score from 0.5 to 0.25. The documented adapter contract explicitly leaves non-ASCII folding backend-specific. Those changes deserve review, but are not established violations of the promised ASCII behavior. Additional retrieval/ranker suites passed 116 examples for each patch and the correct baseline; passing them still does not establish exhaustive equivalence or SQL performance. [Supplementary audit](evidence/four-tests-posthoc-review.md).

Use posthoc probes to describe limits and improve future task preparation. Do not relabel a passing frozen endpoint because an undocumented expectation was added afterward. Conversely, do not describe it as production-ready merely because no frozen assertion failed.

## Real defects came from independent audit

The same posthoc work reproduced two failures in untouched Woods source:

- A SQLite field query containing NUL matched unrelated text, and a normal substring after a stored NUL was missed. Three generated SQL rewrites incidentally avoided this behavior; they did not earn extra primary credit. [Woods #355](https://github.com/lost-in-the/woods/issues/355).
- Boolean field searches used `true`/`false` in InMemory and `1`/`0` in SQLite. The issue asks for a consistent representation, rather than assuming one adapter is authoritative. [Woods #356](https://github.com/lost-in-the/woods/issues/356).

A newsletter mutation also exposed missing publication-isolation regression coverage while the actual application remained correct. That is a test gap, distinct from a current behavior bug. [Testbed #24](https://github.com/lost-in-the/woods-testbed/issues/24).

These findings came from deterministic inspection and execution around the experiments. Do not claim TypeSafe autonomously found them. For a new issue, reproduce against untouched current code, separate environment failure from behavior, check duplicates, and attach a small sanitized example. A defect only in an experimental author patch belongs in the experiment record.

## Cheap inference still needs honest comparison

The four-task primary selection cost approximately $0.00704; the diagnostic repeat doubled that. At the supplied rate, demanding dramatic compression before considering any benefit would miss useful quality gains. But comparing a subsecond TypeSafe HTTP call with an entire agent turn is not a speed benchmark, and unmeasured comparator usage cannot establish a savings ratio.

Cache effects also matter. Identical repeated author prompts reported different total input usage, and different policies received different cache hits. Keep raw usage, optional unknown counters, preparation, author effort, review, and retry/escalation separate. An all-abstaining comparator or a policy that sends everything to review is not a convincing economic control. See [cost accounting](07-cost-and-adoption.md).

## Stop, correct, or continue deliberately

Stop an affected run when source/configuration fingerprints change or a response violates its contract. Preserve attempts and known costs. Fetch missing evidence or revise a rubric only as a new, labeled stage; do not quietly repair the old result. Whole-task deterministic fallback is appropriate only for the workflow and snapshot against which it was tested. A fallback cannot authorize stale-source patch application.

Continue ordinary coding and testing when the selected evidence is useful; the selector need not become a correctness authority. Use the [agent playbook](09-agent-playbook.md) to select the next bounded action, and the [guide index](README.md) to distinguish tested mechanisms from proposals.
