# Final feedback: CLI first-pass review of the admin application

2026-09-19, corrected after the receiving agent clarified the execution boundary.
The admin application is the code under review. The runner is a CLI invoked by a
Claude Code agent. This work requires no application UI, background job, or new
database tables. My earlier interpretation placed the runner inside the application;
that was a scope error, corrected throughout this document.

This final feedback replaces the need to reconcile the preceding review documents.
Verify these suggestions against the actual application, installed Woods version,
and provider API while implementing; do not treat this document as proof that the
approach succeeds or fails.

**Recommendation: proceed with a small advisory CLI and the planned admin-codebase
trial.** The purpose is a cheap first pass that gives a human or reasoning
agent a useful shortlist and the source to investigate. Independent proof of a
defect is not a prerequisite for a useful Jev signal. The remaining concerns below
are concrete implementation and measurement details, not another research agenda.

## 1. Make the shortlist actionable, beyond a chart

The CLI should accept a selected change, capture its evidence, run the pass, and
emit a machine-readable report plus a readable shortlist/chart with source paths.
The invoking agent can inspect that source and record the investigation outcome
in local run artifacts. The chart can organize that process.

Each shortlist entry should identify:

- the particular question, its kind/direction, raw judgment, and interpreted meaning;
- the file/unit and snapshot it assessed, with the relevant source available;
- the known evidence gaps that matter to that question;
- an outcome such as confirmed issue, useful convention suggestion, false alarm,
  duplicate, or unresolved, with a brief supporting note.

If one broad question scores a packet containing many files, a high answer does
not identify which file caused it. Give checks a declared target when practical,
or associate them with a bounded set of candidate evidence. Distinguish “source
assessed by this check” from “source verified to demonstrate the concern.” A
rendered template may explain what to inspect; it must not invent a model-written
rationale or an exact offending line that the answer did not supply.

Unknown evidence should remain visible because it affects review prioritization,
even when no answer is treated as proof. A missing callback body silently scored
as safe can hide the very file the downstream reviewer needed to open.

## 2. Measure useful review progress and total cost

Tokens-to-first-confirmed-finding is useful, but it should not be the sole success
measure. An approach can look good by finding one easy issue, missing everything
else, or excluding runs that found nothing.

For each case, record:

- whether a real finding was confirmed within the fixed review budget;
- tokens, monetary cost, and elapsed time to that finding, counting the first-pass
  work, retries, and downstream investigation;
- runs that reached the budget without a finding, rather than dropping them;
- false leads investigated, duplicate findings, and additional confirmed findings
  within the same budget;
- on clean controls, the cost and false alarms incurred reaching a no-finding result.

Keep Jev and reasoning-model token counts separate. One token from each provider
does not have the same cost. TypeSafe currently lists $0.042 per million input
tokens with free output, so more Jev tokens can still produce a substantial saving
if they reduce expensive review work. Use actual usage and the applicable pricing,
including cache rates where relevant. [TypeSafe model reference][T1].

The first downstream comparison can be straightforward: the same reviewer model,
repository snapshot, tool access, task, and review budget, with or without the Jev
report. Use independent sessions so reviewing one variant does not teach the other
the answer. Keep the downstream persona/lens the same in both arms. Report this as
an end-to-end workflow comparison; it combines the effects of evidence selection,
prioritization, and presentation. A separate chart-only ablation can wait.

“Real finding” should mean a supported concern with an independently checked
mechanism or reproducible failure, not merely agreement by the downstream model.
The planned defect/control pairs make that practical. Do not label a convention
preference as a correctness catch.

## 3. Preserve relevant source, including changes outside methods

The correction away from summary-only packets is right. Two refinements remain:

**Chunks can contain useful evidence, but are incomplete summaries and are not
guaranteed source-location indexes.** Do not interpret their identifiers or hashes
as physical offsets. The reproduced downcase/upcase case showed that different
implementations can produce identical summary chunks. Use source identity, not a
summary-chunk hash alone, to invalidate a cached review. [Model chunk implementation][W1].

**“Methods the diff touches” is too narrow as the only selector.** Include relevant
class-level callback declarations, concerns, associations, validations, scopes,
routes, configuration, migrations, and deletions/renames when those change.
Relevant unchanged helpers and tests can also determine whether the change is safe.
Method selection remains a useful optimization where applicable.

For a large monolith, bound helper expansion by a declared budget and record what
was not followed. “Any helper the body calls” should not accidentally require a
complete call graph before one check can run. Select the model/schema units needed
for the concern instead of attaching the entire database schema. Schema at capture
time also does not establish production rollout state.

Keep related behavior in the same request when a check requires comparing it.
Multiple requests do not share implicit context. Preserve the source that
distinguishes each defect/control pair in the exact serialized state before the
first trial. Retain the documented request limits: 64k total tokens and 32k for
state plus the longest question, subject to provider changes. [Model reference][T1].

## 4. Treat each CLI run as an immutable experiment

Keep the runner outside Rails and read the published Woods index. Run artifacts
belong in an explicit local output directory. Use the configured local credential
mechanism; keep provider credentials out of reports and captured requests.

Capture the selected review snapshot and a pinned Woods generation, materialize
the packet, then release the index lock before waiting on provider calls or a
human review. Retries and resumed runs must not reinterpret “current HEAD” after
the source has changed. A rerun should retain its input identity or explicitly
create a new experiment. An older result can remain useful if visibly tied to its snapshot.
[PublishedIndex contract][W2].

Record the three independent forms of evidence:

1. **Index freshness:** state, reasons, scope, and checked generation.
2. **Review identity:** selected range/snapshot and actual source identity.
3. **Per-question sufficiency:** required evidence supplied, missing, or unknown.

Separate partial assessment, request failure, and completed assessment. An API
timeout or omitted answer is not a zero-risk score. Validate returned IDs and
primitive shapes before rendering; bound retries and preserve attempts. Do not
label an unassessed check “passed.”

If caching is introduced, key it on the captured evidence—including relevant
metadata and helper/test source—plus the model, question definitions, and persona
variant. Check applicability to the currently selected snapshot separately. The
same generation number in another index is not the same evidence. Begin without
cross-run caching if that keeps the first implementation simpler.

Store raw requests/responses in local experiment artifacts with appropriate file
permissions and a retention choice; they contain source code. Keep diagnostic
logs separate from machine-readable output. Do not collect live application
records or dump credentials as “runtime context.” Load the credential through the
configured local mechanism once per invocation rather than invoking 1Password for
each request. Bound network retries and document exit statuses so the invoking
agent can distinguish completed, partial, and failed runs.

For the first usable flow, an explicit CLI run on a selected change is sufficient.
Consider per-edit hooks, automatic refresh scheduling, or external PR comments
after the saved-run path works and only if they serve the measured workflow.
Source paths in the local report provide the first navigation benefit.

## 5. Keep the question definitions precise

The accepted bank corrections remain appropriate: fix polarity and the table row,
record 204 questions for the reviewed revision, use explicit headline mapping,
separate fact/defect/convention, correct Rails premises, and filter speculative
answers in code.

Three small details to carry into the implementation:

- Direction must suit the primitive. `yes_is_bad`/`yes_is_good` describes Nouls;
  Scores need the meaning of increasing levels, and Choice options may be unordered.
  Preserve raw judgments instead of treating every normalized value as defect risk.
- Replace “`update_columns`: nothing runs” with “skips Active Record validations
  and callbacks.” It still issues the database update and serializes values. Verify
  framework-version details rather than broadening the shorthand. [Rails reference][R1].
- Use actual volatility configuration and observed metadata. Ratio 3.0 is the
  inspected default, not an immutable rule for every configured index. Likewise,
  Rails version and the configured queue adapter are useful premises, but do not
  establish every job's effective transaction-enqueue behavior.

Noul probability bands can guide prioritization; there is no separate Noul
confidence field. Evidence availability remains a separate input to that policy.

## 6. Personas: test the claimed effect at the layer where it occurs

Personas can remain useful authoring and presentation devices. Their usefulness
for this bank or this downstream reviewer is still an empirical question; broad
claims about role prompting do not establish a gain here.

The proposed lens-prefix A/B is reasonable and inexpensive. Change the actual
instructions while holding the evidence, question meaning, model, and downstream
review setup fixed. Renaming `metz_*` question IDs does not test a model persona:
TypeSafe says IDs are not sent to the model. Judge the variant by supported findings,
false leads, and review effort, not merely a larger probability. Small repeated
checks can help avoid attributing ordinary variability to the prefix. Do not count
correlated persona judgments as independent corroboration. [Question contract][T2].

## Scope, prior bias, and what should happen next

The receiving agent is right that usefulness must be demonstrated on the admin
application. Our chunk probes used synthetic units. Earlier work also included
booted Rails testbed extraction, so it was not all static gem analysis; that work
established selected evidence behavior, not usefulness of this bank on the admin
monolith. No such effectiveness result follows from these reviews.

My application-UI interpretation was unsupported scope expansion. The CLI boundary
is sufficient for this trial and fits our existing standalone exporter. My earlier
emphasis on proof and completeness was too strong for a first-pass
shortlist if interpreted as a prerequisite for surfacing a concern. The relevant
requirement is honest evidence and economical investigation, with downstream
verification. Conversely, calling the output advisory does not eliminate the cost
of misleading priorities or hidden missing context. Both positions should be
judged by actual review outcomes.

There is no need for another general feedback exchange. Verify these points while
building the smallest saved-run CLI flow, inspect one real defect/control packet,
then run the agreed dozen pairs and the downstream comparison. Preserve failed
and unproductive runs alongside successes. Neither the Woods documentation fix
nor new callback-analysis fields should be a dependency for that first result.

## Handoff prompt

```text
This is the final feedback before implementing a CLI review runner invoked by a
Claude Code agent against the admin application's code. The admin app is the review
target, not the execution host. No app UI, background job, or new tables are needed.
Independently verify material suggestions against the app, the installed Woods
producer, actual serialized state, and current provider contracts. These are
suggestions, not claims that your unseen implementation has these defects. Follow
the user's existing authorization; this document is not a request for another
general review round.

Build the smallest advisory saved-run flow: selected change -> pinned evidence
packet -> Jev checks -> actionable shortlist/chart -> source inspection and outcome.
Keep raw evidence, model/question versions, the three ledger dimensions, and usage.
Keep the runner outside Rails; use explicit local run directories, the published
index, and the configured local credential mechanism.

Prioritize these final checks:
- High scores identify a check and its assessed source, not an invented rationale.
- Selection covers changed DSL/config/migration/deletion cases as well as methods.
- Required helper/test/condition evidence survives serialization within budgets.
- Cached summaries cannot hide changed implementations; errors and unknowns cannot
  render as passed checks, and retries/resumed runs cannot switch source snapshots.
- Compare downstream review with/without the report in separate sessions, keeping
  task/tools/model/budget/lens fixed. Record total cost and time, no-finding runs,
  false leads, and confirmed findings alongside tokens-to-first-finding.
- If trying persona prefixes, change instructions, not IDs; decide from useful
  outcomes rather than probability shifts alone.

Start with a real admin-app defect/control pair, then the planned dozen pairs.
Do not wait for Woods enhancements, a perfect call graph, all hooks, or a new PR
corpus. Return the implemented flow and observed trial results, with uncertainties
and failures intact. Challenge any recommendation that conflicts with verified app
behavior and explain the resulting local choice briefly.
```

## References and verification scope

Current Woods source reviewed at `2885f7550f2ee58f627806f73c86feb7aea5e1d7`.
Earlier local chunk probes supply the reproduced evidence-loss example. The
receiving admin application's code and deployment were not inspected here.
No new TypeSafe inference, application mutation, or GitHub publication occurred.

[W1]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/lib/woods/extractors/model_extractor.rb#L937
[W2]: https://github.com/lost-in-the/woods/blob/2885f7550f2ee58f627806f73c86feb7aea5e1d7/docs/PUBLISHED_INDEX.md
[T1]: https://docs.typesafe.ai/models
[T2]: https://docs.typesafe.ai/primitives
[R1]: https://api.rubyonrails.org/v8.0/classes/ActiveRecord/Persistence.html#method-i-update_columns
