# Jev over the v1.6.2 to beta3 release diff

Completed 2026-09-19. **A release-sized scan was practical at very low inference
cost, using many bounded requests and a short investigation queue.** It did not
fit in one request and did not establish correctness of the whole release.

The scan ranked two files whose subsequent investigation reproduced three bugs.
Other concerns required cross-file contracts or supported-tool registration to
resolve. These outcomes support an advisory screening workflow; they do not
establish model precision, defect recall or savings against an ordinary agent.

## Exact range and size

GitHub releases identified **v1.6.2** as the latest non-prerelease. The comparison
uses the exact endpoints, not the merge base:

- Stable: `4b40e17fd68122a70ccf00d9d2ffb8af42171d3d` (`v1.6.2`).
- Target: `84fc59c18047870a7b45e6da049064ff78427e93` (`v2.0.0.beta3`).
- Merge base: `73423a42644176b09961be373e13648c94690933`.

The stable maintenance branch contains work after divergence, so silently using
a three-dot/merge-base comparison would answer a different question.

The default unified diff is **12,288,759 bytes**, with **921 changed files**,
**210,449 added lines** and **32,738 deleted lines**. A cl100k tokenizer counts
approximately **3,358,933 tokens**. That is a sizing proxy, not Jev's tokenizer.
The [model limits](https://docs.typesafe.ai/models) are 64k tokens per request and
32k for state plus the longest question; sending the entire release was therefore
not attempted. Recorded benchmark vectors/captures and historical material account
for substantial bulk without being useful first-pass code-review evidence.

## What was and was not screened

Every changed path has an inventory entry with its role and source hashes.

| Role | Files | Treatment |
| --- | ---: | --- |
| Runtime source under `lib/` and `exe/` | 312 | Screened |
| Build/delivery scripts, workflows, appraisals and gem definitions | 18 | Screened |
| Tests | 448 | Retained as follow-up candidates; not individually screened |
| Benchmarks and recorded benchmark data | 28 | Not screened |
| Generated/historical material, including changelog/backlog | 22 | Not screened |
| Documentation and other files | 93 | Not individually screened |
| **Total** | **921** | **330 files selected for the first pass** |

This is an executable-change screen across the requested release range, not a
claim that every documentation, test or dependency-lock change was reviewed.

Detached source worktrees preserved both releases. The current development mapper
at `2885f7550f2ee58f627806f73c86feb7aea5e1d7` produced a fresh **5,162-unit static
index of beta3 source**, with producer identity recorded separately. The map was
used for follow-up identities and ownership. It is not runtime Rails extraction;
the beta3 index did not borrow current-main application code or resolved Rails
facts. The primary screen used exact Git diff bytes directly.

## How the large input was handled

1. Produce eight-context-line diffs mechanically for every eligible file.
2. Pack whole hunks where possible, under a 29,000-byte serialized request bound.
3. Split oversized hunks at line boundaries, explicitly marking fragmentation.
4. Ask independent questions about correctness, integrity, security and resource
   behavior, plus a separate context-gap judgment and region-localization Choice.
5. Rank files by their highest substantive score, keeping the complete response
   vector and missing-context signal.
6. Enrich the first six distinct files with complete implementation and matching
   test files; also inspect two low-ranked runtime files.
7. Investigate the shortlist with source tracing and executable probes.

This yielded **393 primary packets**. All eligible hunk bytes were independently
reconstructed from those packets and matched the original diffs. There were
**38 fragmented hunks across 28 files**. Retaining bytes does not establish that
each fragment contains a complete method or enough context to assess it.

Requests identified the intentional v2 migrations—typed identities, atomic
generations, supported MCP surface changes, explicit task failures and clean
re-indexing—so change from v1 alone was not the definition of a defect. No later
fixes, PR discussions or bug labels were supplied. Coordinator familiarity with
the repository remains a bias; this is not a blinded benchmark.

The first pass reported context-gap probabilities at or above .70 in **180 of
392 valid packets**. That is model-reported uncertainty, not a measured count of
inadequate packets. It reinforces that diff screening needs an evidence-fetching
stage. File scores used max aggregation, which gives large multi-packet files
more opportunities to rank highly; they are not calibrated file-risk estimates.

## API handling and operational findings

All **401 requests** returned HTTP 200. **400 passed response validation**.
One primary response for `lib/woods/console/tool_specs.rb` returned Choice
`h1p1` at .36 while `none` had .37. The documented Choice contract selects the
highest-probability option, so the existing validator rejected it.

The initial batch stopped with 166 valid responses and that one invalid response.
The remaining 226 never-attempted requests resumed with identical bytes and the
same validator. The invalid response was not retried, changed into a zero score,
or silently relabeled. Its raw usage is included in the bill estimate. One of
three packets for `tool_specs.rb` therefore remains unassessed; **329 eligible
files have all packets validated, and one has partial validated coverage**.

This makes per-packet isolation and resumable accounting important for a companion
CLI. A malformed localization should remain visible; a deliberate future policy
could separately retain valid Noul fields, but this trial did not relax its
whole-response validation policy retrospectively.

There were no rate-limit or overload retries. Four concurrent workers were used.
A separate local orchestration error attempted follow-up before an oversized
packet's preparation had finished; it made no API call and is retained in the
artifacts. The first follow-up preflight refused 18,990 proxy tokens against an
18k ceiling. Before inference, the follow-up ceiling was explicitly revised to
20k for state plus the longest question, retaining all source and test evidence
and leaving margin below 32k. The original preflight is archived.

The primary stop and local follow-up restart required **three total credential
lookups**, each once per process, never once per request. Keys remained in memory.

## What fuller context changed

The eight enrichment requests retained complete beta3 source and every matching
`<basename>*spec.rb` file. Source hashes and static index identities were recorded.
No source/test truncation occurred. Shared fixtures, other-file helpers, package
wiring and application runtime facts were still incomplete and disclosed.

Follow-up packets used <24k cl100k proxy tokens overall and <20k for state plus
the longest question. The largest actual returned input usage was **20,262
tokens**. Question wording and model stayed fixed, while localization options and
state instructions expanded to cover the supplied full files. This is context
enrichment, not an isolated experiment on token count alone.

| Selected file | First-pass maximum | Enriched maximum | Investigation |
| --- | ---: | ---: | --- |
| `obsidian/vault_exporter.rb` | .77 | .67 | Selected typed-edge ambiguity behavior is intentional; dedicated typed-variant tests support the contract. No defect established in this bounded investigation. |
| `temporal/json_snapshot_store.rb` | .76 | .65 | Malformed nested snapshot data crashes reads and fresh capture; independently reproduced. |
| `session_tracer/file_store.rb` | .75 | .62 | Non-legacy clear error and expired-history revival independently reproduced. |
| `retrieval/source_evidence.rb` | .74 | .58 | Complete-source, heredoc and budget regressions pass; no specific defect established. |
| `console/eval_guard.rb` | .72 | .70 | The concerning source path is inventory-only: supported Console modes never register `console_eval` and refuse unsafe-eval options. No supported-mode vulnerability established. |
| `obsidian/note_builder.rb` | .72 | .67 | Ambiguous analysis attribution is intentionally suppressed; typed-variant tests support the behavior. |
| Low-ranked `embedding/text_preparer.rb` | .06 | .28 | Selected tests pass; no defect established. |
| Low-ranked `version.rb` | .07 | .12 | Correct beta3 version literal; no defect established. |

The seventh first-pass file at .70 or higher, `ruby_analyzer/trace_enricher.rb`,
was outside the six-file investigation budget and remains unadjudicated. The two
low-ranked checks are small spot checks, not evidence of recall or clean low scores.

Adding source/tests reduced every top-file maximum. It did **not** establish that
the files were clean: investigation found real defects in two whose enriched
scores fell below .70. Passing tests and lower scores should not automatically
discard a lead already selected for review. Likewise, a surviving security score
requires actual product reachability before being reported as a vulnerability.

## Reproduced findings and validation

The existing selected suites passed **306 examples**, zero failures or pending.
Follow-up regressions then produced **6 examples: 3 failures and 3 passing
controls**:

- Clearing a valid punctuated/Unicode session ID deletes its encoded file, then
  passes a nil legacy path to `FileUtils.rm_f` and raises. The v1.6.2 counterpart
  clears without error: a beta3 regression.
- Appending to an expired session reads its old history before checking TTL,
  refreshes mtime, and revives the old events. This is a defect in a new feature;
  v1.6.2's FileStore did not offer TTL.
- A retained snapshot with a null unit record passes outer JSON-object checking
  and raises in nested conversion. Both listing and a subsequent valid capture
  fail. This also reproduces in v1.6.2, so it is a pre-existing robustness gap.

The affected files matched observed main
`8fa5f358c5f8da5e31b3c1975f13a4c07697f266`. These findings remain unfixed by this
experiment. The [focused bug report](2026-09-19-beta3-review-bugs.md) includes
reproduction commands and suggested investigation boundaries.

Jev selected files/regions, not the precise failure explanations. Coordinator
inspection and probes established the mechanisms. Three findings in two of six
investigated files is a descriptive workflow outcome, not a model precision
estimate. The supplied probabilities are not calibrated against release-wide
ground truth, and uninvestigated files may contain additional defects.

## Cost and time

| Phase | Calls | Input tokens | Output tokens | Estimated USD |
| --- | ---: | ---: | ---: | ---: |
| Primary screen, including resumed packets and invalid response | 393 | 1,172,352 | 52,481 | $0.049238784 |
| Source/test enrichment | 8 | 86,146 | 1,267 | $0.003618132 |
| **Total** | **401** | **1,258,498** | **53,748** | **$0.052856916** |

Estimate uses the [published $0.042/M input rate and free output](https://docs.typesafe.ai/models),
not an invoice. Every paid response is counted, including invalid output.

HTTP median was **0.395 s**, p95 **0.511 s**. Four-worker batches occupied about
**40.9 seconds in total** across the initial, resumed and enrichment phases.
This excludes preparation, local restart handling, inspection, specification runs
and reproduction work. It is not a 41-second completed release review, and no
downstream time comparison was performed.

## Implementation lessons

- **Large total input is manageable through fan-out.** The limiting problem is
  preserving the context needed by each judgment, not the total number of bytes
  the workflow can process or the marginal TypeSafe token bill.
- **Keep a coverage ledger.** Distinguish inventoried, excluded, fragmented,
  attempted, valid and investigated. A quiet packet or excluded file is not a pass.
- **Use full evidence for follow-up.** Filename matching alone missed relevant
  Obsidian typed-variant tests. Woods relationships and explicit contracts should
  improve support retrieval, while static graphs must not claim runtime reachability.
- **Treat screening as an investigation queue.** A second .70 gate would have
  discarded the two files where subsequent probes found bugs. Do not infer that
  more context plus a lower score proves safety.
- **Carry supported-surface context.** The eval concern required actual registration
  policy; source existence alone was insufficient. Rails applications likewise
  need effective runtime configuration and supported version/adapter premises.
- **Isolate malformed answers.** Preserve raw results, count their cost, keep
  incomplete coverage visible and resume unrelated work without silently changing
  model output or prompting until it passes.

The next comparison should measure downstream reviewer effort at a fixed budget,
using fresh application changes and a matched ordinary-agent workflow. This trial
already establishes feasibility of broad, very inexpensive screening; it does
not require proving Jev is an independent release judge before building the
optional companion CLI recorded in backlog B-204.

## Artifacts and limits

`tmp/typesafe-release-trial-2026-09-19/` retains the protocol, complete inventory,
requests, raw responses, per-attempt ledger, freezes, rankings, source receipts,
local failure/restart records, specification results, probes and summaries.
Disposable release worktrees and static map are under
`/tmp/woods-jev-release-trial-2026-09-19/`.

The new standalone regressions live in
[`script/typesafe/probes/release_review_regressions_spec.rb`](../../../script/typesafe/probes/release_review_regressions_spec.rb).
They are intentionally outside the default suite pending fixes. Focused RuboCop
passes. No production code, dependencies, gem version, release fences, tags or
plugin behavior changed. The complete Woods/booted Rails/live-backend matrices
were not rerun for this development experiment. No GitHub issues, comments or
release operations were performed during the trial. At the user's subsequent
request, the reproduced bugs were filed as
[#490](https://github.com/lost-in-the/woods/issues/490),
[#491](https://github.com/lost-in-the/woods/issues/491) and
[#492](https://github.com/lost-in-the/woods/issues/492).
