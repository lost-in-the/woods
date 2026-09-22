# Follow-up prompt: reconcile the discovery results before changing the index

Read this as the coordinator's response to `FEASIBILITY-CHECK-AND-REVISED-PROTOCOL.md`. **Accept the current-snapshot feasibility work and the newly documented limitations. The next action is a bounded audit of the existing target rows and index measurement, not a general index repair.** The report identifies a potentially important coverage gap, but it does not establish that 74% of targets are unreachable or that every ranking experiment must wait for that gap to be fixed.

Continue with offline analysis of retained artifacts, small deterministic harness corrections, and read-only inspection of the installed Woods version, source, configuration, index, and existing logs. Do not make new inference calls, boot the private application against its shared database, launch author/application trials, or build a general source framework. Preserve the old results and record corrected results separately. This review uses your report and the coordinator's current Woods source; it does not independently verify your private scripts, source, or measurements.

Keep the accepted precision, applicability, provenance, and access corrections. There is no need to reopen those audits. Return concrete supporting artifacts for the remaining claims, rather than another broad research plan.

## 1. Correct the distinction between missing evidence and unselected evidence

Your union returns 9/34 target occurrences. The remaining **25/34 are not selected by that union**, which is different from being unreachable.

Your separate table reports, over 33 distinct target files:

| Current-snapshot status | Distinct targets |
| --- | ---: |
| In the filesystem corpus and Woods index | 12 |
| In the filesystem corpus, absent from Woods index | 12 |
| Not found at the current snapshot | 8 |
| Outside the declared filesystem corpus | 1 |

Thus **24/33 distinct targets are reportedly available in the BM25 filesystem corpus**. Absence from the structural index does not remove those files from filesystem retrieval or from a later reranker's candidate pool. Conversely, being present in the index does not guarantee a depth-one graph path from a changed unit or selection within the output cap.

Separate at least these boundaries:

1. Target mapping is valid for the chosen snapshot.
2. Target source exists and is eligible for the declared corpus.
3. Source is represented in the relevant index or filesystem corpus.
4. Discovery makes it available to selection: graph reachability, lexical search, or another declared mechanism.
5. It survives ranking/shortlisting.
6. The needed source bytes survive packing.

For each arm, identify the first failed boundary and retain other known limitations. A target available in BM25's corpus but ranked below 20 is a selection miss; it is not evidence that the structural index prevented retrieval. A target's name occurring only after the first 8 KB may expose the chosen ranking representation, not a missing file. For the twelve indexed targets, test the actual seed units, edge direction/type, depth, frequency ranking and output cap before attributing every hydration miss to index coverage.

The [TypeSafe reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe) distinguishes discovery of a shortlist from scoring candidates within it. The applicable constraint is that a ranker cannot choose absent candidates. It does not impose a universal discovery-recall floor or require every candidate to have a Woods structural unit.

Withdraw “74% unreachable by any arm,” “coverage alone explains hydration's 5.9%,” and “no selection experiment is interpretable until views are indexed.” A current index gap may justify focused engineering work, while a separately scoped filesystem-based selection experiment remains possible. Neither statement establishes that TypeSafe will help; that remains unmeasured here.

## 2. Rename the measured endpoints and prevent target leakage

**Changed-path overlap is not source saturation.** The 123/138 = 89.1% statistic shows that an anchor path is listed among changed files. Your retained corpus contains neither patch text nor review-time head/base commits, so it cannot establish that the relevant source bytes were actually supplied in mandatory context. This is enough to reject filename recovery as a persuasive measure of incremental context value. It does not measure 89.1% saturation of review evidence. Some apparently out-of-diff anchors may also reflect renames, outdated comments, or mismatched snapshots.

Use “outside the retained changed-path list” where that is the actual test. Describe the 28/194 = 14.4% as **comments matched by the reference/anchor probes**, not the prevalence of demonstrated external-evidence need. An explicit reference may be incidental; important evidence may go unmentioned. Convention-based resolution against today's tree remains an approximate mapping. Likewise, “not found today” alone does not distinguish deletion from a failed mapping.

Your current reported metric is **target-file selection coverage at K**, not source-span coverage: the score checks membership in delivered file sets. If source packets were not actually rendered, say so. File selection, first-8-KB ranking input, and the source ultimately supplied to a consumer are different artifacts.

**The new convention arm must not consume its own answer key.** Resolving constants extracted from later review comments is a legitimate way to propose weak evaluator targets. Feeding those same constants into a discovery arm would disclose the targets to the system under evaluation. A valid arm may resolve constants found in the task-time description, diff, or source it is legitimately allowed to inspect. Record the origin and availability time of every query seed.

Keep comment-derived resolutions evaluator-only, or label them as an oracle-assisted lookup diagnostic. The existing table has no separately measured convention-resolver arm, so do not claim that arm uniquely reached Phlex targets until its inputs and results are shown. A convention resolver can still be useful deterministic infrastructure; its usefulness must be evaluated without giving it the answer.

## 3. Reconcile denominators and budgets from one row ledger

Produce the existing **34 target-occurrence rows**, retaining all exclusions, with an explicit occurrence key: for example PR/file or comment/file. Do not mix those definitions. Include:

- Sanitized PR/family ID, comment/reference ID, target path, mapping method, and any ambiguity.
- Whether the reference came from an anchor, explicit path, or constant; deduplicate overlap between probes by a stated rule.
- The current source commit and index generation used, source existence, corpus eligibility, all associated Woods units, and direct versus embedded/source-only representation.
- Whether the target or any query clue was available to the evaluated arm independently of the review comment.
- BM25 rank, graph reachability/rank, selected-path status, and delivered-source status if a packet exists.
- A first-failed-boundary reason per arm, with unknowns left explicit.

Derive **exact** distinct-file, occurrence, PR, eligible and excluded counts from that ledger. Subtracting eight distinct missing files from 34 occurrences only works if none of those files accounts for the repeated occurrence. “26 evaluable occurrences across roughly 12 PRs” also needs to account for the out-of-corpus target. Clarify the row described as one excluded file but parenthetically listing both `.js` and `.png`. Do not silently repair these mismatches by changing the denominator.

Retain 9/34 as the reported full-accounting union result, with its limitations, and separately calculate corpus-eligible results when the ledger supports them. Missing historical snapshots are reconstruction limitations; they are not model or ranking failures. A deliberately current-snapshot mechanics check is valid if labeled that way.

Two budget corrections matter:

1. **Twenty BM25 files plus twenty hydration files can produce up to forty distinct files.** Unless the union was deduplicated and repacked by a declared rule to K=20, call it a union-coverage diagnostic, not an equal-budget competing arm. Report its actual cardinality. If you want a comparable combined arm, freeze fusion, deduplication and repacking first.
2. **K=20 is not a shared token budget.** It is adequate for a file-discovery diagnostic but not for claiming equal context cost. For a small current-source packet demonstration, use one explicit extra-context token budget, identical treatment of mandatory input, and count headers, support source and truncation markers. Record both selected files and source bytes delivered. Do not invent a mandatory diff packet when only filenames survive.

Restricting hydration to layers above 80% measured coverage is a new exploratory policy, not a causal explanation of the old result. There is no need to add that arm now. First repair the underlying measurement and retain results for excluded layers.

## 4. Diagnose Woods coverage against the installed implementation

The coordinator inspected Woods at **`a9785e7af6704d0c9a7dc0c57b7503565937feae`**. That is the current checkout, not the historical four-test revision and not necessarily your installed gem. Verify your loaded version/source before applying these findings.

Current Woods explicitly supports discovering Phlex components under `app/views`. Its default `component_paths` includes `app/components`, `app/views/components`, and `app/views`; component discovery loads configured directories before enumerating runtime descendants. `nil` uses those defaults; `[]` disables the directory walk. Files must belong to a Rails autoload/eager-load/autoload-once root, and the classes must qualify under the selected component base. The configuration reference also explains that `config.extractors` is accepted for compatibility but does **not** select which extractors run. Do not propose enabling `:components` in that array as a fix. See the pinned [component-path configuration](https://github.com/lost-in-the/woods/blob/a9785e7af6704d0c9a7dc0c57b7503565937feae/docs/CONFIGURATION_REFERENCE.md#component-directories).

This establishes an existing capability to investigate, not a guarantee that every file under `app/views` should produce a unit. File location alone does not prove it defines an eligible Phlex class. Clay support depends on the actual classes and inheritance involved; a directory name cannot establish either support or absence. There is no generic standalone-file scanner for all of `app/helpers` or `app/view_models` in this checkout. A structural index is not a promise of a standalone unit for every application file or extension. The relevant implementation starts in [PhlexExtractor](https://github.com/lost-in-the/woods/blob/a9785e7af6704d0c9a7dc0c57b7503565937feae/lib/woods/extractors/phlex_extractor.rb) and its [component-discovery helper](https://github.com/lost-in-the/woods/blob/a9785e7af6704d0c9a7dc0c57b7503565937feae/lib/woods/extractors/component_discovery.rb).

There is also a concrete adapter concern. Your `by_path` mapping is a private projection, not the public Woods graph field. Current `dependency_graph.json` has a **`file_map` with an array of identifiers per file**, and typed variants matter where identifiers collide across unit types. A single string per path can discard units even after fixing character-by-character iteration. Reconcile your adapter against all applicable source records and graph representations; do not assume fixing those two bugs proves complete traversal. See the pinned [graph implementation](https://github.com/lost-in-the/woods/blob/a9785e7af6704d0c9a7dc0c57b7503565937feae/lib/woods/dependency_graph.rb) and [graph contract specs](https://github.com/lost-in-the/woods/blob/a9785e7af6704d0c9a7dc0c57b7503565937feae/spec/dependency_graph_spec.rb).

Inspect a bounded sample: **three reported missing Phlex/Clay targets plus one indexed control**, preferably including different view subtrees. For each, establish from retained source/index/logs:

1. The installed Woods version and loaded gem/source path; full versus incremental extraction; source commit, application root, environment and resolved generation; relevant component paths and optional dependency versions.
2. What the file actually defines, its superclass chain where known, and which extractor should own it. Record the Rails autoload/eager-load/autoload-once root that owns the file, or mark ownership unknown; inclusion in `component_paths` is a separate check. Distinguish source-inspected expectations from verified runtime ancestry.
3. Whether it was represented as a primary unit, another unit from the same file, embedded/included source, or a graph-only/external identity. Search the actual unit records, not only your single-value `by_path` map. Source coverage and graph connectivity are separate properties.
4. Existing extraction/load warnings, skipped classes, source-location problems, stale generation or path-normalization mismatches, and the adapter's handling of relative/container paths.
5. Which evidence would distinguish an expected scope boundary, version/configuration mismatch, stale/incomplete extraction, an adapter defect, or a reproducible Woods extraction bug.

Do not boot the private application merely to fill those evidence gaps. Unknown runtime facts stay unknown until an isolated reproduction is available. Do not run a fresh extraction against the shared development database. Any eventual reproduction should use the Woods testbed or another disposable, independently configured host. Woods' static self-map helps inspect the gem implementation; it cannot establish the private application's Rails behavior.

Validate the local graph adapter with a small synthetic fixture covering multiple units in one file, a typed-identifier collision, forward/reverse edges, and deterministic deduplication. Keep invalid pre-fix traversal results archived as instrumentation failures. This is a focused regression check for the known adapter mistakes, not another broad performance study.

For reference, the coordinator's component-discovery, Phlex, ViewComponent and dependency-graph specs pass at the pinned revision: **195 examples, zero failures**. Those are current fixture checks, not verification of your private extraction. An existing booted regression covers an autoloaded, non-eager-loaded `app/views` component using a stand-in base; the large Woods testbed supplies real Phlex components. Neither demonstrates your private Clay/Next inheritance patterns. No private runtime reproduction was performed for this review.

Report direct-primary-file coverage separately from source-content coverage, extractor eligibility and graph coverage. A helpers file included into another unit may contribute evidence without owning a primary unit. Conversely, finding its name in an edge does not prove its source was delivered. Until these definitions and sampled cases are checked, “the structural index does not contain half the application” is stronger than the reported path-map measurement supports.

## 5. Keep historical reconstruction bounded and optional

Accept “not recoverable from the retained artifacts” as the present limitation. It is narrower than “not recoverable anywhere.” Do not start reconstructing all 220 PRs as a prerequisite to fixing the current harness.

If useful after the local reconciliation, inspect **one to three PRs** using authorized read-only GitHub metadata access. GitHub review-comment responses document `diff_hunk`, `commit_id`, `original_commit_id`, path, side and line fields; these may help recover an anchor's context. They do not guarantee a complete historical task or its correct base commit. Current PR head/base metadata is not automatically the state before the evaluated review. See [GitHub's review-comment API](https://docs.github.com/en/rest/pulls/comments?apiVersion=2022-11-28).

If that bounded check cannot establish a legitimate review-time task, stop historical reconstruction and retain a current-snapshot fixture. Human adjudication would be needed for stronger claims about reviewer usefulness; it is not required to diagnose graph serialization or file-discovery mechanics. Neither a full historical index per task nor a labeling campaign is a prerequisite to the immediate adapter/coverage audit.

## 6. Return a diagnosis and one concrete next action

Return:

1. **The corrected 34-row ledger and computed summary**, with exact units/denominators, query provenance, union cardinality, corpus availability, rank/output misses and unresolved mappings.
2. **A minimal reproducible adapter/coverage check**, its source revision and commands, the synthetic fixture result, and the four sampled file diagnoses. Report any corrected deterministic result beside, not over, the earlier report.
3. **A short decision**, choosing the next action supported by those artifacts:
   - A lossy adapter or stale/path-mismatched index: fix that local integration and recompute affected measurements.
   - A confirmed extraction defect: identify the installed version and smallest isolated reproduction, check existing issues, and file a sanitized, reproducible bug under the existing issue authorization. Do not publish private application source or file a speculative “Phlex unsupported” issue.
   - An intended structural scope boundary: retain filesystem source discovery alongside Woods relationships, and scope coverage claims accordingly.
   - Corpus-present targets lost below the shortlist/packing cutoff: prepare a small, correctly scoped ranking comparison over that shared evidence pool. Indexing every view file is not a prerequisite.

More than one cause may exist; choose one next action by its demonstrated impact rather than forcing a single explanation. If evidence remains insufficient, name the exact missing artifact or isolated check, not a general requirement to fix the index.

Leave assertion triage and the unverified expensive-selector substitution study deferred. The existing data do not establish TypeSafe benefit, harm, or a limitation on Phlex/delegator code. At the stated **$0.042/M input with free output**, even an equal-quality bounded selection can be worthwhile; a useful improvement over deterministic selection can also justify its small incremental cost. The immediate obstacle is a valid comparison and reliable accounting, not the price of the proposed inference.

Keep the sealed guide/archive and historical outcomes unchanged. A portable guide lesson can eventually say “measure information already supplied, distinguish corpus availability from shortlist selection, and validate adapters against the published graph contract.” The private figures remain attributed observations until their definitions and supporting artifacts are inspected.
