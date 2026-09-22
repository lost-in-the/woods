# Building a useful evidence selector

Use TypeSafe after deterministic discovery has produced plausible source candidates, and before a coding or review agent consumes them. This was the most promising application in the Woods trials. The model assigns narrow usefulness judgments; your program owns source discovery, ranking policy, exact source delivery, provenance, budgets, and failure handling. Read [the trial ledger](06-trial-ledger.md) before choosing a policy.

## Define the downstream operation first

“Relevant to payments” and “useful for adding a read-only refundable balance” ask different questions. A payment controller might be topically relevant while a small persisted-refund aggregation or model declaration provides the implementation evidence the author needs. Describe the intended operation, required observable behavior, and behavior to preserve. Do not include a private repair location or the known reference solution in a benchmark prompt.

For ordinary development, a known filename supplied by the user is legitimate context. In an evaluation of autonomous localization, supplying that same filename removes the localization challenge. Record the distinction rather than mixing success rates.

A useful narrow question is:

> Does this source candidate provide concrete implementation, declaration, or relationship evidence useful for performing the task in `task.description`?

Define yes and no in relation to the task. Ask one Noul per candidate when several candidates can help. Its number is a judgment about this proposition; it is not the probability that an eventual patch will pass. If you want degrees of usefulness, a well-defined Score is another design to test. Woods trials did not evaluate Score.

The [reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe) supplies the candidate-judgment pattern. [Semantic find](https://docs.typesafe.ai/cookbooks/semantic_find) illustrates a different construction: a Choice over source IDs plus a separate answer-presence judgment. Choice probabilities compete across the options in that request; they are not directly comparable independent relevance scores across separate candidate batches.

## Measure where evidence can disappear

Treat retrieval as successive sets, with independent diagnostics:

```text
repository source
  -> indexed units
  -> discovered files/units
  -> parser-defined source cards
  -> deterministic shortlist
  -> semantic ordering
  -> packed source actually delivered
  -> author patch
  -> independently checked behavior
```

For each target or independently labeled source, record its presence at each stage. Also record partial scans, caps, stale indexes, unsupported types, parse failures, oversized cards, and truncated delivered spans. Never turn an unavailable stage into an empty, successfully searched corpus.

A reranker cannot restore a unit excluded before its request. The Canopy retrieval trial had approximately 95% available-candidate recall on average and one query with no relevant candidate at the ranking boundary. No score improvement can repair that case. Conversely, a correct source ID in returned metadata does not prove the decisive code survived packing: at the 600-token setting, TypeSafe increased relevant-ID recall without improving complete-source recall.

For a behavioral task, annotate useful mechanisms separately from a single reference edit location. A valid implementation can modify a different delivered method. Private target-file and edit-site diagnostics are valuable, but they must not become hidden restrictions on accepted solutions unless the task explicitly requires that location.

## Use a credible deterministic baseline

Start with exact identifier/path lookup when the task gives one. Otherwise use repository search, available Woods structural search, an existing retriever, or BM25 over a defined source corpus. Record tokenization and tie rules. Keep a no-semantic-call baseline available throughout the experiment.

The later four-task trial used this fixed policy:

1. Split camel case, lowercase ASCII alphanumeric words, apply a fixed stopword list, and keep words of length at least three.
2. Construct escaped Ruby-regex alternatives from all unique task-description tokens, in lexical order.
3. Search identifiers and source with a 1,000-result limit while retaining the packaged 500-source scan cap; record both possible truncation conditions separately.
4. Resolve returned typed identifiers to source files, deduplicate paths, and segment actual snapshot source with Prism.
5. Rank cards using BM25 with k1=1.2, b=.75, and `log(1 + (N - df + .5)/(df + .5))`. Documents combine identifier, file path, namespace, and candidate source; query terms are unique.
6. Retain the first 80 cards. Break ties by identifier, path, start byte, and end byte. Withhold these baseline ranks/scores from TypeSafe.

This is a description of the tested protocol, not a universal optimum. The broad query discovered 59/65 eligible Canopy files and 258–261/261 Woods files. It removed private localization hints, but nearly enumerated the Woods source corpus. For a larger application, evaluate narrower exact lookup, hybrid discovery, or hierarchical expansion on fresh tasks. Do not silently replace a failed query with a gold-target query.

Earlier experiments used other baselines, including native retrieval, native top-three selection, unique lexical overlap, and an ordinary agent. Their results answer different questions. The top-three native control saved 8.7% of delivered tokens on the Canopy corpus without losing a baseline-labeled source; that is a reason to test cheap controls before adding a model. It does not establish that every unlabeled source was useless.

## Source cards must preserve semantics and provenance

Prefer parser-defined methods plus meaningful supporting source to arbitrary line windows when the task concerns code. Whole files remain useful controls and sometimes better context. A short method without its surrounding declaration can be misleading.

A local card should retain at least:

| Field | Purpose |
| --- | --- |
| Candidate ID | Stable local routing key within a frozen selection set |
| Typed source identity | Avoid collisions between units with the same textual name |
| Repository/snapshot identity | Distinguish branches, commits, and local overlays |
| Index generation number and token | Bind the discovery view; a number alone can restart after index recreation |
| Physical relative source path | Locate the actual editable file |
| Whole-file SHA-256 | Reject stale source before reuse or patching |
| Original start/end byte offsets | Bind the precise UTF-8 interval, not guessed line positions |
| Exact source text | Give the selector and author evidence, with no normalization surprises |
| Kind, namespace, and necessary declarations | Make the snippet interpretable |
| Original/delivered completeness flags | Distinguish a full method from a prefix or pre-clipped card |
| Transformation version | Reproduce comment attachment, clipping, and segmentation |

Keep full provenance in an offline sidecar. Provider state needs only allowlisted context necessary for the judgment. A local manifest may legitimately contain labels and oracle references; the outgoing serializer must construct a fresh object that cannot accidentally include them. Deleting a few known secret keys from a large object is a fragile alternative to an allowlist.

A runtime-extracted unit can be an assembled view: concern behavior, reflections, or metadata may not be one contiguous physical source interval. Use that view to understand the application, but construct editable evidence from verified actual file bytes. Do not authorize a patch merely because its text appears somewhere in an assembled model document.

Ruby-specific evidence that can matter includes visibility declarations, class/module nesting, refinements, included concerns, aliases, constants, singleton methods, inherited behavior, and macros. RSpec context can depend on subjects, lets, hooks, shared examples, helpers, or custom matchers. Missing context is a fact to surface, not a gap a score can erase.

The four-test preparation caught a concrete representation defect: bare `private`, `protected`, and `public` declarations had been dropped without preserving visibility metadata. Review corrected it before inference and archived the original preparation. A guide implementation should mechanically retain such source or attach verified semantics with provenance. Availability in the candidate corpus still does not guarantee delivery after ranking.

## Bound requests without inventing vendor limits

The successful later trials used a **local 24 KiB serialized request cap** and no automatic retries. That cap was a conservative operating choice, not the service's advertised maximum. Current documentation describes an approximate shared state-and-question budget of 32,000 tokens; English character approximations are particularly unreliable for source code and escaped JSON. [Primitives](https://docs.typesafe.ai/primitives).

Pack complete candidate/question units into a request. Count the final encoded request bytes, including instructions and JSON escaping. Stop preparation if one candidate cannot fit under the chosen policy; do not silently crop it differently for one comparison arm. The four-test study prospectively allowed a 16 KiB UTF-8 prefix per card with a completeness flag, but no shortlisted card needed it. Other protocols should choose and test their own clipping rules.

Batch independent judgments over shared state to avoid retransmitting it for every question. Questions cannot consume each other's answers. A second request is appropriate if a first-stage result is needed to fetch a complete method, choose options, or create new state. That is the basis for a proposed shortlist-then-hydrate workflow, not proof that any particular two-stage configuration works.

The initial large context-selection request failed at 180,409 bytes; a later 24,471-byte compact request succeeded. Content, representation, and size changed together. The failure does not prove a precise service byte limit. Preserve the rejected trial and unknown failed-call usage rather than presenting compacting as a proven causal repair.

## Separate ordering from removal

Our most reliable promising direction is **reordering candidates**, with deterministic fallback. The Canopy policy that removed every Noul at or below .5 saved 19.5% of context tokens but lost baseline-labeled IDs on 12/28 queries and complete labeled source on 13/28. Aggregate relevance improved while individual evidence disappeared.

Part of this was task mismatch: a requested type intentionally kept weak fallback candidates, while the usefulness question scored them low. Part was packing. One audited ranking error put a stale-review record ahead of the method containing the actual guard despite that guard's complete source being available. None of these observations supports adopting a general .5 cutoff.

For a new project, first compare pure ranking with a zero-model baseline under identical packing. If removal is valuable, define the consequence of losing evidence, evaluate missing-evidence recall and downstream behavior, and freeze the threshold on separate development data. A no-match or presence judgment is a separate decision to validate. A low relevance score does not grant permission to skip a test, ignore a violation, or declare that code absent.

## Packing is part of the algorithm

Source selection quality can disappear in formatting. Measure the exact final delivered context after headings, fences, truncation markers, section allocations, and appended metadata. Distinguish:

- Candidate inclusion: an ID appears somewhere in the output.
- Complete candidate inclusion: all supplied candidate source appears.
- Complete original source: no earlier card clipping occurred either.
- Mechanism coverage: the relevant guard, declaration, or relation is present.
- Task success: the independently checked implementation works.

The tested ordered-prefix policy stops after a partial final card. It is deterministic and easy to audit, but not an optimal packing solution; the binary-search prefix is feasible under the tokenizer, not guaranteed to be the longest possible BPE-fitting prefix. Native Woods assembly has its own section budgets and sorting. Reordering an input array is ineffective if the assembler immediately resorts by score; the retrieval trial replayed the actual assembly behavior.

Potential alternatives worth separate experiments include preserving whole methods, attaching fixed declaration/helper context, skipping oversized candidates, keeping incumbent context while adding complementary evidence, and selecting complementary groups. These were not validated as superior policies here. Changing selection, packing, and rubric simultaneously prevents attribution.

[Woods #354](https://github.com/lost-in-the/woods/issues/354) demonstrates another distinction: reported token counts were computed before final context postprocessing. Recounting the final string under the **same estimator** established inaccurate accounting; it did not establish that an advertised hard budget had been violated. A reference tokenizer such as cl100k_base is also not the downstream provider's actual billed token count.

## Delivery contract and practical recommendation

Persist the exact selected source ledger before authoring. A stale file or changed index generation should cause revalidation/reselection, not silent application to a new source tree. On an incomplete or malformed score vector, discard that vector and reuse the complete deterministic ranking; do not mix partial probabilities with lexical scores on an undefined scale.

Use the [reference examples](examples/README.md) to understand these boundaries, then implement the actual repository adapter for your project. The examples are not the full Woods experiment harness and do not certify candidate discovery or model quality. Start with an optional advisory context view, measure accepted task outcomes and recurring cost, and keep a one-step return to the deterministic policy. [Architecture](02-architecture-and-operations.md), [Woods integration](05-woods-integration.md), and [evaluation](04-code-authoring-and-evaluation.md) define the surrounding contracts.
