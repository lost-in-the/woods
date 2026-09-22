# Woods-backed review: completed follow-up and booted Rails pilot

Completed 2026-09-21. **Runtime Woods evidence improved Jev's prioritization on
the application fixtures. The first downstream comparison found no advantage
over the ordinary agent. Known-bug replays did not support automatic fix
verification.** These are separate findings; none establishes a general limit on
TypeSafe or a production review policy.

No new Woods defect was independently reproduced in this round, so no new GitHub
issue was filed. The four application defects below were deliberately constructed
fixtures, not discoveries in the user's application or the testbed's existing code.

## Revisions and completed scope

- Woods producer/reviewed main: `904226c91b36a6656e3d6ab7ff2de3f74a9cdc23`.
- Original defective release: `84fc59c18047870a7b45e6da049064ff78427e93` (beta3).
- Testbed source: `99c349c087b43ce6535f609ac1af506ede278320`.
- TypeSafe: requested and returned `jev-1.13.0`.
- Application runtime: Ruby 3.3.1, Rails 8.0.5.1, SQLite, ActiveJob test adapter.
- Fresh reviewer processes used the local CLI configuration, `gpt-5.6-sol` with
  low reasoning effort. The CLI usage events do not independently attest the
  backend's resolved model identity.

The three earlier bugs are closed through [#493](https://github.com/lost-in-the/woods/pull/493)
and [#494](https://github.com/lost-in-the/woods/pull/494). The original reproductions
and related suites passed 165 examples before this round. No production code,
release state, default inference dependency or public tool schema changed here.

The work completed the two remaining release-scan checks, replayed the known
bugs/fixes, added explicitly labeled diagnostic refinements, and compared
diff-only versus runtime-index evidence on a booted application. It also ran
separate ordinary and shortlist-assisted reviewers with recorded usage.

## The two remaining release-scan items

### TraceEnricher

The earlier .72 file-level lead was investigated against complete implementation,
the runtime tracing contract, and the real thread/fiber/method-identity fixtures.
The documented behavior deliberately identifies the nearest observed Ruby method,
excludes native/block frames and other threads, and does not promise an exhaustive
call graph. Instance/singleton identity, inherited defining owners, unknown callers,
exception unwinds and independent fiber stacks have executable coverage.

The trace implementation and Console server suites passed 53 examples together.
No additional concrete defect was established. The enriched Jev response failed
strict distribution-sum validation (.99 total), so it is not counted as a valid
negative verdict. Its scalar judgments remain in the raw record.

### Console tool specifications

Three byte-identical repeats of the previously invalid `r0090` request returned
two valid responses and one repeat of the winner inconsistency: selected .36 while
another option had .37. The two valid responses had correctness .40/.42 and
context-gap .72. The original invalid response remains unchanged in the original
experiment; later repeats do not retroactively repair it.

Full tool specifications, server registration and tests were supplied in a
separate enriched request. Source tracing distinguished supported modes from
inventory-only schemas. Another 73 specification/input-contract/matrix examples
passed. No supported-mode defect was reproduced. This closes the bounded follow-up
investigation, not every possible Console behavior.

## Known bugs versus fixed source

The same broad question wording was retained. Both versions received identical
packet structure and common beta3 tests, with only implementation bytes changing.
Fix titles, new regression tests, execution results and before/after labels stayed
outside requests. Three repeats per version were recorded; unchanged text-preparer
and version files were controls. This packet form differs from the original
release-diff experiment, so compare within this round rather than attributing
cross-round score changes to the fixes.

Broad scores barely moved:

| File | Median substantive maximum before | After |
| --- | ---: | ---: |
| FileStore, containing the clear and expiry defects | .52 | .52 |
| JsonSnapshotStore, containing the malformed-unit defect | .57 | .57 |

This does not mean the patches failed: executable regressions already confirmed
them. It means these broad file judgments do not reliably verify those fixes.
The controls are a few examples, not a precision/recall estimate.

### Explicitly posthoc contract diagnostics

After observing weak separation, three specific contract questions were written.
These were informed by the known failures and cannot count as fresh discovery.
Each asks whether the intended behavior holds, so **yes is good**:

| Contract | Median probability it holds before | After |
| --- | ---: | ---: |
| Clear completes for every supported identifier | .91 | .90 |
| Record discards expired history before append | .23 | .92 |
| Listing/new capture tolerate a retained null unit record | .47 | .43 |

The expiry question discriminated the fix; the other two did not. One final,
predeclared refinement used complete method bodies selected by Prism, with tests
omitted and explicit scope limits. It still did not provide reliable verification:
clear scored .78 before/.72 after, and snapshot tolerance .24/.35. Adding the
independently measured `FileUtils.rm_f(nil)` behavior to the clear packet produced
.69 before/.54 after. FileUtils was checked on Ruby 3.3.1 and 4.0.6; both raise.

These refinements change evidence scope and premises, and were selected with
knowledge of the defects. They are diagnostic observations, not isolated causal
ablations or calibrated checks. The planned refinement ended regardless of the
unfavorable result. Executable tests remain the fix-verification mechanism.

## Booted application construction and evidence

Eight disposable copies of the testbed's `rails-8.0-large` template contained four
defect/control pairs. The scale generator was not run: each index had roughly
405–406 units, so this was a small booted Rails fixture, not a monolith benchmark.
The original testbed checkout and database files were left unchanged.

Each candidate had a real local Git revision, migrated private SQLite database,
fresh Rails process, full Woods extraction and pinned `PublishedIndex` block read.
The model packets used full source and selected runtime units, not summary chunks.
Model units supplied schema and concern/callback information; controller units
supplied resolved inherited filters; job source and measured runtime premises
supplied the per-job enqueue setting. All oracle outcomes stayed outside packets.

The first ordinary Rake extractions honestly reported `unknown` with
`unverified_boot_boundary`. Those preliminary receipts were archived. The corrected
run used the `woods-extract full` launcher, yielding **generation 2, deep freshness
`current`, no reasons, and clean candidate checkouts in all eight cases**.
The container's cached bundle lacked the new executable shim, so the identical
launcher was invoked through `bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full`.
No dependencies were upgraded to make the test pass. This is a source-checkout
test invocation, not a replacement installation instruction.

The ledger separately binds source hashes, checked-out SHA, intended candidate
range, producer revision, generation/checksum and evidence availability. Generated
schema was committed locally before extraction. Freshness describes captured
application source; external database truth was established separately by migration
and executable checks. An empty callback annotation was never treated as proof
that a method had no effects.

| Family | Constructed defect | Legitimate control | Executable check |
| --- | --- | --- | --- |
| Callback/concern | `update_columns` changes name without normalizing its companion column | `update!` invokes the concern's callback | Reload and compare the normalized value |
| Inherited authorization | `skip_before_action` exempts private `show` | Only intentionally public `preview` is exempt | Real Rails requests with/without reviewer header |
| Job/transaction | `after_save` queues work before a rollback | `after_create_commit` queues after successful creation | Rollback queues zero; commit queues one |
| Schema | Ordinary index leaves keys non-unique | Unique database index | Duplicate bulk insert rejected by database |

The job explicitly sets `enqueue_after_transaction_commit = false` and uses the
test adapter. This avoids treating all Rails versions/adapters as equivalent.
No claim is made about Sidekiq, PostgreSQL, MySQL or another Rails line.

All eight behavioral checks matched the intended labels. Changes and intent were
visible; opaque candidate IDs concealed labels and pair metadata. The curator
authored both fixture and oracle, so this is not an independently authored holdout.
Supporting files/units were selected with known family knowledge, not discovered
by an evaluated automatic evidence retriever. That bounds any claimed adapter gain.

## Jev: diff-only versus Woods-enriched

Both arms used the same six-question bank: four substantive Nouls, context-gap,
and localization Choice. Three repeats per candidate/arm produced 48 requests.
Ranking used the maximum of the median substantive scores across strictly valid
repeats. Two Woods responses failed strict Choice validation; their candidates
still had two valid repeats. They were not silently repaired or retried.

| Candidate | Diff-only maximum | Woods-enriched maximum |
| --- | ---: | ---: |
| Callback defect | .83 | .895 |
| Callback control | .73 | .26 |
| Authorization defect | .91 | .91 |
| Authorization control | .41 | .14 |
| Transaction defect | .67 | .83 |
| Transaction control | .29 | .62 |
| Schema defect | .70 | .81 |
| Schema control | .27 | .31 |

At the existing exploratory .70 band, diffs surfaced three defects and one control;
Woods evidence surfaced four defects and zero controls. The top-four ranking gives
the same counts. Median model-reported context-gap fell from .715 to .18.
These are eight constructed candidates, not population-level error rates.
The transaction control's risk increased substantially with added context: larger
packets do not uniformly reduce false suspicion.

The diff arm used 27,117 input tokens; the Woods arm used 125,406. Across all three
repeats their estimated TypeSafe costs were $0.001139 and $0.005267 respectively.
Relevant extra context was affordable. There is no evidence here that aggressive
context minimization would be worth losing the callback/transaction distinctions.

## Downstream reviewer comparison

Fresh CLI processes reviewed the same eight independent candidates. Both had the
same full evidence pool, a maximum of four deep candidate packets, a 180-second
instruction budget and a 210-second supervisor cutoff. A helper logged/enforced
packet count. The ordinary agent chose its own order; the assisted agent received
the frozen Woods-enriched ranking. Neither could see oracle outcomes. Recorded
commands showed only permitted candidate/shortlist reads and four helper calls.

| First comparison | Ordinary | Shortlist assisted |
| --- | ---: | ---: |
| Confirmed findings | 4 | 4 |
| False actionable findings | 0 | 0 |
| Deep packets opened | 4 | 4 |
| Time to first subsequently confirmed finding | 19.44 s | 20.11 s |
| Process wall time | 42.67 s | 48.02 s |
| Input tokens, including cached input | 138,210 | 142,952 |
| Cached input, a subset of input | 76,928 | 108,800 |
| Output tokens | 1,574 | 1,549 |

Both selected the four defects and left the four controls unassessed. Thus this
comparison measures useful prioritization under a budget, but does not measure
the agents' false-positive rate when forced to inspect every control. All four
source explanations agreed with the separate executable oracles. One explanation
also identified update-triggered duplicate enqueueing; that additional consequence
was not independently exercised and is not counted as a fifth finding.

The first assisted instruction required reading every diff as well as the ranking.
It therefore tested added oversight, not replacement of broad reading. The audit
identified this limitation and triggered one explicitly posthoc routed comparison:
a fresh ordinary replicate and an agent starting from the frozen top-four shortlist,
with the complete diff pool still optionally available. Its results are recorded
in the follow-up section below; the first comparison is retained unchanged.

### Routed comparison: replace the initial broad read

The routed agent read the top-four shortlist and then four evidence packets. Its
command trace confirms it did not open the full diff pool. A fresh ordinary
replicate used the original ordinary instructions and read the full pool first.

| Posthoc comparison | Ordinary replicate | Routed shortlist |
| --- | ---: | ---: |
| Confirmed findings / false actionable findings | 4 / 0 | 4 / 0 |
| Deep packets opened | 4 | 4 |
| First subsequently confirmed finding | 19.99 s | 28.04 s |
| Process wall time | 38.96 s | 56.26 s |
| Input tokens, including cached input | 139,032 | 135,529 |
| Cached input, a subset of input | 84,864 | 98,304 |
| Output tokens | 1,180 | 1,594 |

Routing reduced reported input by 3,503 tokens (2.52%) in this one comparison,
while output increased and wall time worsened. Both arms found the same defects.
That is a small descriptive token reduction, not reliable cost/time superiority.
The routed arm inherits the same known-family evidence selection and small-corpus
limitations. The recorded ranking used three Jev repeats; its $0.005267 upstream
cost belongs in the assisted pipeline's accounting, in addition to extraction.
Future single-pass costs cannot simply be presented as this measured pipeline.

Cached-input proportions differed sharply. Tokens saved from cache cannot be
attributed to Jev; caching and shared backend state were not controlled. Agent
input counts also include repeated instructions/tool context. No billing invoice
or causal dollar-saving claim is available. Reviewer time excludes fixture
construction and extraction; pipeline comparisons must add upstream work.

## API accounting and validation

| Phase | Calls | Strictly valid | Input | Output | Estimated TypeSafe USD |
| --- | ---: | ---: | ---: | ---: | ---: |
| Known-source replay and outstanding leads | 23 | 21 | 162,793 | 2,916 | .006837306 |
| Booted app, both evidence arms | 48 | 46 | 152,523 | 6,678 | .006405966 |
| Whole-source contract diagnostics | 12 | 12 | 96,579 | 372 | .004056318 |
| Focused-method diagnostics | 18 | 18 | 23,778 | 360 | .000998676 |
| **Total** | **101** | **97** | **435,673** | **10,326** | **.018298266** |

All 101 calls returned HTTP 200. Costs include rejected responses and use the
[published $0.042/M input rate with free output](https://docs.typesafe.ai/models).
They are estimates, not invoices, and exclude the downstream agent calls. One
credential lookup served all four phases; the key stayed in memory and the process
was closed after capture. No HTTP retries occurred. Three-worker API batches took
15.31 seconds combined, excluding preparation, extraction and review.

Of four strictly rejected responses, one selected a non-maximal Choice; three
had probabilities summing to .99. Those three are consistent with coarse displayed
rounding, and the experimental validator's 0.00002 sum tolerance may be too strict
for the observed service. Do not describe all four as demonstrated semantic model
failures. Preserve the raw distribution, define an explicit rounding policy, and
validate independently consumed Noul fields separately in a future runner. This
trial kept its original whole-response policy rather than changing acceptance
after seeing the results. Typed output still requires defensive handling; see the
[API answer contract](https://docs.typesafe.ai/api).

## Implementation conclusions and limits

1. Reuse a runtime Woods index for application review. Whole sources, inherited
   filters, schema and explicit job premises can remove meaningful ambiguity.
2. Start advisory. An execution-backed finding can remain real when its Jev score
   barely moves or moves the wrong way after a fix. Never auto-close that finding.
3. Measure replacement as well as added oversight. A shortlist cannot save broad
   reading if the workflow still requires the agent to read everything first.
4. Isolate answer failures and record all usage, including invalid results. One
   malformed localization should not erase a batch or imply a clean packet.
5. Treat pre-boot source capture, selected evidence sufficiency and revision identity
   as separate checks. Post-boot Rake capture being `unknown` was correct behavior.
6. Keep this in the optional companion's design. This round does not justify a
   default inference dependency or a merge gate in the Woods gem.

The fixture pairs are easy, correlated examples with explicit intent. The evidence
adapter used known relevant paths, and neither agent had to explore a monolith.
There is no general recall, calibrated risk, secure-review or multi-database claim.
The result supports inexpensive application triage feasibility and careful evidence
construction, while downstream savings remain an empirical question.

## Local artifacts

`tmp/typesafe-next-trial-2026-09-21/` retains frozen schedules, all requests/responses,
raw accounting, before/after labels outside state, boot/extraction logs, candidate
receipts, independent behavioral outcomes, reviewer JSONL events and final reports.
Disposable applications and reviewers live under `/tmp/woods-jev-app-pilot-20260921/`
and `/tmp/woods-jev-reviewer-comparison-20260921/` respectively. None is a supported
CLI release or a complete historical replay archive.

The original source checkout's unrelated changes were preserved. Full local gem,
Rails-matrix and live-backend suites were not rerun because no packaged behavior
changed; 126 focused existing examples passed, and the application cases executed
through a real Rails runtime. The prior fixes' 165-example verification and green
PR checks remain separate evidence.

The portable guide includes the actual synthetic callback request `a042` and its valid recorded response. Request SHA-256: `6f03439376eb0b897cae102c7c622ff359c4f2568b7b98269a5845f5fe384f01`; response SHA-256: `9a351ed7f4bc430ff65c7c26fc1312f68d6e77539224cd993c0e8e7b6d4dc94b`. These samples contain no executable oracle results and are not inputs to the older ranking-example CLI.
