# Jev screening on two pinned Woods PRs

Completed 2026-09-19. This is a bounded development experiment, not a shipped
reviewer or an evaluation of the admin application's Rails question bank.

## Outcome

Broad contract-aware screening identified both known faulty implementations and
selected relevant source locations. Focused questions were not consistently
better: they missed GraphQL ownership and callable-identity defects at the frozen
threshold, while detecting unstable mailer action ordering.

On the proposed mailer code, broad screening still raised a determinism concern
and selected `SharedUtilityMethods#stable_filter`. Investigation of that lead
reproduced an additional, pre-existing object-callback serialization gap. This is
a useful example of cheap screening guiding a reviewer to a real problem, with
important attribution limits: Jev supplied a probability and location, not a
causal explanation; the coordinator found and executed the specific mechanism.

Twenty-four requests cost an estimated **$0.003710448**. No downstream reviewer
comparison was run, so no total-cost or review-time advantage is established.

## Source and evidence boundaries

| Case | Common baseline | Proposed revision |
| --- | --- | --- |
| [GraphQL ownership, #485](https://github.com/lost-in-the/woods/pull/485) | `2885f7550f2ee58f627806f73c86feb7aea5e1d7` | `d3f423eaf80e984da3b2dbf9120032c5f4d57cfc` |
| [Mailer determinism, #487](https://github.com/lost-in-the/woods/pull/487) | same | `a7e6fc6371200fb1a8def7a916063930b274e372` |

The PRs moved during the trial; all requests and tests retained these exact
commits. Three detached worktrees and three fresh static Woods self-maps were
created outside the main checkout. `PublishedIndex` pinned generation 1 of each
map while checking selected units. Exact physical method definitions and file
declarations came from Prism source locations, with complete supporting helpers.

Woods **does** have a static index for itself. It supplies ownership and source
structure, but does not provide a booted application's schema, runtime callback
chains or resolved filters. No such Rails runtime evidence was asserted in these
requests. The separate executable mailer checks booted Rails 8.0.5.1.

Packet preparation recorded revisions, source-file SHA-256 values, generation
numbers and selected index-unit hashes. Captured source bytes were checked again
before inference. This verifies the selected source snapshots; it is not a claim
that built-in application source-freshness checks or an automated whole-app
evidence adapter were exercised.

The coordinator selected relevant methods after reading the fixes. The contract
and supporting material are therefore curator-informed. Both prompt profiles
received identical state within a condition. Jev saw no PR title/discussion,
issue narrative, regression tests, answer key, Git revision or counterpart
snapshot. Ordinary code comments remained. Omitted helper implementations and
absence of runtime/tests were disclosed. This is not blind repository discovery.

## Frozen comparison

Two families × three source conditions × two question profiles = 12 requests;
each request was repeated once in a seeded order, for 24 calls and 96 judgments.
Repeats are not independent defect examples.

Conditions: baseline source, proposed source, and proposed source plus its actual
implementation diff. In the diff condition, instructions explicitly ask about
defects remaining or introduced in the proposed code, not removed faulty lines.

The broad profile asks four independent Nouls: contract correctness,
cross-process determinism, unintended callback/default execution, and attribution
to the wrong entity. Each focused profile asks two specific contract questions.
All use yes-is-bad polarity. An exploratory **0.70** threshold selects advisory
leads; it is not a calibrated probability boundary or merge gate.

Every request also independently asks a Choice of the first source span to
inspect, with a `none` option. This Choice cannot read parallel Noul answers and
asks the same broad contract-localization question in both profiles. Its output
must not be described as a reasoning chain from the focused questions.

## Observed probabilities

Ranges below cover the two repeats. These are selected dimensions; raw artifacts
preserve the entire executed bank, including all low scores and no-match results.

| Question | Faulty baseline | Proposed code | Proposed code + diff |
| --- | ---: | ---: | ---: |
| GraphQL: broad correctness | .76–.77 | .40–.42 | .34 |
| GraphQL: broad wrong-entity attribution | .74–.78 | .50–.52 | .42–.44 |
| GraphQL: focused unrelated parent | .44–.49 | .15–.17 | .17–.18 |
| GraphQL: focused implicit/interface parent | .24–.27 | .19–.20 | .17–.18 |
| Mailer: broad determinism | .82–.85 | .77–.78 | .67–.70 |
| Mailer: focused Proc identity | .40–.41 | .28 | .30–.31 |
| Mailer: focused action ordering | .81–.83 | .23–.29 | .27–.30 |

GraphQL baseline localization selected its regex-based `extract_parent_class` in
both profiles and repeats. Proposed GraphQL conditions selected `none` throughout.
Mailer baseline localization selected `annotate_source`; proposed conditions
selected the shared `stable_filter` throughout. Location choices were repeatable;
their probabilities/confidence and the Noul probabilities varied.

The proposed mailer diff condition crosses the .70 boundary between repeats,
despite unchanged input. A rigid threshold would route one run and suppress the
other. A fixed investigation budget/ranking may be preferable; this trial did not
compare those policies. Keep raw values and uncertainty visible.

No other broad dimension reached .70 apart from correctness and the target
attribution/determinism dimensions. Broad correctness also reached .70 in one
proposed-mailer repeat. We did not presume the proposed files were globally clean:
only specific regression mechanisms had passing controls.

## Executable checks

All ran in detached snapshots with Ruby 4.0.6. Regression tests from each proposal
were overlaid onto the baseline as test-only files; production source stayed at
the pinned revisions. The tests are supplied by the PRs, not independent hidden
oracles. No test output or fixtures went to Jev.

| Check | Baseline | Proposed |
| --- | --- | --- |
| GraphQL parent-ownership unit regression | 11 examples, 10 failures | 11 examples, 0 failures |
| Independent-process mailer Rails regression | 3 examples, 3 failures | 3 examples, 0 failures |
| Proposed mailer unit suite | not run as a paired arm | 40 examples, 0 failures |

The mailer integration suite exercises independent roots/processes, preserved
literal/default/callback values, callable-kind changes, and published full versus
incremental results through MCP. These runs do not establish every supported
Rails version. No examples were pending or failed outside the examples.

## Additional confirmed gap

After the primary capture, coordinator inspection of the selected helper found
that `stable_filter` only normalizes Proc instances. A supported object callback
passes through and later becomes an address-bearing `to_s` value.

Two independent Rails boots of the proposed implementation emitted different
`MailerAuditCallback` addresses in callback metadata. A separate standalone
reproduction confirmed this again, and normal mailer processing was shown to
invoke that object callback. Extraction itself did not invoke it. Source hashes
remained equal; metadata instability is the measured effect.

The affected files match subsequently observed main
`287d1d29117b9890ce02a2f1a95cf978925b7d04`. This gap predates #487; its Proc fix did
not introduce it. The broad concern is therefore not safely counted as a false
alarm, but neither can we know that Jev internally recognized this particular
mechanism. See the focused [bug report](2026-09-19-mailer-object-callback-reproduction.md)
and [standalone reproduction](../../../script/typesafe/probes/mailer_object_determinism.rb).
No new issue, PR comment or production fix was created.

## Cost, latency and retained artifacts

All 24 calls returned HTTP 200 and passed the existing strict Choice/Noul response
validator with model `jev-1.13.0`. There were no retries and one in-memory
1Password retrieval for the batch. No credential is saved in request artifacts.

- Input: **88,344** tokens; output: **3,848** tokens.
- Estimate at $0.042/M input and free output: **$0.003710448** for both repetitions;
  a single pass costs half that, **$0.001855224**.
- HTTP median: **0.417 s**; nearest-rank p95: **0.516 s**; summed HTTP time: **10.543 s**.
- Batch timestamps: `2026-09-19T21:42:40Z` through `2026-09-19T21:42:52Z`.

The [model reference](https://docs.typesafe.ai/models) documents the rate and
context limits; these costs are usage-derived estimates, not invoices. Preparation,
source selection, manual investigation and regression execution are outside HTTP
timings. Request sizes were bounded at 28,000 UTF-8 bytes as a conservative
admission heuristic, not billed-token measurement; actual usage is retained.

Artifacts: `tmp/typesafe-pr-trial-2026-09-19/` contains the frozen protocol, source
receipts, exact requests, raw responses, capture ledger, summaries, regression
JSON/logs and the follow-up reproduction. `freeze.json` binds preparation,
protocol, schedule, capture code and requests; a final validation rechecks those
hashes. Temporary worktrees/maps are under `/tmp/woods-jev-pr-trial-2026-09-19/`.

## What this changes

Keep broad contract questions as candidates alongside focused questions: this
trial contradicts a blanket preference for narrower wording. Do not interpret a
missed Noul as proof that useful localization is unavailable. Conversely, typed
answers and useful locations do not remove the need for executable confirmation.

The next informative product trial remains a Woods-indexed Rails application,
with real pre-push changes and a downstream agent consuming the shortlist. Measure
all investigation effort and missed issues, including runs with no finding. The
existing admin application pilot can supply runtime context that the gem's static
map cannot. Historical PR-comment mining is unnecessary for that workflow.

The requested separate review/CI repository is recorded as **B-204** in
`docs/backlog.json`. It is a backlog item; no repository was created. General
extraction improvements stay in Woods, while the future optional companion owns
Jev orchestration and review policy. Findings remain advisory.
