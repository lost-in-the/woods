# Jev Review investigation and a Rails adaptation

Reviewed September 17, 2026. Public repository: [devagrawal09/jev-review](https://github.com/devagrawal09/jev-review), pinned to **`31f89602797fb7bea007f8a480bf368bf564954e`**. The investigation included source review, two independent code audits, the repository's checks, and seven offline probes. No TypeSafe inference request, private application boot, or credential lookup was made.

## Recommendation

**Adapt its staged review architecture for Rails as an optional development tool.** It is a useful implementation reference for cheap review triage, evidence selection and advisory routing. It does not establish that Jev finds bugs accurately, and the current implementation does not scan Ruby at all.

Use a Woods-backed evidence adapter with a filesystem fallback, preserve the evidence through every stage, and evaluate the resulting review behavior on known defects and valid counterparts. Keep this review experiment distinct from the shared-candidate ranking experiment: one measures which evidence is selected, the other measures whether actionable review concerns are found. Neither result substitutes for the other.

The attractive economic case remains the user's estimated **$0.042 per million input tokens, free output**. Cheap screening can be worthwhile even if a larger model is equally or more accurate, provided screening reduces total work while meeting the intended quality and missed-defect requirements. Evidence construction, latency, downstream confirmation and reviewer attention must be measured separately.

## What the repository implements

The project is an MIT-licensed TypeScript application requiring Node 24 or later, with SDK `@typesafe-ai/sdk` 0.6.0 in its lockfile. It has two entry points: current working-tree changes against `HEAD`, and a scan of current source files. A local dashboard reads a saved report. It does not publish GitHub reviews or modify reviewed source. Its own README describes findings as prompts for investigation rather than proof of a defect. [README](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/README.md), [package manifest](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/package.json).

| Stage | Actual behavior | Potential Rails use |
| --- | --- | --- |
| Screen | Five Noul judgments per source packet: correctness, security, reliability, compatibility, test gap | Cheap, task-scoped concern signals over source plus runtime facts |
| Profile | Top five files get Choice category and Score review priority, even below the screening threshold | Optional display/routing metadata; omit initially if it changes no decision |
| Select follow-ups | Signals at least .70; global maximum eight | A bounded investigation queue, with explicit records for unreviewed signals |
| Locate | Choice of a hunk/region or `noMatch`; confidence floor .55 | Select a stable source-span ID while permitting abstention |
| Classify | Choice of mechanism or `noIssue` | Categorize a supported concern, without claiming a generated explanation |
| Assess impact | Score 0–3 assuming the concern exists | Conditional impact for prioritization, separate from whether a defect exists |
| Route | Score at least 1.5 triggers reviewer-specialty Choice; at least 2 yields a `request_changes` report label | Advisory specialist routing after a validated policy; no automatic merge gate |

The application centralizes these policies and keeps discovery separate from review orchestration. This is a useful design to borrow. The numeric cutoffs are project choices, not validated thresholds for Woods or Rails. Profiling currently does not influence which signals are followed. Several dimensions from one file can consume several of the eight slots. [Workflow](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/review/workflow.ts), [policy](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/domain/config.ts).

## What was verified offline

The repository's `npm run check` passes on Node 26.7.0: TypeScript checking, dependency direction/cycle checks across 17 modules, and dashboard JavaScript syntax. There is no behavioral test script or measured review-quality evaluation in the checked repository. Passing those checks does not establish defect-detection performance.

The local probe script imports the actual repository functions. Calls to the SDK are replaced with a deterministic recorder, and global fetch rejects any unexpected network access. All seven probes pass; the unexpected-fetch count is zero. The captured model outputs are synthetic and establish control flow only.

| Probe | Observation | Interpretation |
| --- | --- | --- |
| Source discovery | From `plain.ts`, `café.ts`, a Ruby file and an RSpec file, both adapters return only `plain.ts` | JS/TS-only scope plus a quoted-path bug |
| Test compaction | A six-line test becomes its declaration and two setup lines; action, assertion and closing brace disappear | Relevant evidence can be lost before the model sees it |
| Follow-up state | Evidence, mechanism, severity and routing calls contain no test context | Later test-gap judgments cannot recheck the supplied tests |
| Single long line | A 548,914-byte one-line source produces one screening request of 632,352 serialized bytes in the recorder | Line count is not a byte/token admission limit; no server response was tested |
| Later request sizes | The same file produces roughly 630 KB profile and localization requests | Screening chunking does not bound all stages |
| Low-signal case | A file whose five signals are .1 still gets profiled | Profiling is additional recurring work, not a gate for following signals |
| Worker rejection | After one of seven callbacks fails, surviving workers can schedule the remaining callbacks | The reusable runner lacks coordinated cancellation; the save CLI's process exit can cut this short |

The follow-up probe also returned a `request_changes` label when synthetic mechanism and severity confidence were both .01 but severity was 2.5 and location confidence was .9. Only location confidence gates that path. This is not evidence of actual false positives, and adding arbitrary confidence gates is not an established fix.

Two reproducible input defects were initially reported upstream, then **closed and withdrawn at the user's request**:

- [Issue #2: Git-quoted filenames are silently omitted](https://github.com/devagrawal09/jev-review/issues/2).
- [Issue #3: Test compaction silently drops action and assertion](https://github.com/devagrawal09/jev-review/issues/3).

The public issue titles and bodies now say “Withdrawn”; GitHub denied deletion because the account lacks the required repository permissions. Do not open or comment on issues unless the user explicitly asks. The local synthetic reproductions remain valid evidence. Source loss in later stages, incomplete request caps and cancellation remain design/operational concerns documented here; their effects on live review quality or billing were not measured.

Local evidence is retained under `tmp/jev-review-audit-2026-09-17/`: `offline-probes.mjs`, `offline-results.json`, the issue bodies, and a SHA-256 manifest. Reproduce with an installed checkout of the pinned revision:

```bash
node tmp/jev-review-audit-2026-09-17/offline-probes.mjs /path/to/jev-review
```

The probe writes disposable synthetic repositories under the system temporary directory. It supplies a synthetic placeholder key only to instantiate the mocked client; it does not read the user's TypeSafe credential.

## Transfer limitations that matter for Rails

**Language and Git semantics.** The source regex includes only JS/TS variants. The test regex does not recognize RSpec's `spec/` and `_spec.rb`; adding `.rb` alone would therefore treat specs as production subjects. Test files are otherwise context-only, so test-only changes are not independently reviewed. Change mode uses `git diff HEAD`, includes untracked files, and excludes deletions. It has no pinned PR base/head comparison. Codebase mode reads working-tree contents without a source digest. [File policy](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/domain/config.ts#L19), [Git adapter](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/adapters/git.ts), [filesystem adapter](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/adapters/repository-files.ts).

**Test context is neither complete nor a coverage oracle.** Codebase test selection uses path heuristics and at most four snippets. Change mode sees only changed test patches. Unchanged regression tests, RSpec shared examples, hooks, fixtures and supporting helpers may be absent. The compactor can remove assertions, and follow-up calls drop the tests entirely. A finding must therefore distinguish missing supplied evidence from missing application coverage. [Screening and test compaction](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/review/codebase-judgments.ts), [change judgments](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/review/judgments.ts).

**Chunking can change the judgment.** Codebase screening takes the maximum over nonoverlapping 160-line regions; this is a pooling rule, not a calibrated probability that the whole file is defective. More regions create more opportunities for an extreme value. The triggering region is not retained in the report. Localization uses 80-line regions and can split a method or guard from its use. Profiles and localization can still submit an entire large file. Preserve these as hypotheses about failure modes rather than measured model errors.

**Typed output is not a defect proof.** Mechanism and impact are selected from fixed vocabularies. A conditional severity score says how serious a suspected defect would be, not whether it exists. The returned line is a hunk/region start, not necessarily the failing expression. The pipeline does not execute tests, resolve Rails behavior, or supply a causal explanation. TypeSafe's confidence describes its output distribution; domain thresholds still require evaluation. [Confidence documentation](https://docs.typesafe.ai/confidence).

**Reports are presentation artifacts.** They contain a matrix, category labels, stage counts and findings, but not source/request hashes, model versions, raw judgments, token usage, retry attempts or source freshness. Saving uses a temporary file and atomic rename; the dashboard binds to loopback with a fixed asset list. Those are useful foundations, but they do not make the report replayable experimental evidence. [Report types](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/domain/types.ts), [report store](https://github.com/devagrawal09/jev-review/blob/31f89602797fb7bea007f8a480bf368bf564954e/src/adapters/report-store.ts).

## Request counts and economics

For one run, logical requests before retries are:

```text
S + P + F + C + I + R
```

`S` is screening calls: one per changed file, or one per 160-line source region. `P ≤ 5` is profiles, `F ≤ 8` localization, `C ≤ F` classification, `I ≤ C` impact, and `R ≤ I` routing. Typed questions total `5S + 2P + F + C + I + R`. The dashboard's file-by-five matrix count is not the number of region judgments or billable requests.

The application has no explicit retry policy or model pin in its calls. However, installed SDK 0.6.0 defaults to a ten-second per-attempt timeout and two retries for applicable HTTP/network failures. It uses `TYPESAFE_DEFAULT_MODEL` when set, otherwise `jev-latest`. The environment can therefore pin a model, and retries already exist; their usage is simply not recorded in application reports. The SDK returns usage, but this application drops it. [JavaScript SDK and linked client reference](https://docs.typesafe.ai/sdk/javascript).

The project publishes no measured token bill or accuracy/latency comparison. At the user's rate, 100,000 input tokens cost $0.0042; one million cost $0.042. These are arithmetic examples, not measured costs of this repository. Five independent judgments in one screening request are a sensible amortization pattern. Repeating large test packets across files and paying several sequential follow-up round trips still affects latency and total input. Do not equate cheap inference with inexpensive human review of weak findings.

## A concrete Rails architecture

Keep the initial integration outside Woods' production extraction path. A small opt-in review runner can consume a versioned JSON evidence packet emitted from Woods plus pinned filesystem source. Retaining the TypeScript orchestration initially is reasonable; Ruby can emit packets without a new production TypeSafe dependency. MIT licensing permits reuse with the required notice. This is an implementation proposal, not functionality already shipped by either project.

```text
Pinned Git base/head or current snapshot
    + filesystem source discovery
    + matching Woods generation and typed relationships
    + relevant tests, contracts and supplied-context limitations
                        |
                Rails evidence packet
                        |
         Jev concern screen, independent dimensions
                        |
          bounded selection of source-span IDs
                        |
       mechanism / missing-evidence / no-supported-issue
                        |
             conditional impact and routing
                        |
     advisory queue -> reasoning review / isolated tests
```

The packet should retain:

- Source revision, base/head identities when applicable, worktree state, index generation, extractor version, typed unit IDs and physical source spans with hashes.
- The actual change and enough enclosing source to interpret it; explicit deleted/renamed/new-file handling.
- Relevant Rails facts, such as inherited behavior, included concerns, callbacks, associations, routes, job behavior or component relationships, only where the matched extraction actually provides them.
- Known callers/support source from Woods and filesystem lookup, with unresolved dynamic relationships recorded rather than invented.
- Associated RSpec/Minitest source and necessary helper/hook/shared-example context, plus a narrowly stated requirement where known. Incompleteness is a program-recorded fact, not something a model can certify away.
- Candidate span IDs, omitted ranges, selection limits, and the provenance of every model-visible fact. Evaluator-only bugs, fixes, reference labels and acceptance outcomes must not leak into input.

Preserve the relevant packet through later stages; selecting a source span should not discard the tests or contract needed to interpret it. Use Ruby-aware spans or whole small definitions with explicit truncation, not arbitrary line windows advertised as complete examples. A filesystem fallback is necessary for useful source outside Woods' standalone extractor scope. Preserve typed graph variants and resolve the generation pointer rather than assuming flat index files.

For Woods itself, use the static self-map to provide source ownership and conservative relationships. For Rails runtime behavior, use a retained, matching host-app extraction or an isolated Woods testbed. The self-map cannot prove callbacks or runtime associations. These are complementary evidence sources.

## The next experiments

**Continue the narrow ranking trial already made feasible by the other agent.** Freeze one naturally generated candidate pool and compare BM25 with TypeSafe under the same delivered-token budget. This remains a current-snapshot weak-target experiment, not a review-quality result.

**Prepare a separate small Rails review pilot.** Start with a few verified defect/fix pairs and valid controls from Woods and the testbed, using source snapshots and an independent behavioral oracle. Build and inspect the packet artifacts offline before inference. Then evaluate Jev screening, the cascade, and an ordinary reviewer on matched evidence and a declared investigation budget. No repository-wide human-labeling campaign or production integration is needed to establish initial feasibility.

Measure finding/target correctness against the independent oracle, missed positives at each gate, false alarms on valid controls, source/evidence completeness, abstentions, actual inference usage and latency, and downstream confirmation effort. Report file/defect-family dependence and preserve the paired unit. A balanced defect/fix fixture is useful for sensitivity checks but does not estimate production precision or natural defect prevalence.

Do not deploy `request_changes` as an automatic gate or treat a quiet run as evidence of safety. If Jev reliably selects useful concerns at very low recurring cost, escalation to a reasoning agent or engineer may be the principal benefit. If it discards true positives or overwhelms confirmation with unsupported concerns, change the instrument or keep the deterministic workflow. This repository makes that experiment concrete; it does not predetermine its outcome.
