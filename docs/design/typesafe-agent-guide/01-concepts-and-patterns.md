# Concepts and development patterns

TypeSafe supplies small, typed judgments that ordinary code can combine. For
development, its most promising measured role here is selecting useful source
context for a coding agent. The coding agent still writes the patch; tests and
review establish whether the result works. Routing, extraction, review triage,
and claim checks are additional possibilities, with different evidence needs.

This chapter maps the current documentation to those possibilities. Vendor
examples explain mechanisms; they are not Woods measurements. Official pages
were checked on September 16, 2026. Consult the live
[documentation index](https://docs.typesafe.ai/llms.txt) before implementing an API
client. See [architecture and operations](02-architecture-and-operations.md) for
request handling and [the trial ledger](06-trial-ledger.md) for local results. The
official [patterns overview](https://docs.typesafe.ai/patterns) groups the control
flows that combine individual judgments.

## Start with a proposition, not a miniature coding prompt

The [System One model](https://docs.typesafe.ai/concepts/system-one) is useful when
the application can state the judgment, supply the evidence, and define the
possible result. An ordinary coding model remains useful for open-ended
implementation, explanation, and investigation. The
[use-case map](https://docs.typesafe.ai/concepts/use-case-map) is a starting point
for composing judgments, rather than a list of features already available in
Woods.

For each proposed question, specify:

1. **Decision:** what code will do differently after receiving the answer.
2. **Evidence:** which source, observations, and alternatives are actually
   available to answer it.
3. **Meaning:** what each answer represents, including uncertainty or absence.
4. **Validation:** which independent outcome will reveal a useful or harmful
   decision.

“Is this code good?” lacks all four. “Does this source span implement the literal
matching behavior described in the task?” can prioritize reading. It still cannot
prove that a change passes the database adapter's behavior tests.

## Choose the primitive deliberately

| Primitive | Result and suitable question | Development interpretation |
| --- | --- | --- |
| [Choice](https://docs.typesafe.ai/primitives/choice) | One of named alternatives, with their probability distribution and confidence. The current limit is 255 options. | “Which supplied subsystem best owns this symptom: extraction, publication, retrieval, MCP transport, or insufficient evidence?” Include an escape option when the roster may be incomplete. |
| [Noul](https://docs.typesafe.ai/primitives/noul) | Probability of “yes” for a binary proposition; no separate confidence field. | “Would this candidate help implement the requested behavior?” Several candidates can independently receive high values. |
| [Score](https://docs.typesafe.ai/primitives/score) | A probability-weighted position from 0 to level-count minus 1 on 2–10 ordered descriptive levels, with distribution, legend, and confidence. | “How much implementation detail does this passage contain: none, indirect context, or decisive implementation?” The numeric scale measures the chosen rubric, not probability of correctness. |

Choice probabilities depend on the alternatives. A candidate winning among weak
options does not establish that it contains adequate evidence. Noul allows
independent inclusion judgments, but asking about usefulness and asking about
sufficiency are different propositions. A Noul value near 0.5 represents
uncertainty about the proposition; it does not mean medium severity. Score can
represent intensity explicitly, but its response contract needs a dedicated
validator. The current local replay implementation supports Choice and Noul;
**Score has not been evaluated or implemented in that validator**.

Freeze polarity in both wording and code. For example:

| Question instructions | A larger Noul value means | Possible use |
| --- | --- | --- |
| “Does the supplied span contain implementation evidence useful for this task?” | More likely useful | Rank candidates. |
| “Is additional source required to resolve the stated claim?” | More likely incomplete | Fetch evidence or abstain. |
| “Does the provided execution record demonstrate this exact assertion ran and passed?” | More likely directly supported | Assist evidence review; retain the record. |

Do not add these three values together: their directions and meanings differ.
Changing wording from “is sufficient” to “needs more evidence” requires changing
the consuming policy, test fixtures, and cache identity too.

## Build state that preserves evidence roles

[State](https://docs.typesafe.ai/concepts/state) is the shared context for a
request's questions. Prefer named fields over an undifferentiated transcript.
Separate the task, source candidates, observed execution, and provenance. A test
definition is evidence of an assertion's existence; it is not a passing execution
record. An issue's expected behavior is a request, not an observation of current
behavior.

An application-owned representation might be:

```json
{
  "task": {"requested_behavior": "Return only published newsletter entries"},
  "candidate": {
    "id": "candidate-17",
    "path": "app/services/newsletter_builder.rb",
    "source": "<exact supplied source span>",
    "complete": true
  },
  "observed_execution": [],
  "evidence_limits": ["No database execution is included"]
}
```

These are illustrative application fields, not a Woods schema or a complete API
request. Keep private acceptance tests, expected labels, reference patches, and
post-outcome notes outside the scoring state. Record their hashes separately for
evaluation reproducibility.

The [primitive contract](https://docs.typesafe.ai/primitives) says question IDs are
not model-visible. An ID such as `check_runtime_proof` cannot teach the model what
counts as runtime proof. Put the complete proposition, candidate reference, and
required distinction in question instructions. IDs route validated answers back
to code.

The current documentation describes an approximate **32,000-token combined
state-and-questions budget**. Treat this as prospective planning guidance, not a
measured exact rejection threshold. Account for repeated instructions and
representation overhead; split candidate batches before approaching the limit.
The cause of an older large local request's HTTP 400 was not established. A later
compact request succeeding does not retroactively identify that cause.

## Batch independent judgments; sequence real dependencies

[Fan-out](https://docs.typesafe.ai/patterns/fan-out) evaluates several questions
against evidence already available. Answers in the same request do not feed one
another. For one source card, relevance, likely subsystem, and missing-context
questions can share state. Code can consume only the answers relevant to the
selected branch.

A real dependency requires another step. If the first result selects three skill
names, the program must fetch those skills before judging their full instructions.
If a result identifies a helper, read that helper before asking whether the
combined implementation preserves behavior. A second question cannot inspect
unfetched source merely because its ID mentions that source.

The local assertion pilot reduced input from 9,012 to 3,172 tokens by batching the
same five questions over shared state. That supports avoiding repeated context,
not an assumption that arbitrary extra questions are free or equally reliable.
Results and scope are recorded in [the ledger](06-trial-ledger.md).

### Adapt the smart-home control flow

The [smart-home demo](https://docs.typesafe.ai/demos/smart-home) speculatively asks
about category, device/domain, and action, then lets code use the applicable
branch. Compound requests and conversation can go to a generative model. A
development analogue could classify a request, identify a likely subsystem,
assess which supplied evidence is useful, and route to an ordinary investigation
or coding workflow.

For “fix this stale index warning,” a proposed router might produce:

- task category: diagnose index freshness;
- relevant evidence: status and publication provenance;
- next handler: a known read-only diagnostic workflow;
- evidence gap: installed version or latest extraction result missing.

This is a **proposed integration**, not a shipped Woods agent. Repository
instructions, permission, argument validation, and tool availability remain
ordinary program constraints. Uncertainty in an unused branch should not trigger
an unnecessary escalation. The useful measurement is whether routing improves
completion or reduces work without hiding required checks.

## Cookbook map: what could be reused

“Related trial” below means that local experiments exercised a comparable idea;
it does not mean the cookbook was reproduced or its full workflow implemented.

| Documentation | Development adaptation | Local status and important limit |
| --- | --- | --- |
| [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions) | Share source state across independent relevance, evidence-role, and completeness questions. | Related batching trial completed. Questions remain independent; missing evidence requires a fetch. |
| [Reranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe) | Retrieve cheaply, judge candidate usefulness, then pack an evidence budget for an author. | Related end-to-end trials completed. Measure candidate recall and usable delivered source, not just ranking accuracy. |
| [Semantic find](https://docs.typesafe.ai/cookbooks/semantic_find) | Choose an existing line/span ID and separately judge whether answer evidence is present. | Related source selection tested; this exact line-search workflow untested. A forced winner is not proof of adequate context. |
| [Function calling](https://docs.typesafe.ai/cookbooks/function_calling) | Select an allowlisted diagnostic operation and closed arguments. | Untested. Validate identifiers and callable tools in code; this does not generate arbitrary safe commands. |
| [Skill suggestion](https://docs.typesafe.ai/cookbooks/skill_suggestion) | Rank short skill descriptions, fetch a shortlist, then allow rejection of every skill. | Untested. The example reports harmful suggestions too. Mandatory repository/skill rules still apply. |
| [Intent routing](https://docs.typesafe.ai/patterns/intent-routing) | Route source lookup, boot diagnosis, freshness investigation, or implementation to known handlers. | Untested. Keep a useful fallback and measure misroutes plus extra work. |
| [Pre-parsed extraction](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook) | Enumerate constants, paths, versions, or error locations deterministically; choose a candidate ID; copy exact text in code. | Related selection idea tested; general extraction untested. No selector can recover a candidate the parser omitted. |
| [Date extraction](https://docs.typesafe.ai/cookbooks/date_extraction_cookbook) | Interpret issue deadlines or relative dates, then validate calendar arithmetic with an explicit reference date and timezone. | Untested, low Woods priority. Reject incompatible or absent date components. |
| [Autoformat](https://docs.typesafe.ai/cookbooks/autoformat) | Recover prose blocks or build a reading guide while retaining original text. | Untested. Ruby source boundaries should come from a parser; joining lines before classifying blocks is a genuine sequential dependency. |
| [Entity alignment](https://docs.typesafe.ai/cookbooks/entity_alignment) | Suggest potential renames/moves between snapshots after exact identity/path comparisons. | Untested. Never rewrite public Woods identifiers probabilistically. Intermediate scores and routing cut points still require evaluation. |
| [Citation check](https://docs.typesafe.ai/cookbooks/citation_check) | Match quotes and locations deterministically, then judge whether surrounding evidence supports the stated claim. | Related claim trials completed, with errors. Missing quote, unsupported claim, and contradiction are different outcomes. |
| [RAG passage classification](https://docs.typesafe.ai/cookbooks/classifying_rag_passages) | Separate relevance, answer evidence, and contradiction; expose useful conflicts to the author. | Related relevance ranking tested; full workflow untested. Its injection judgment is explicitly not a security boundary. |
| [SDE cascade](https://docs.typesafe.ai/cookbooks/sde_cascade) | After schema checks, judge narrow extraction-error conditions and escalate suspicious fields with original evidence. | Untested. Measure missed errors and escalation burden; keep deterministic validation. Example model choices and prices are historical. |
| [Hierarchical classification](https://docs.typesafe.ai/cookbooks/hierarchical_classification) | Explore large module trees while retaining several paths, then fetch exact leaf evidence. | Untested. Pruning can lose the correct branch. A geometric-mean path score is a search heuristic, not calibrated path correctness. |
| [Confidence routing](https://docs.typesafe.ai/patterns/confidence-routing) and [coarser labels](https://docs.typesafe.ai/cookbooks/classification_using_confidence) | Obtain more evidence, choose a useful broader category, or request review when a detailed classification is uncertain. | Confidence observed; no validated production threshold. Broader labels can also be wrong. |
| [Composite scoring](https://docs.typesafe.ai/patterns/composite-scoring) | Reuse separately judged dimensions with transparent policy weights for review priority. | Untested as a workflow. Mandatory conditions should not disappear into a weighted average. |
| [Autoresearch feature discovery](https://docs.typesafe.ai/cookbooks/autoresearch_feature_discovery) | Let an ordinary LLM propose judgment features, then train/evaluate a supervised triage model. | Untested; defer until enough independent outcomes exist. Preserve grouped/chronological splits and an untouched final test set. |
| [Noul consistency](https://docs.typesafe.ai/cookbooks/consistency_noul_cookbook) and [Choice consistency](https://docs.typesafe.ai/cookbooks/consistency_choice_cookbook) | Repeat requests and measure answer drift, rank changes, routing changes, and downstream success separately. | Limited exact repeats completed. Vendor examples vary a throwaway UID; cached replay is not a fresh model repeat. |

## Interpret confidence and local evidence conservatively

[Confidence](https://docs.typesafe.ai/confidence) summarizes distribution
concentration and differs from the winning probability. Neither quantity is a
guarantee that the proposition was correctly framed or adequately evidenced. An
earlier local trial included a wrong classification at 0.94 confidence and a
correct one at 0.52. Thresholds must be evaluated against the intended decision,
including false approvals, abstentions, and additional review work.

Do not infer that more questions necessarily improve policy. An earlier local
veto composition retained none of four correct direct-support decisions. Preserve
raw outputs and evaluate the consuming rule independently. The
[pitfalls chapter](08-pitfalls-and-diagnostics.md) separates configuration,
representation, and model limitations.

The completed four-task experiment provides a narrower positive result. At a
1,000-token source budget, TypeSafe selection produced accepted patches on 4/4
tasks on each of two author draws; BM25 produced 3/4 on each. Both reached 4/4 at
3,000 tokens. The difference came from one repair; both genuine additive features
succeeded under every tested condition. These are four task blocks and 28 author
attempts, not 28 independent tasks. A separate model authored every patch.

This justifies further optional evidence-selection use, especially at the low
reported input price. It does not validate automatic merge decisions, universal
bug detection, performance assurance, or all the proposed cookbook adaptations.
The [evaluation chapter](04-code-authoring-and-evaluation.md) explains acceptance
and its limits; [cost and adoption](07-cost-and-adoption.md) compares the marginal
selector cost with whole-workflow value.
