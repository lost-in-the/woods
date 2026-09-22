# Jev Rails reviewer: response, verified Woods capabilities, and follow-up prompt

Reviewed 2026-09-19 against Woods commit
`2885f7550f2ee58f627806f73c86feb7aea5e1d7` and current TypeSafe documentation.
This is a sanitized companion to `2026-09-19-jev-rails-review-feedback.md`.
It updates that assessment after the author's response. It proposes changes;
it does not authorize implementation, inference, hooks, or publication.

## Updated assessment

**The author's main correction is right: Woods should be the primary Rails
evidence source for this reviewer.** Reimplementing its schema, callback,
configuration, and relationship extraction in a review hook creates unnecessary
work and weaker evidence. My earlier “consider reusing” language understated
this opportunity.

I also accept the proposed sequencing: repair the question definitions and run
a small direct-Jev defect/control trial before requiring a multi-arm comparison.
That first trial can establish useful examples, obvious misses, and nuisance
findings. It cannot establish superiority over another reviewer or reliability
across projects, but those are later questions.

The architectural recommendation is a **Woods-backed evidence adapter with
revision-specific source and test supplements**. Some stronger statements in the
response blur the distinction between reflected registrations, source-derived
annotations, and demonstrated runtime behavior. Preserving those distinctions
makes Woods more useful; it does not require rebuilding Woods or postponing the
first experiment.

## Where I accept the pushback

- The polarity, malformed table, count, mapping, schema helper, hook, and Rails
  API corrections remain useful. They concern the printed sketches, not an
  unseen production implementation. Their practical impact should not be used
  as evidence against Jev's ability.
- Independent parallel questions and persona labels were already discussed in
  the bank. The actionable change is to make the implementation and annotations
  consistent with that understanding, not to relitigate the architecture.
  Asking speculative questions and filtering their answers in application code
  is an explicitly documented pattern. [TypeSafe fan-out][T1].
- A chart can be useful navigation without being a validated defect predictor.
  Keep truthful labels, direction, and scale. Validation becomes necessary for
  claims such as “this is the probability the change is unsafe,” or for automatic
  blocking based on that chart.
- Broad questions deserve a fair trial. Narrow, contract-specific questions are
  an option to investigate after a failure, not a prerequisite for every row.
- Correlated questions can provide complementary coverage. Correlation alone
  does not justify deleting or merging them.
- The small first trial is preferable to another extended methodology exercise.
  No additional historical-PR corpus is required to begin it.

## What Woods actually supplies

These are findings about the pinned source checkout. The receiving project's
installed gem, extraction producer, and retained units may be older. A manifest's
writer version identifies its last publisher; incremental publication can retain
older units. Verify actual capability and rebuild relevant evidence when needed.
[Published-index provenance][W1].

| Area | Verified capability | Implication for the adapter |
|---|---|---|
| Model schema | Model source is enriched with columns, types, indexes, and foreign-key information from the connected database. | Replace the hand-written schema regex. Also supply proposed migrations and identify the extraction environment: current schema alone does not establish rollout safety, future schema, table size, query selectivity, or index usefulness. |
| Callback chains | The model extractor reflects Rails callback chains and conditions. Side-effect enrichment locates method bodies in model/concern source and scans them. | Use registrations and annotations together with source. Empty effect lists do not prove absence of effects; the concrete reproduction below matters for review questions. |
| Controller filters | The extractor reads the resolved process-action chain, ancestors, and action restrictions. | This substantially improves inherited-filter review. Arbitrary predicate/proc conditions are not executed to establish authorization outcomes. Retrieve the relevant parent/filter/policy implementation when the question needs its behavior. |
| Dependency volatility | The graph analyzer really computes commit-count ratios and ranks qualifying dependencies by PageRank. | Reuse it as a structural review signal. It is a heuristic with a history window, exclusions, and output caps, not a finding that the dependency is wrong. |
| Configuration | Configuration files are indexed; `BehavioralProfile` reads selected resolved Rails settings, including Rails version and the configured ActiveJob adapter. | “Woods can't supply runtime config” is too broad. The earlier review said it does not emit every effective setting; it should also have named the useful settings already available. Use these fields and supplement missing question-specific settings, such as effective per-job commit-enqueue behavior. |
| Policies, jobs, migrations, tests | Dedicated extractors expose policy code, job metadata, migration indicators, and test mappings. Their mechanisms vary; several fields are derived from source patterns. | Useful inputs, with field-specific interpretation. For example, `retry_config` is source-scanned; a test mapping is a candidate relevant test, not measured execution coverage. |
| Reverse relationships | Published graph queries expose recorded dependents and relationship labels. | Preserve type and `via`, and disclose traversal limits. Select edges for the question being asked rather than treating every reverse edge as a production caller. |
| Freshness | Supporting versions compare captured source inputs with currently visible source, bound to the served generation, and report `current`, `drifted`, or `unknown`. | Use this evidence, preserving reasons and scope. It is not a blanket guarantee that all facts required by every review question were collected. |

Implementation references: [models][W2], [callback analysis][W3],
[controllers][W4], [graph analysis][W5], [behavioral profile][W6],
[jobs][W7], and [extractor reference][W8].

### A reproduced callback limitation to preserve explicitly

I ran the current `CallbackAnalyzer` against five synthetic sources, without
booting Rails or executing the callback. These were the results:

| Source/filter shape | `columns_written` | Other useful evidence |
|---|---|---|
| Callback method directly assigns `self.status = :ready` | `["status"]` | Assignment operation present |
| Callback method calls `set_status`; that helper assigns `self.status` | `[]` | Helper call appears in `operations`; its body is not recursively analyzed for column writes |
| Proc callback assigns `self.status` | `[]` | Empty operations for the tested proc label |
| Named callback method cannot be located | `[]` | All effect arrays empty |
| Located method containing only `nil` | `[]` | The same empty effect arrays as the unresolved method |

For example, the second case supplied both methods:

```ruby
class SampleRecord
  def normalize
    set_status
  end

  def set_status
    self.status = :ready
  end
end
```

The probe passed `normalize` as the callback filter and `status` as a known
column. The source therefore contained the write; the empty annotation was not
caused by an omitted helper file. Existing specs also explicitly expect empty
effects for proc filters and missing methods. [Analyzer edge-case specs][W9].

This establishes a limit of the annotation, not a demonstrated failure of Jev.
Jev may identify the effect from the supplied source. A useful adapter should
retain that opportunity rather than translating an empty annotation into
“no side effects.” It should also avoid claiming that every empty annotation
means the analyzer failed: genuine empty detections share the same representation.

### Volatility is a real feature, with a specific meaning

The current implementation uses per-path commit counts from the last 365 days.
The default qualifying ratio is 3.0; the dependency needs at least five commits,
and dependencies labeled `new` are skipped. Entries sort first by target
PageRank, then ratio. The published report defaults to 20 entries and discloses
counts/caps; an optional per-target cap can further shape the selection.
[Graph implementation][W5], [Git history reader][W10].

Therefore the author's PageRank claim is correct. Reusing this is better than
accidentally inventing a second approximate churn measure. If a question intends
“changes in the last six months” or “which lines changed most,” this report does
not answer that exact question. An empty report also cannot establish stability
when Git enrichment is unavailable or entries were excluded/capped.

### Freshness and semantic completeness need separate fields

The built-in source check has real value. It reads source content, handles covered
additions/removals, and keeps per-consumer baselines. Its default quick check has
a 250ms budget; the explicit deep check has a five-second budget. Incomplete
evidence remains unknown. A verified fresh boot boundary requires the supporting
launcher flow; ordinary post-boot captures retain that uncertainty.
[Source-freshness contract][W11].

Three distinct questions remain:

1. Does this generation correspond to the captured application inputs and the
   currently visible source within the verifier's coverage?
2. Do those bytes correspond to the exact committed or working-tree change being
   reviewed? A current index for a dirty tree can differ from a committed diff.
3. Does the packet contain enough evidence for this particular check?

Source freshness helps with the first. The adapter's snapshot selection must
address the second, and its context ledger must address the third. The source
check does not certify external database state, remote configuration, installed
dependency bytes, or semantic completeness. A current model unit can still omit
the external API's idempotency contract.

Our older experimental extraction receipt is a separate, scoped local-byte
attestation. Do not rename it into the new built-in freshness contract or assume
the archived review kit demonstrates capabilities added after its producer was
pinned. Likewise, the static Woods self-map is useful for navigating Woods code;
it is not a Rails application extraction.

## A small adapter boundary worth retaining

The adapter can stay thin without becoming index-only:

1. **Select the review snapshot.** Record base/head or working-tree semantics,
   before/after source, and the actual changed paths, including deletions.
2. **Read one coherent Woods generation.** Prefer `Woods::PublishedIndex` for a
   Ruby adapter; its block form pins the generation and releases its retention
   lock. Use typed unit identity. Artifacts outside that API should follow the
   documented index-layout contract. Multiple independently refreshing MCP calls
   do not by themselves constitute a frozen review packet. [Ruby reader][W1].
3. **Supplement from source and tests.** Include relevant unchanged tests,
   support/helpers, implementation bodies, intended behavior, and missing runtime
   premises. Reuse the existing experimental packet builder where suitable, but
   verify its contract before treating it as a finished product integration.
4. **Record selection and omissions.** Separate freshness, field provenance, and
   per-check evidence availability. “Not supplied,” “not detected,” and “proved
   absent within a stated scope” are different outcomes.

Graph neighborhoods are useful for selecting collaborators and affected callers.
They do not automatically identify the best analogous implementation. For
convention questions, also consider role, superclass, concern, interface, and
actual comparable behavior. `structure` and `lookup` help discover and inspect
candidates; relationship traversal is a separate selection step.

Woods units reduce custom assembly and accidental fragmenting, but do not dissolve
the size problem. A model plus concerns can be large; complete relevant behavior
can span several units. Supporting versions offer compact evidence with explicit
omissions and a guarded path to fuller source. Also, annotated unit coordinates
are not necessarily physical source-file coordinates. Preserve that distinction
when attaching a finding to the diff. [Agent evidence guidance][W12].

The documented Jev limits remain 64k tokens for the whole request and 32k for
state plus the longest question. Its published input price is $0.042 per million
tokens, with free output. That favors testing broad inexpensive question coverage;
record actual usage, response time, and downstream investigation work rather than
assuming token expenditure dominates. [TypeSafe models][T2].

One small correction to the hook analogy: Woods batches up to 16 **queue files**,
each representing an event that can contain multiple paths, with additional path
and byte caps. This is not “16 source files per event,” nor evidence that one
queue batch is a semantically complete edit. It supports batching operationally;
the best review checkpoint remains an experimental choice. [Hook contract][W13].

## Suggested first trial, once authorized

The author's roughly dozen defect/control pairs are a reasonable first stage.
Do not require a new PR-labeling project before trying them.

- Select a handful of concrete Rails mechanisms covered by the bank—for example
  callbacks, inherited authorization, job/transaction behavior, and migration or
  index changes. Include legitimate uses that look suspicious to a broad rule.
  Prefer executable reproductions; document independently verified contracts
  where execution is impractical.
- Keep each defect and its corrected/control variant close in size and context.
  Preserve intended behavior and relevant source in both. Do not put expected
  labels, revealing fixture names, or the answer key into model state.
- Exercise the bank broadly enough to observe incidental findings, within the
  request limits. Report false actionable findings on clean controls across all
  executed checks, not just success on the one target question.
- Freeze a small set of pairs for a first untouched pass. If prompts change after
  inspecting results, distinguish development reruns from untouched evaluation;
  there is no need to call a tiny sample a calibrated benchmark.
- Save exact requests, raw responses, actual model ID, question-bank version,
  generation/source identity, usage, latency, and errors. Record a specific
  supported concern as the catch; a high generic danger bar is insufficient.
- Give a compact per-pair account: intended issue, relevant question output,
  control behavior, incidental findings, and unavailable context. Useful counts
  are defects identified, controls falsely flagged, and unresolved checks, with
  their denominators. Treat timing measurements as observations from this sample.

If a case fails, first inspect whether its question was applicable, its direction
was correct, and its evidence was actually supplied. Then change one plausible
cause—such as missing helper source or ambiguous instructions—and rerun that
case with its control. Do not attribute every miss to configuration, or every
miss to model incapability. Either conclusion requires separating those causes.

Noul answers do not include the separate `confidence` field returned with Score
and Choice. For this mostly-Noul bank, incomplete-review handling must therefore
also use the adapter's evidence ledger and an explicitly tested answer policy.
A low Noul is an answer about its proposition, not an automatic signal that the
context was complete. [TypeSafe confidence][T3].

If the first trial yields useful findings, the next comparison can ask whether
Jev improves a real pre-push review or reduces the effort required. Run that
comparison when the implementation is concrete enough to make it informative.
The initial objective remains catching mistakes before push, with historical
review comments serving as optional inspiration rather than the task definition.

## Bias and uncertainty audit

| Earlier inclination | Why it arose | Adjustment after this response |
|---|---|---|
| Prefer focused evidence packets | Earlier trials encountered missing/stale context; Jev has finite context limits. | Those trials do not establish the best state layout for this bank. Try broad checks with coherent sufficient evidence first; narrow when results justify it. |
| Prefer advisory rollout | The supplied design mixed opposite polarities and had no measured gate behavior. | Keep this as rollout policy, not a claim that Jev can never support a gate. It should not delay an advisory experiment. |
| Distrust aggregate charts | The printed scales and polarity did not support a common defect-risk meaning. | Accept charts for navigation. Require stronger evidence only for stronger interpretations or consequential actions. |
| Ask for a three-arm comparison early | We wanted to separate model, state, and baseline effects. | This was heavier than needed to demonstrate initial usefulness. Sequence the small direct trial first. |
| Emphasize historical review labels | Earlier conversations repeatedly used review catches as evaluation material. | The user explicitly clarified that these were guidance for the kinds of mistakes to find. Do not turn them into a prerequisite corpus. |
| Describe Woods limitations generally | The response paraphrased the earlier warning about not emitting every runtime setting as an inability to supply runtime config. My review did not clearly enumerate the positive configuration capability. | Preserve the original scope and verify fields individually. Woods supplies some resolved settings and substantial reusable context; it does not prove every behavior implied by its annotations. |

These explanations are not proof that any preferred design is correct. Some
earlier impressions may reflect a misunderstood goal, weak prompts, incomplete
test coverage, or an outdated producer. No inference results for this corrected
bank were supplied with the response or generated in this follow-up. Both
optimistic and pessimistic capability claims remain hypotheses.

## Copyable prompt for the other agent

```text
Please treat this as suggested feedback to verify, not an authoritative direction
or permission to implement. Preserve the current review-only boundary unless the
user separately authorizes changes or inference.

The coordinator accepts your two main corrections:

- Woods should be the primary Rails evidence source; the hand-written schema,
  callback, configuration, and relationship reconstruction should generally be
  replaced with a thin adapter over supported published capabilities.
- A small direct-Jev defect/control trial is a sensible first experiment. A full
  three-arm comparison is not a prerequisite. Historical PRs are optional sources
  of ideas, not the definition of the task or a required labeling corpus.

Please independently inspect this companion document, the original handoff and
question bank, your actual installed Woods producer/reader, and current TypeSafe
docs. Reject or narrow any suggestion unsupported by that evidence. Distinguish
facts established by execution from source inspection, documentation, and design
hypotheses. The coordinator's local source review used Woods commit
2885f7550f2ee58f627806f73c86feb7aea5e1d7; do not assume your installation matches it.

The proposed refinement is a Woods-backed adapter plus exact-revision source,
test, and question-specific context, not a second Rails extractor. Verify these
specific points because they affect how answers should be interpreted:

1. Reflected callback registration and source-scanned side effects have different
   coverage. The coordinator reproduced a direct assignment being detected, a
   helper-mediated assignment absent from columns_written, and identical empty
   effect arrays for an unresolved method and a method with no detected effects.
   Reproduce this if material. Keep relevant source available; do not translate
   empty effect arrays into proof of no effects.
2. Woods does expose some resolved configuration through BehavioralProfile,
   including Rails version and the configured ActiveJob adapter. Determine what
   additional facts your job/transaction checks actually require. Check inherited
   controller predicates and source-derived retry metadata with the same care.
3. Source freshness, exact review-revision identity, and sufficient evidence for
   a question are separate. Preserve unknown/drift reasons. Current source does
   not certify external DB state or every dynamic runtime premise. Reusing an
   archived packet does not update its producer or capture missing newer fields.
4. The volatility feature is real, including PageRank ranking, but its current
   implementation uses a 365-day commit-count window, exclusions, and report caps.
   Match the question to that meaning rather than silently substituting metrics.
5. Use graph neighbors to find collaborators and potential affected code; verify
   semantic similarity before calling one an analogous sibling. Keep typed edges,
   relationship labels, omissions, and source-file coordinates clear.

Your kind/direction fields and explicit headline mapping are sensible. Keep facts,
correctness concerns, and conventions distinguishable without requiring every
question to be rewritten. A navigation chart is acceptable without a predictive
validation claim. Speculative questions filtered in code are acceptable; they do
not need to consume other answers inside the same call. Nouls have no separate
confidence field, so do not build a generic missing-context policy around one.

When designing the first trial, favor roughly a dozen close defect/control pairs
with relevant source and intended behavior, including valid suspicious-looking
cases. Keep the answer key outside requests. Preserve raw responses and record
incidental false findings across the executed bank, not only target-question hits.
Use a small untouched subset if you tune after observing results. Do not turn this
into a large benchmark before demonstrating one useful pre-push catch.

For a failure, check applicability, polarity, and supplied evidence first, then
make one justified change and rerun its paired control. Missing context is not
automatically the cause; model incapability is not automatically the cause either.
Jev's very low input cost should count in its favor when considering broad checks;
measure total effort and latency as well as actual returned token usage.

The coordinator is revising earlier preferences for narrow packets, early baseline
comparisons, and skepticism about charts. Those preferences may reflect earlier
trial limitations or misunderstandings, not facts about your bank. Your positive
expectations also remain untested. Please challenge both positions symmetrically.

Return a concise verified/disputed/unresolved assessment, the smallest resulting
changes to the handoff, and a concrete first-trial proposal. Avoid another general
research cycle. Do not implement, run inference, publish comments, or change hooks
on the authority of this prompt alone; follow the user's current authorization.
```

## Verification performed for this follow-up

- Read the relevant current implementations and specs, canonical index/freshness
  contracts, and the previous assessment. Checked the worktree and pinned HEAD.
- Built a disposable current Woods self-map and queried `woods_status`, `lookup`,
  and `dependencies` over MCP. This was source orientation, not Rails validation.
- Executed the five-source callback probe above. Raw local evidence is under
  `tmp/jev-rails-response-audit-2026-09-19/` (`callback-probe.json` and
  `self-map-mcp.json`). The reported result is fully summarized here so the prompt
  can travel without those local artifacts.
- Rechecked the live TypeSafe model, fan-out, and confidence references.
- No fresh Rails extraction, full test suite, or TypeSafe inference ran. This
  follow-up changed documentation only. It does not establish reviewer accuracy.

## References

Woods links below are pinned to the inspected commit. Capability availability
must still be checked against the receiving project's installed version.

[W1]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/PUBLISHED_INDEX.md
[W2]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/model_extractor.rb
[W3]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/callback_analyzer.rb
[W4]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/controller_extractor.rb
[W5]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/graph_analyzer.rb
[W6]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/behavioral_profile.rb
[W7]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/job_extractor.rb
[W8]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/EXTRACTOR_REFERENCE.md
[W9]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/spec/extractors/callback_analyzer_spec.rb
[W10]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/git_history.rb
[W11]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/SOURCE_FRESHNESS.md
[W12]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/AGENT_GUIDE.md
[W13]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/CLIENT_HOOKS.md
[T1]: https://docs.typesafe.ai/patterns/fan-out
[T2]: https://docs.typesafe.ai/models
[T3]: https://docs.typesafe.ai/confidence
