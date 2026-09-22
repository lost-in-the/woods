> Portable evidence copy. Historical status and proposed commands are preserved; this is not a promise that the planned APIs were implemented. Links and the installed-skill location were normalized for portability. Raw ignored captures and external source snapshots are not included.

# Historical TypeSafe evidence audit for the later guide

Read-only historical audit; no inference, credential lookup, test execution, or
frozen-artifact edits. Reviewed development-plan sections 15–21, the source-tooling
README and implementation, and earlier local trial/results/review files. The
current four-test experiment is excluded while it is running. This is supporting
evidence for the later guide, not that guide itself.

## Results that deserve preservation

| Trial / evidence path | Verified historical result | Guide consequence / durable-report gap |
| --- | --- | --- |
| `tmp/typesafe-assertion-trial/RESULTS.md`, `summary.json` | 6/6 labels matched on one dependency-graph family; 6 calls, 4,461 input tokens. All six original examples passed; three exact/helper variants rejected a substituted result fault. Labels came from the preparing assistant. | Durable section 15 only mentions this smoke. Preserve feasibility, but call it assertion discrimination with result fault injection—not implementation mutation, broad coverage, or bug discovery. |
| `tmp/typesafe-assertion-expanded/RESULTS.md`, `summary.json`, `label-review.json`, `control-results.json`, `fault-results.json` | 32/40 exact agreement; 12/12 direct recognized; 0/28 other cases falsely direct. All eight errors were type-only `weak` → `absent`. Four scenario families, 44 calls including four repeats, 27,821 input tokens. All 40 controls passed; 16 injected-result examples failed as expected. Initial independent agreement was 36/40, with four pre-inference tautology-label corrections. | Main durable history omits these exact results. Useful assertion-triage evidence, limited by correlated variants and agent references. The shallow matcher baseline was 26/40 and falsely direct on 14 cases, not a strong static-analysis comparator. |
| Same expanded report | Correct direct confidence reached as low as .52; a taxonomy disagreement had .94. All four omitted helpers were classified insufficient-context. Obvious instruction comments did not override four judgments. Repeat label stability 4/4, maximum probability drift .06. | Do not describe confidence as correctness probability, stable labels as accuracy, or a few obvious injection controls as a security boundary. Missing helper evidence remains distinct from an assertion being absent. |
| `tmp/typesafe-decomposition-pilot/RESULTS.md`, `summary.json`, `corpus/oracle-summary.json` | 16 packets/four new families; 56 calls. Standalone Choice 15/16 versus batched Choice 16/16, with one direct/weak .49/.49 tie. The conservative veto retained 0/4 correct direct cases. Actual isolated implementation mutations: 16 controls passed; eight strong/omitted-helper executions rejected mutants, eight weak/absent survived. | Durable section15 and README accurately report the main outcome. Retain the tie and the distinction from earlier result substitution. More typed questions did not automatically improve the composed decision. |
| Same decomposition report | Same five questions on four packets: 3,172 batched input tokens versus 9,012 separate, 64.8% less input. Sequential summed elapsed 1.74 seconds versus 7.48 seconds. All 56 calls: 33,864 input tokens. | Batching is a measured cost opportunity when questions share state. This does not mean adding questions is cheaper than one original question, nor prove concurrent throughput gains. Durable README has the percentage; exact comparison scope is worth retaining. |
| `tmp/typesafe-claim-pilot/RESULTS.md`, `summary.json`, `markerless/summary.json` | Constructed claims 23/24; 0/18 false-supported; total 42 calls including injection/repeat/marker-removal work. The exact-substring comparator abstained 24/24. Six quote and four arithmetic checks ran deterministically; three code behaviors ran directly. | Durable section16 covers the headline. Keep deterministic checks separate from semantic judgment and do not treat the all-abstaining baseline as a meaningful win. A genuine quote can accompany a false claim; an unmatched abbreviated quote is not proof of fabrication. |
| `tmp/typesafe-real-claims/{RESULTS,configuration-review,task-fit-review,integrity-review}.md` | Natural PR claims: 7/11 exact and 11/12 support-status versus ordinary-agent 11/11 and 12/12; 15 calls. No demonstrated API/model/schema defect. Reviewer instruction parity, missing antecedents, historical-observation scope, and overlapping unsupported/insufficient labels were material confounds. No contradiction-positive natural cases; no fresh historical runtime oracle. | Durable section17 captures the key limits. This is not a clean model-capability ceiling or historical buggy/fixed replay. A raw supported argmax of .39 had .61 total non-support mass and confidence .18; binary routing policy must be specified prospectively. |
| `tmp/typesafe-controlled-followup/{RESULTS,post-run-review}.md`; `tmp/typesafe-narrow-followup/RESULTS.md` | Instruction/context stages 56 calls; narrow stage 12 calls. Aligned instructions improved first-pass agreement but the unchanged original also improved on repeat. Added narrative changed probabilities without argmax changes. Two narrow dimensions each matched 6/6 primary labels and their repeats. | Durable section18 is sound. This demonstrates configuration sensitivity and narrow-task feasibility, not a verified cure. Changing task and primitive together cannot attribute success to Noul alone. Supplied historical-record presence does not prove the historical event independently happened. |
| `tmp/typesafe-context-pilot/{RESULTS,diagnostic-review}.md` | The 180,409-byte selection request returned 400; no authoring began. Separate small-state ten-question marker succeeded; exact full state with one marker failed 400. Three total requests across original/diagnosis, one marker success, unknown rejected-request usage. | Durable section19 is unusually complete. Do not invent a context/token/question limit or causal diagnosis. Discarding the original error body limited diagnosis; later strict sanitization also retained no safe category. Preserve failure as its own experiment. |
| `tmp/typesafe-context-retry/{RESULTS,final-report-review}.md`; durable sections20–21 | Compact 24,471-byte request succeeded; three calls 19,700 input tokens; primary 6,675 tokens/$0.00028035 at the recorded $0.042/MTok input, free output. Both authors passed 116/116 independent checks. Integrated reader equals the frozen TypeSafe-context author's source/spec. | Both had acceptable results; maintainability preference for one implementation does not establish selector superiority. Ordinary selector/author usage was unavailable, so actual savings remain unquantified. The compact request changed content as well as size/representation; success does not diagnose the earlier 400. |

These earlier trials are separate, correlated development sets. Do not pool them
into an independent total-accuracy estimate. Their raw artifacts are ignored local
research files; a portable guide should link durable summaries and explicitly
state when exact captures are not distributed.

## Implemented versus still planned

| Capability | Evidence-backed status |
| --- | --- |
| Offline assertion replay | Implemented in `script/typesafe/{cli,replay,response,profiles}.rb`, exact frozen assessment JSON, and `spec/development/typesafe/replay_spec.rb`. Replay needs neither API nor credential access. Missing/invalid responses remain intended cases; CLI 0 means valid processing, not model adoption. |
| Exact question semantics and malformed input handling | Implemented hardening. Decomposition review found that reversed Noul meaning could pass under the old frozen policy and invalid UTF-8 could escape sanitized CLI handling. Four regression examples failed before fixes. Current specs bind complete rubric/instructions even if a changed request has a valid hash, reject malformed UTF-8, and exercise sanitized exit 2. These concrete discovered-and-fixed harness defects are not prominent in durable outcome sections. |
| Response validation | Implemented for Choice/Noul: exact reported model identity, exact answer IDs/types, complete normalized option distributions, winner consistency, finite bounded values, nonnegative token counts. Malformed/missing responses are operational errors, never a negative semantic judgment. Synthetic validation tests are not evidence that the service returned malformed responses in successful historical batches. `Score` is deliberately unsupported. |
| Materialized evidence reader | Implemented offline `Evidence.read`; exact raw-byte SHA-256/UTF-8, bounded regular-file reads, confined resolved paths, explicit error type. No Git access, inference, labels, source execution, or CLI integration. It does not prove source lineage or provide a race-proof hostile-filesystem sandbox. |
| Capture/auth/cache workflow | Live runners exist as ignored experiments, not a supported `capture` command. Observed pattern: one secret-manager resolution per batch, credential only in process memory, captured responses reused for offline analysis. Store secret references in configuration; never persist the key in captures. Cache-key/version guidance exists, but a general reusable production response cache is not implemented. Intentional repeat trials bypass capture reuse. |
| Failure/fallback | Historical live runs stop without automatic retries; replay preserves missing/invalid results. Semantic `needs_context`/`review` routing is separate from transport or validation failure. There is no production fallback/escalation service or validated auto-approval policy. Later experiment-specific ranking fallback rules must be described from their own frozen protocol. |
| Benchmark applicability/performance diagnosis | Planned in the initial design and `tmp/typesafe-docs-review/NEXT_STEPS.md`; no completed dedicated benchmark-applicability or performance-risk experiment was found in this historical evidence. Existing claims about measured timings are claim-support tasks, not benchmark recommendations or executed performance regression discovery. |
| Blinded historical buggy/fixed replay | Planned; no completed implementation of the named paired historical profile found. Deliberately mutated current code, after-change source claims, and questions about supplied historical records are different experiments. |
| Full corpus/provenance/holdout framework | Still deferred: general lineage/partition validation, stronger baseline selection, family bootstrap, historical-pair admission, capture/resume CLI, and held-out adoption study. Materialized-reader and replay slices do not satisfy the full initial architecture. |
| Production Woods use | No TypeSafe runtime extraction/MCP/packaged dependency, automatic acceptance, CI inference, or ordinary test-network requirement introduced by these historical slices. |

## Portable lessons to carry forward

Use deterministic parsing, exact quote/arithmetic checks, source IDs and copied
bytes wherever they answer the question. Ask narrow typed judgments only where
semantic selection adds plausible value. Preserve the complete question meaning
in instructions/state; IDs are routing keys, not a substitute for task wording.
Questions in a batch are independent and do not consume each other's answers.

Keep code-implied behavior, test assertions, executed behavior, historical
observations, and missing evidence distinct. Typed output guarantees a shape,
not a correct judgment. Freeze policy/rubric and report review burden, retained
useful decisions, failures, and ambiguity alongside accuracy. No observed broad
verification result supports dropping ordinary review or executable tests.

At the very low measured input rate, acceptable equal-quality selection can be
valuable even without superior code. Still account for context preparation,
downstream context, authoring, repair/escalation, and review. Do not claim a
savings ratio from unmeasured comparator/subscription usage, and do not divide a
whole agent-turn duration by HTTP latency as a model speed benchmark. Preserve
unknown failed-request cost as unknown.
