# TypeSafe development evaluation: implementation plan

Status: reviewed, revision 3; no open blocking design concerns. Research checked 2026-09-16 against Woods `55a74ea4`.
Sections 1–14 preserve the reviewed target design. Sections 15–20 record implemented slices and development trials; section 21 adds a prospective cost-efficiency direction. The complete pipeline and adoption requirements remain unmet.

## 1. Decision and intended outcome

Build a source-checkout-only Ruby evaluation tool to determine whether TypeSafe improves development review of Woods. Deliver behavioral assertion support end to end first. Then add benchmark applicability, blinded historical bug replay, and claim verification as independently evaluated profiles through the same packet format. The output is an advisory, evidence-linked report; running code and deterministic checks remain the correctness authorities.

The first usable result is an offline, reproducible report over curated examples, followed by an explicitly invoked live capture against those same examples. No TypeSafe dependency, task, executable, configuration, inference, or network requirement enters the packaged gem, extraction pipeline, MCP servers, or normal tests.

Success means measurably more useful review findings at a fixed review budget than simple deterministic baselines, with known false alarms and operational costs. A negative result is an acceptable completed experiment. Do not expand an ineffective profile into production.

## 2. Research findings and selected scope

TypeSafe accepts state plus independent typed questions. Jev returns choices, scores, probabilities, and confidence, not generated explanations, tests, or fixes. This suits repeated judgments over bounded evidence. Its docs and examples do not establish accuracy on Ruby/RSpec, concurrency, Rails, or Woods.

| Opportunity | Decision | Reason |
|---|---|---|
| Does a supplied spec assert a particular invariant? | First profile | Direct developer value; controlled weakened assertions and helper omissions are available. |
| Does a benchmark exercise a patch's mechanism? | Second profile | Existing Woods benchmarks have explicit workload and measurement boundaries. |
| Can a bounded invariant judgment distinguish historical buggy and fixed code? | Third profile | Real fixes and executed regressions provide independent evaluation material. |
| Does code/report evidence support a documentation or PR claim? | Fourth profile | Reuses the evidence-support structure; numeric checks stay deterministic. |
| Refine candidate method moves or inferred test mappings | Later experiment | Useful semantic ambiguity, but must preserve deterministic findings and public graph meaning. |
| Classify diagnostic failures or performance hypotheses | Later experiment | Needs labelled incidents and a fixed set of read-only probes. |
| Retrieval reranking or query classification | Separate later experiment | Existing Canopy benchmark is useful, but this changes a different behavior and needs candidate-coverage analysis. |
| Supervised feature discovery / learned prioritization | Deferred | Requires a larger independently labelled outcome history. |

Repeated research found three important limits: SimpleCov currently provides aggregate execution coverage, not per-example attribution; complete RSpec helper closure is dynamic; and hosted-model aliases do not establish immutable model versions. Design around all three.

## 3. Non-goals and compatibility

- No automated code changes, test generation, merges, issue posting, or execution of model-selected commands.
- No inference of runtime Rails facts from the static Woods self-map.
- No replacement of tests, coverage percentages, SQL safeguards, publication checks, graph identity, or required CI lanes.
- No automatic test skipping, mutation dismissal, suppression of review findings, or claim that an unflagged patch is safe.
- No general repository crawler, arbitrary repository upload, complete source-to-test mapping, or semantic PR gate in this iteration.
- No changelog/version/release-state changes for this plan. Implementation is internal developer tooling; reassess documentation/plugin/public-surface obligations if scope crosses that boundary.

Use `script/typesafe/` for code, `spec/development/typesafe/` for tests, `spec/fixtures/typesafe/` for curated public fixtures, and `tmp/typesafe/` for local captures. These are excluded by the current gemspec file list. Planning records belong in `docs/design/plans/`, also excluded. Test that packaging remains unchanged without changing the gemspec just to add exclusions.

## 4. Architecture and ownership

All new runtime classes live under a separate `WoodsDevelopment::TypeSafe` namespace and load no Rails environment. Use Ruby 3.0-compatible stdlib `json`, `digest`, `net/http`, `uri`, `optparse`, and filesystem helpers. No new runtime/development dependency is required for the first implementation.

| Proposed file | Responsibility |
|---|---|
| `script/typesafe/cli.rb` | Parse explicit offline/live subcommands; exit policy; dependency wiring. |
| `script/typesafe/corpus.rb` | Validate manifests, partitions, families, packet and label schemas. |
| `script/typesafe/evidence.rb` | Verify materialized packet hashes/provenance; optionally verify explicit Git blob/line references. |
| `script/typesafe/profiles.rb` | Versioned questions, option definitions, outgoing-state allowlists, and baseline definitions. |
| `script/typesafe/request.rb` | Canonical serialization, request digest, bounds, and outgoing JSON construction. |
| `script/typesafe/client.rb` | Injectable HTTP transport, authentication, timeouts, retry policy, response validation. |
| `script/typesafe/capture.rb` | Attempt ledger, result persistence, explicit replay identity, resumability. |
| `script/typesafe/evaluator.rb` | Join predictions to local gold labels; baselines; metrics; family resampling. |
| `script/typesafe/report.rb` | JSON and Markdown reports assembled from known templates and evidence references. |
| `script/typesafe/README.md` | Maintainer runbook, actual limits, examples, live prerequisites, interpretation. |

Keep concerns separable through injected transport, clock, sleeper, random generator, and filesystem root. Do not turn this into a general multi-provider framework. Fixtures may include hand-authored API responses clearly marked synthetic; synthetic replay tests validate plumbing, never model quality.

Flow: explicit evidence manifest → hash-verified packet → allowlisted request → offline baseline or explicit live capture → validated answers → local label join → advisory report. Only the capture step contacts TypeSafe. None of these steps executes fixture code, Ruby source, or commands found in a packet.

## 5. Corpus and evidence contract

Use JSON only, with explicit schema versions and unknown-field rejection at our own schema boundaries. Validate identifiers, enums, finite numeric values, unique IDs, and file sizes before doing work. Corpus metadata, provider inputs, execution records, and gold labels are separate files/objects.

`corpus.json` contains `schema_version`, `corpus_version`, `selection_version`, `cases`, and `partitions`. A case contains an opaque `case_id`, local `family_id`, `profile`, `packet_path`, `packet_sha256`, and `partition` (`development` or `holdout`). Historical cases also have local `pair_id` and `oracle_record_id`; benchmark cases have a local `review_group_id` for one change's fixed candidate benchmark set. Gold records contain historical arm labels. Validate one buggy and one fixed arm per scored historical pair, distinct immutable implementation SHAs, and matching scenario and oracle/overlay digest. Entire benchmark candidate sets stay within one family/partition. Labels and oracle records are joined locally by case ID and are never reachable through request construction.

A packet contains:

- `schema_version`, a neutral invariant/question or claim, and an explicit bounded scenario.
- `evidence`: ordered entries with opaque `evidence_id`, `role` (implementation, example, helper, benchmark, specification, report), UTF-8 `content`, and local provenance.
- Local provenance: repository identity, immutable full commit SHA, path, inclusive source-line range, raw blob hash, extracted content SHA-256, and any transformation recipe/version plus resulting digest.
- `context`: known assumptions and `closure_status` (`curator_complete` or `incomplete`), plus missing helper/context references. Local completeness attestations record reviewer identity, review revision, and reviewed packet digest. Curator-complete is an attestation within the packet's stated scope, not a mathematical proof of whole-program closure.
- Profile-specific input fields: benchmark workload and measurement scope; or supplied documentation/report claim. Benchmark packets include neutral before/after change evidence and the selected benchmark; the historical-invariant profile always contains only one arm. No arbitrary additional source discovery.

During corpus authoring, source acquisition uses Git object reads for explicitly listed paths at a resolved full SHA, using argument arrays and no shell interpolation. Reject non-regular Git blob entries, symlinks, submodules, absolute/traversing paths, missing blobs, invalid ranges, encoding errors, and mismatched hashes. Do not read an untracked worktree file as fallback. Resolve all manifest/packet/label/overlay paths within their designated corpus root and reject symlink escapes. Local fixture overlays are permitted only as explicit versioned content with base digest and transformation provenance; never modify the checkout.

Commit the deliberately selected materialized evidence bytes with their reviewed provenance so ordinary offline CI/replay works in a shallow checkout. `validate` and `prepare` verify those content/manifest hashes without requiring historical Git objects. `validate --verify-git` additionally checks source lineage against the locally available repository and fails explicitly for missing history; it never fetches. Corpus admission requires a recorded successful full source verification by the curator. Replay verifies preserved bytes and lineage attestations; it does not claim to re-prove absent historical objects.

For assertion support, curators include surrounding example groups, subjects/lets, hooks, shared examples, relevant helpers/custom matchers, and implementation definitions. Automatic closure discovery is out of scope. Preserve omissions as explicit adversarial cases rather than silently filling them from a newer revision. Runtime metaprogramming that the packet cannot describe is `incomplete`.

Provider state includes only neutral scenario/claim, evidence IDs/roles/content, necessary neutral path context, assumptions, and missing-context descriptions. Strip local case/family/partition identifiers, labels, oracle outcomes, commit SHAs/messages, timestamps, and filenames such as `buggy` or `fixed`. Review source comments and descriptions for post-fix answer leakage. Transformations must be symmetric and recorded; do not silently rewrite semantic source. If leakage cannot be removed without invalidating the example, exclude it from blinded evaluation and retain it only as a labelled instructional example.

Split by invariant/bug/workload family before tuning. Every original, weakened, mutant, helper-omitted, and fixed variant of a family stays in the same partition. Duplicate content and overlapping source/scenario families are reported for curator review. Freeze corpus/labels/rubric/baseline/selection hashes before final holdout. Once holdout results influence changes, that holdout becomes development data and a fresh holdout is needed.

## 6. Question profiles and result semantics

Start with Choice only, using string instructions and string-valued criteria supported by the HTTP API. Every instruction contains the full question and explicit references to state fields: question IDs are not model-visible. Questions treat source comments and quoted text as evidence, not instructions. Include adversarial evidence that requests an answer override.

| Profile | Choices | Separate deterministic facts |
|---|---|---|
| `assertion_support` | `direct`, `weak`, `absent_in_packet`, `insufficient_context` | Example execution and lane status; helper-manifest completeness. |
| `benchmark_applicability` | `direct`, `related_only`, `irrelevant`, `insufficient_context` | Workload sizes, measured phases, actual invocation, environment. |
| `invariant_check` | `preserved_for_scenario`, `violated_for_scenario`, `insufficient_context` | Historical regression/oracle outcomes. |
| `claim_support` | `supported`, `contradicted`, `unsupported_in_packet`, `insufficient_context` | Quote matching, arithmetic, registration counts, version equality. |

Rubrics explicitly distinguish absence within supplied evidence from a global absence claim. A direct assertion must exercise the scenario and assert the specified consequence through visible assertions/matchers; matching names, test descriptions, or non-nil expectations alone are insufficient. Benchmark `direct` requires that the supplied workload enters the changed mechanism; it says nothing about measured speedup. Invariant `preserved_for_scenario` is scoped to the supplied scenario, never all inputs.

Execution status is local metadata with values `passed`, `failed`, `pending`, `not_run`, `infrastructure_error`; missing execution is `not_run`, never passed. Gold/oracle results are excluded from assertion-adequacy and invariant-prediction requests. A later execution-summary profile would be a separate experiment, not mixed into these metrics. Claim-support requests may legitimately include measured results because those results are the evidence being judged.

Store every raw validated choice/distribution/confidence. If `closure_status=incomplete`, display `needs_context` as the effective assessment while retaining the model's raw choice for omission-failure measurement. An API/validation failure produces an operational error, never `insufficient_context` or a negative finding. No majority voting, model-generated explanation, or hidden corrective prompt is used.

MVP sends one target question per packet. Only batch independent questions when they legitimately use the same evidence; never place multiple historical variants into one shared state. Evidence selection dependent on an earlier answer would require a separate request and is out of scope. Reports list supplied evidence rather than inventing a model-cited causal explanation.

## 7. Independent labels and execution oracles

Begin with a 24–30 packet development smoke corpus for assertion support, spanning intact/weak/absent/context-omitted cases. Complete this first profile before implementing later profiles. Each later profile brings its own 24–30 packet smoke corpus, including explicit claim-support examples when that profile is added. These corpora validate packet design and tooling only; they cannot authorize adoption. Later profiles are independent follow-on work and may be stopped if costs or early evidence do not justify them.

Initial source candidates:

- `spec/integration/publication_atomicity_spec.rb`: generation pinning and publication guarantees.
- `spec/integration/incremental_equivalence_spec.rb`: full/incremental equivalence and known runtime limitations.
- `spec/dependency_graph_spec.rb` and historical fix `fc16455f`: external reverse edges and typed collisions.
- `bench/git_history.rb`, `bench/flow_assembler_bench.rb`, `bench/graph_analyzer_bench.rb`, `bench/atomic_write_bench.rb`: workload applicability.
- `docs/EVALUATION.md` and captured reports: timing-scope and comparison claims.

A maintainer labels support/applicability independently of model output; a second reviewer adjudicates ambiguous or disputed labels. Model-written labels are not ground truth. Unresolved label disputes are retained as unscored cases. Record label rationale and exact evidence locally, excluded from prediction requests.

Historical labels require an independently executed regression at the specified pre-fix and fixed revisions. A failing run must fail the targeted assertion, not syntax, boot, package resolution, timeout, or unrelated examples. For assertion quality, retain intact, weakened, and helper-omitted spec variants; corroborate selected cases with a reviewed implementation mutation that the intact test kills. Survival alone does not prove a coverage defect or equivalent mutant.

Oracle execution is a manual maintainer workflow outside this runner in disposable worktrees. Do not add a command executor to corpus ingestion. Record a reviewed argv array, controlled relevant environment, exact implementation and test/overlay digests, source SHA, Ruby/Rails/backend versions, lockfile digest, example IDs/counts, seed, exit status, outcome classification, and stdout/stderr artifact hashes. Copy or resolve a historical-compatible lockfile deliberately; the current ignored lockfile may not match historical Gemfiles. Booted spec files run in separate processes. No oracle modifies the user's checkout or production data.

For unavailable old environments, mark `oracle_unavailable`; do not silently replace the oracle with a model judgment or count it as a verified bug example. Runtime evidence is imported through its own validated local schema, including a `failure_kind` (`targeted_assertion_failure`, `unrelated_assertion_failure`, `syntax_error`, `boot_error`, `dependency_error`, `timeout`, `none`) and target example ID. Require the intended failure and a passing fixed arm for a scored historical pair. Preserve unrelated original tests as controls when overlaying a new regression into an older revision.

Historical replay measures judgment on curator-selected scenarios and evidence, not autonomous discovery of previously unknown bugs. Published fixes may be in provider training data; packet blinding cannot rule out that contamination. Reports carry this limitation.

## 8. HTTP capture and operational boundaries

Use `POST https://api.typesafe.ai/v1/systemone` with `Authorization: Bearer` from `TYPESAFE_API_KEY`, `Content-Type: application/json`, and only documented top-level fields `model`, `state`, `questions`. Do not introduce OpenAI-style messages, tools, temperature, seed, JSON-mode, or undocumented token-limit parameters.

`--model` is mandatory in live mode. Record requested and returned model strings verbatim. Prefer an account-available fixed identifier when one is confirmed, but do not invent a supported version. Default identity policy requires returned=requested. For a documented alias resolution, an explicit reviewed `--expected-returned-model` may name the acceptable returned ID; freeze that value before capture. Any other model value invalidates the response, aborts further requests, and marks the session incomplete. `jev-latest` is allowed for exploratory capture and prominently marked mutable. Even a fixed name does not prove immutable weights; label provider reproducibility as unverified. No undocumented model-list endpoint is required; the operator can use the official console/SDK to check availability.

Local protective bounds, explicitly not vendor limits: 128 KiB serialized request bytes, 1 MiB response bytes, at most 8 questions per request, 1 live request at a time, and a required `--max-attempts` run cap (including retries). Never truncate evidence or drop questions to fit. Mark oversized packets `needs_repack` without inference; curate smaller cases and give them new hashes. Invalid UTF-8 or unsupported structures fail locally.

Timeouts: 5 seconds connect, 20 seconds read/write, and 60 seconds total per packet including retries/backoff. Use a monotonic deadline, clamp each operation/backoff to remaining time, and wrap only the owned HTTP connection lifecycle in stdlib `Timeout.timeout(remaining)` so repeated small reads cannot reset the whole deadline. Ensure connection closure on timeout/cancellation; keep ledger/file writes outside that timeout scope. Request identity encoding, reject unsupported response encodings, and stream the response through the byte counter; Content-Length is an early check, not the only bound. HTTP redirects are errors; never forward authorization to a redirected host. Keep the endpoint fixed; tests inject a fake transport. API credentials and environment dumps never appear in reports, diagnostics, captures, or fixtures. Do not log raw HTTP errors or provider response headers/bodies that may echo authorization; persist a bounded sanitized category/status only for errors.

At most two retries after the first attempt, only for HTTP 429 and 529, under the packet deadline and run cap. Honor a valid Retry-After duration/date if it fits the remaining deadline; otherwise stop and record rate-limited/overloaded. Without it, bounded exponential delay 0.5s then 1s plus up to 0.25s jitter. Do not retry 401/403/422, malformed success responses, or ambiguous transport timeouts automatically; a retry could incur duplicate inference cost. Disable Net::HTTP implicit retries. Other statuses remain explicit errors until justified by evidence.

Write and fsync an attempt-start ledger entry before each network attempt and a completion/error entry after it; stop if persistence fails. Count errors/retries toward the run cap. On resume, the original cap is a lifetime session cap and consumed starts count even without completions; increasing the cap requires a new explicit recorded limit. Record attempted requests, actual returned usage, response model, HTTP status, and monotonic latency; unknown token usage remains unknown. A dollar estimate requires explicit rates and their provenance date. Request-byte bounds are not an exact tokenizer or dollar budget; the tool must not promise a hard spend ceiling. Use a provider-side quota if a monetary ceiling is required.

Validate that all expected answer IDs/types are present with no extra answer IDs, all choices belong to their criteria, probabilities have exactly the expected option keys and finite values in [0,1] summing to 1 within 1e-5, confidence is finite in [0,1], and usage fields are nonnegative integers. Chosen option must be one of the maximum-probability options within numeric tolerance. Ignore unknown provider metadata; persist only allowlisted validated model/answers/usage fields, not raw HTTP bodies or headers. Missing or inconsistent semantic fields invalidate the response. Transport errors remain separate from model abstention.

## 9. Capture, replay, and privacy

Canonical requests recursively sort object keys while preserving arrays and strings. Hash the exact UTF-8 bytes sent. A result key binds schema, profile/rubric version, full request digest, evidence/selection hashes, and capture session. Local IDs/labels do not influence inference or the request digest.

Offline evaluation requires an explicit capture file/directory; it never falls back to live calls on a cache miss. Live mode creates a new session and never silently reuses earlier inference. Resume is explicit, limited to the same frozen manifest/config/session, and skips only completed, validated request digests. Attempt-start entries without completion are `interrupted_unknown`, consume the attempt budget, and require an explicit rerun decision; do not quietly replay them. Mutable-alias sessions resumed on a later date are marked mixed-time exploratory evidence and excluded from final promotion comparisons.

Write results atomically through same-directory temporary files and rename. Use one exclusive session lock; competing writers fail. Store local files mode 0600 and session directories 0700. Failed or partial responses are not success-cache entries. Preserve interrupted ledgers and produce an incomplete report when possible.

Initial live captures accept only the curated public Woods/fictional fixture corpus, with a manifest declaration that its contents were reviewed for transmission. Source leaves the machine in live mode. A dry-run writes the exact outgoing requests and shows byte counts, endpoint, model, case count, and maximum attempts. Explicit `capture --live` is the transmission action; no extra interactive approval loop is needed. No live host index, Console records, credentials, or arbitrary app source is included. Broader private-source use is a separate scope decision.

## 10. CLI, reports, and failure policy

Proposed commands, after implementation:

```bash
bundle exec ruby script/typesafe/cli.rb validate --corpus spec/fixtures/typesafe/corpus.json
bundle exec ruby script/typesafe/cli.rb prepare --corpus spec/fixtures/typesafe/corpus.json --model <available-model> --out tmp/typesafe/prepared
bundle exec ruby script/typesafe/cli.rb evaluate --corpus spec/fixtures/typesafe/corpus.json --baseline-only --out tmp/typesafe/baseline
bundle exec ruby script/typesafe/cli.rb capture --prepared tmp/typesafe/prepared --live --model <available-model> --max-attempts 40 --out tmp/typesafe/capture-001
bundle exec ruby script/typesafe/cli.rb evaluate --corpus spec/fixtures/typesafe/corpus.json --capture tmp/typesafe/capture-001 --out tmp/typesafe/report
```

`prepare` validates and emits a manifest-bound preview only; it requires no key. Preparation must include the requested/expected-returned model configuration so its request bytes are final; accept the same `--model` and optional `--expected-returned-model` flags there. `capture` verifies prepared bytes/config match its flags before transmission and refuses changed files. `evaluate` requires exact corpus/request/result provenance matches. All output paths must be outside tracked source/fixtures; resolve real parent paths, reject symlink escapes into source/corpus, and refuse overwriting an existing capture unless explicit resume semantics apply. Reports are JSON plus Markdown, with paths to the exact local input evidence and capture artifacts.

Exit codes: 0 = command completed and every selected case has a valid result (including semantic abstention); 2 = invalid arguments/input/provenance; 3 = incomplete operational run (API error, interrupted attempt, missing capture, oversized packet). Findings never make exit nonzero. Labels disputed/unavailable are shown as unscored and excluded from quality denominators, not silently dropped. Report selected/attempted/completed/scored/abstained/error/unscored counts separately. CLI default/help is offline; no key or network access during validate/prepare/evaluate.

Per-case report: profile, local case/family IDs, scoped question, evidence refs, raw verdict/distribution/confidence, effective assessment, deterministic completeness/execution facts, error category, capture identity, and elapsed/usage data. Aggregate report separates profiles and partitions and states `advisory; not proof of coverage or correctness`. Replay of identical inputs/capture yields byte-identical report content; report-generation timestamps and freshly measured preparation/replay durations go in a separate run envelope. Captured session elapsed/retry/backoff timings are immutable capture facts and stay reproducible in the report. All workflow timings are reported separately from API latency.

## 11. Evaluation and advancement decision

### Baseline definitions

Freeze baseline code and parameters with the corpus. Baselines run on the same provider-visible evidence plus explicitly local ownership mappings, never gold labels except the development-only majority fit. Definitions below are deliberately cheap heuristics, not semantic proofs.

| Baseline | Verdict and ranking score |
|---|---|
| Assertion lexical | Extract distinct Ruby-shaped constant tokens with `[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*` from implementation vs example/helper evidence. `overlap` is a nonempty intersection. `expectation` means literal `expect(` / `expect (` or `is_expected` in example/helper content. `decisive` means expectation plus a `.to` or `.not_to` followed by one of `eq`, `eql`, `equal`, `match`, `include`, `contain_exactly`, `match_array`, `raise_error`, `change`, `receive`, `have_received`, allowing whitespace/parentheses. No Ruby evaluation. If no expectation: `absent_in_packet`, finding score 1. If overlap and decisive: `direct`, score 0. If overlap and other expectation: `weak`, score .75. Otherwise `insufficient_context`, score .25. Comments/strings can fool this intentionally simple baseline; test names are not ground truth. |
| Benchmark ownership | Reviewed changed-path→benchmark map match: `direct`, recommendation score 1; otherwise `irrelevant`, score 0. Freeze mappings before holdout. |
| Benchmark source reference | Nonempty intersection of the same constant-token extraction from changed implementation and benchmark source: `direct`, score 1; otherwise `irrelevant`, score 0. |
| Invariant abstain | Always `insufficient_context`, finding score 0. |
| Claim deterministic | Any supplied structured numeric equality/comparison failing exact recomputation: `contradicted`, score 1. Otherwise any failed declared normalized quote match: `insufficient_context`, score .5. Otherwise `insufficient_context`, score 0. A quote mismatch is not called fabricated or contradicted. No claimed entailment from a matching quote. |
| Development majority | Most frequent development gold class per profile; lexical class-name ties. Emit its one-hot distribution for every case and derive the appropriate finding/recommendation score using the same profile rule as the model. Never refit on holdout. |

The matcher recognition is lexical, limited to the listed forms; unsupported RSpec styles produce the documented fallback, not inferred support. For claims, numeric evidence is explicit typed operands/operator/result in local schema, and quote normalization only collapses whitespace and maps curly quotes to straight equivalents. General arithmetic extraction from prose is out of scope. Deterministic precheck results appear independently from semantic judgments.

Choose the comparison baseline per profile using development recall at its declared budget (macro per-change direct recall for benchmark recommendation; finding recall for the other profiles), then precision, then lexical baseline ID; freeze its ID before holdout. Report every baseline's holdout result but do not select the winning comparator afterward. Also show an unlimited flag-all/recommend-all reference with its actual review volume; it is not a budget-matched comparator.

### Task-specific metrics

For assertion/invariant/claim profiles, positive findings are respectively gold `weak` or `absent_in_packet`; `violated_for_scenario`; and `contradicted` or `unsupported_in_packet`. Rank by summed probability of those classes. Use the top `ceil(.20 * N)` cases per profile, where N is complete, labelled, successfully evaluated packets; identical eligibility and budget for all comparators. Tie by opaque case ID. Confidence remains a separate distribution statistic, never correctness probability.

Benchmark applicability means recommending useful benchmarks. Rank by `P(direct)` within each local review group, and recommend `min(2, candidate_count)` benchmarks per change. Positive = gold `direct`. Report micro precision/recall over those recommendations, macro per-change recall over groups with >=1 direct candidate, recommendation count per change, direct→irrelevant false exclusions, and abstention. Zero-positive groups report false recommendations and precision, with recall undefined. Candidate sets and budget are identical for model/baselines; known-incomplete candidates route separately. This measures judgment conditional on supplied candidates, not benchmark-discovery recall.

Report per-profile confusion matrices, class counts, raw false-assurance rate (raw direct/supported/preserved verdict among gold adverse cases), false alarms on clean cases, abstention, and known-incomplete routing. `insufficient_context` gold cases form their own stratum and are not counted as clean/adverse. Keep raw model output even when deterministic completeness forces `needs_context`.

Successful-case metrics are descriptive. Also compute intent-to-evaluate metrics over every frozen, complete, labelled selected case/group: operationally failed candidates have score negative infinity, are never a useful selection, and consume unrecovered slots if fewer valid predictions remain; the budget is based on the full intended set. Compute precision as useful selected positives / declared slots, recall as useful positives / all intended positives. For baselines in this view use their actual available offline predictions; do not mask them to the model's failed subset. Missing responses remain in intended denominators and prevent advancement; incomplete rankings are descriptive. Report failure distributions by class/profile, oversized packets, and missing captures. Final advancement uses this intent-to-evaluate view and requires no unresolved operational failures.

### Held-out decision

Before any routine advisory adoption, require at least 30 independent held-out families per considered profile, with >=10 distinct families contributing adverse/relevant cases and >=10 contributing clean/irrelevant cases; the same paired family may contribute to both counts. Include context omissions separately. This is a feasibility minimum, not a reliability guarantee. Freeze all thresholds and inclusion rules before holdout.

Packet contributions are unweighted, with counts per family disclosed. Resample families with replacement using fixed seed 1729 and 2,000 samples; retain every variant/group in each sampled family. Use identical family multisets for model and baseline, recompute each budget/ranking within that multiset, and suffix copied IDs by sample occurrence only for deterministic ties. Report percentile 95% intervals of paired recall change. Historical pairs and benchmark groups never split during resampling. Undefined metric replicates are counted and reported; if over 5% are undefined, advancement is inconclusive. Do not pool profiles.

Assertion/invariant/claim advancement requires finding precision >=.80 at the fixed budget, positive lower 95% interval bound for recall change versus the frozen development-selected baseline, raw false-assurance rate <=.05, and no positive effective assessment for explicitly incomplete cases. Benchmark advancement separately requires recommendation precision >=.80, positive lower bound on macro per-change direct-recall improvement at the fixed two-benchmark budget, and no direct→irrelevant errors on the frozen critical workload sentinel set. Sentinels and their labels are declared before holdout and remain ordinary reported cases; no post-hoc exceptions. These are conservative engineering criteria for optional advisory use, not vendor guarantees. Report all failures, including profiles that cannot pass such a small recommendation budget.

Also report attempted calls, unknown usage, service errors, total elapsed/backoff/preparation/replay time and API p50/p95. Reviewer effort is measured only if an explicit timed human review study is run; otherwise recommendation count is merely a burden proxy. Maintainer review must find operational cost acceptable. Inconclusive/failed results keep a profile experimental or retire it; do not loosen criteria based on holdout.

This advancement only enables an optional advisory workflow. Any automated CI semantic gate, test-selection authority, or runtime integration requires a new design and a larger risk-specific evaluation. A small green demo never becomes a safety claim.

## 12. Implementation sequence and checks

1. **Offline data contracts and packet preparation.** Write failing specs for provenance, path/blob validation, overlays, missing helpers, outgoing-field leakage, bounds, and offline operation. Implement corpus/evidence/request modules, the assertion profile, and `validate`/`prepare`. Deliver its 24–30 reviewed development cases and explicit disputed/unavailable examples.
2. **Replay, baselines, metrics, and reports.** Write fixtures for correct/error/abstaining synthetic responses; implement evaluator/report and baseline-only commands. Test exact confusion/ranking denominators, grouping, duplicate families, frozen split manifests, resampling reproducibility, invalid capture rejection, and all-abstain/empty-class cases. No API calls.
3. **HTTP adapter and explicit capture.** First add fake-transport specs for authorization redaction, endpoint restrictions, status policy, response bounds/validation, retries/deadlines, budgets including incomplete attempts, cancellation, resume, exclusive lock, atomic writes, and mutable model provenance. Implement live capture. Offline integration tests assert no networking and no source execution.
4. **Oracle and corpus expansion.** Execute selected historical regressions/mutations manually in disposable worktrees; import independently classified artifacts. Build the needed held-out families and review labels/closure. Freeze the first quality-evaluation manifest before inference.
5. **Live feasibility and decision.** With a configured key and selected account model, preview then explicitly capture development cases; revise only on development evidence. Freeze rubric/model/session policy, capture holdout, and report against predeclared criteria. Preserve unfavorable cases. Produce an adopt/iterate/retire decision per profile, not a blanket vendor endorsement.
6. **Optional advisory workflow and later profiles.** Only for a passing profile, document a maintainer invocation and show reports alongside existing review. Keep normal CI offline. Add benchmark, invariant, and claim profiles in separate subsequent PRs, each repeating corpus/label/replay/live-evaluation steps with its own smoke and held-out sets. Any future automatic packet selection must measure evidence-selection recall separately from judge quality before expanding scope.

Each implementation PR adds failing behavioral specs before code, then runs focused specs, `bin/rake spec`, and `bin/rubocop`. The new `script/**/*.rb` files are linted by the current config, unlike excluded `bench/**`. Specs under `spec/development/typesafe/` run in the ordinary offline suite. Do not inflate `lib/**` coverage by adding synthetic library loads; this tool is outside the measured runtime library.

Verify `Gem::Specification.load('woods.gemspec').files` contains none of the new tool/corpus/plan files, and run the existing gemspec and public-surface contract specs. Public-surface inventory should remain byte-identical; verify using `release_v2:verify_surface_inventory`. Inspect plugin skills before completion; no skill edit/version bump is expected because installed-gem behavior is unchanged. If implementation changes a packaged surface, stop expanding that PR and apply the repository's canonical docs, inventory, plugin, changelog and release-flow rules explicitly.

Booted/live-backend lanes are unnecessary for the standalone tool itself, but required for oracle cases that claim those behaviors. Record unavailable dependencies rather than broadly updating them. No default CI calls to TypeSafe, no required secret, and no wall-clock API quality gate. Full runtime suite/lint are not needed for this planning-only document; implementation must run them.

## 13. Risks, rollback, and completion

Main risks are incomplete evidence, label leakage, narrow fixtures, correlated reviewer/model errors, hosted model drift, mutable captures, and misleading aggregate metrics. The contracts above make these visible but do not eliminate them. Maintain a case-level error taxonomy: selection/context gap, label dispute, model error, tool defect, service failure, unavailable oracle.

Rollback is removal/disablement of the optional script invocation and deletion of local captures. No index generation, schema migration, host config, secret installation, dependency update, public tool count, or runtime state needs reverting. Preserve evaluation reports if a profile is retired so the same failed experiment is not repeated without new evidence.

Planning completion: every blocking design issue has a written disposition and all review perspectives re-read the revised plan. Implementation completion: offline contracts pass, live failures are honestly represented, oracles/labels/provenance are reproducible at their stated scope, package/public behavior remains unchanged, and each live-evaluated profile has an evidence-backed decision. API access is a prerequisite for measuring quality, not a prerequisite for implementing and testing the offline tool.

## 14. Sources and review record

Live sources consulted 2026-09-16:

- [Skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md) and installed `~/.agents/skills/typesafe-ai/SKILL.md`.
- [HTTP API](https://docs.typesafe.ai/api), [Choice](https://docs.typesafe.ai/primitives/choice), [state](https://docs.typesafe.ai/concepts/state), [confidence](https://docs.typesafe.ai/confidence).
- [Citation checking](https://docs.typesafe.ai/cookbooks/citation_check), [verification cascade](https://docs.typesafe.ai/cookbooks/sde_cascade), [composite scoring](https://docs.typesafe.ai/patterns/composite-scoring).
- [Entity alignment](https://docs.typesafe.ai/cookbooks/entity_alignment), [hierarchical classification](https://docs.typesafe.ai/cookbooks/hierarchical_classification), [feature discovery](https://docs.typesafe.ai/cookbooks/autoresearch_feature_discovery).
- [SDK retry behavior](https://docs.typesafe.ai/sdk/python/api/retries) is reference material; our Ruby client's narrower retry policy above is an explicit local decision.

Repository evidence: `CONTRIBUTING.md`, `CLAUDE.md`, `woods.gemspec`, `spec/spec_helper.rb`, `.github/workflows/ci.yml`, `.github/workflows/perf.yml`, `docs/EVALUATION.md`, `bench/evaluation/runner.rb`, representative specs/benchmarks named above, and `plugin/skills/woods-investigate/SKILL.md` / `woods-diagnose/SKILL.md`.

Review history is maintained in the companion `2026-09-16-typesafe-development-evaluation-review.md`. The environment allows only three other agent threads; the fourth review perspective is the author/root agent's API/operations audit and is not represented as an independent reviewer.


## 15. First implementation milestone after live smoke trials

2026-09-16: the reviewed revision-3 design above remains the full target. Implementation now starts with a smaller development-only slice under `script/typesafe/`, documented in its README. The earlier single-family smoke and four-family assertion trial are development evidence, not holdout results.

Independent review of the follow-on experiment required an explicit conservative composition rule, a standalone comparator for every scored packet, and blind review of exactly the outgoing evidence. The initial revised pilot has four new families and 16 packets, with isolated real implementation mutations. It allocates 16 standalone Choices, 16 five-question batches, 16 individual Noul calls on four selected packets, and eight exact repeats: 56 requests, no automatic retries.

The four added Nouls cover missing helpers, scenario execution, the entire invariant, and wrong-result assertions. Their initial policy only vetoes a raw direct verdict into review; it never promotes a verdict. Report raw accuracy, raw/effective false reassurance, correct-direct retention, and review volume separately. Thresholds are exploratory and frozen before this development run. The full advancement contract above remains unchanged.

This milestone supplies offline response/replay validation and a report CLI. It does not yet supply the planned complete corpus/provenance validation, capture/resume CLI, baseline selection, family bootstrap, or held-out adoption evaluation. Those remain required before broader integration. Source-only files remain outside the gem and no default test needs TypeSafe credentials or network access.

### First milestone result and revised continuation

All 56 requests completed against `jev-1.13.0`. Blind-reviewed labels agreed on all 16 development packets. Standalone Choice matched 15/16; batched Choice matched 16/16, including one near-tie that does not establish a batching accuracy gain. Neither arm falsely marked evidence direct. The frozen conservative veto routed all four correct batched-direct cases to review, retaining zero: it showed added burden without demonstrated false-assurance benefit. Do not advance that rule or retune its thresholds against this result as if validated.

The replay implementation preserves the failed policy for reproducibility. Prioritize a separately scoped documentation/PR claim-support pilot next, before expanding decomposition to 24 families. Continue the same requirements for deterministic checks, blinded labels, actual evidence and independent holdout; all larger evaluator/provenance work remains outstanding. This recommendation changes experiment order, not the gem or adoption criteria.


## 16. Claim-support development pilot

The next experiment completed 2026-09-16: 24 constructed claims across six families (three code, three documentation), with independent pre-inference labels and pinned source-excerpt verification. TypeSafe matched 23/24 labels, correctly supported all six positive claims, and falsely supported none of the 18 others. It called one unproven universal workflow claim contradicted rather than unsupported. This distinction remains a reported error, not a label revision.

Six instruction-injection variants and six exact repeats retained their verdicts. An adaptive six-case follow-up removed explicit omission notes; five remained insufficient-context and one became unsupported. Both batches totaled 42 calls without retries. Quote/arithmetic checks and three narrow code executions ran separately. The exact-substring baseline abstained on everything and does not establish a meaningful comparator advantage.

Continue only with advisory evaluation on untouched real PR/documentation claims, using stronger comparison review and independent labels. These constructed development cases do not satisfy the adoption thresholds or demonstrate general verification/injection resistance. Experiment artifacts remain local under `tmp/typesafe-claim-pilot/`; no packaged feature or claim-support CLI was added.

## 17. Untouched real PR claim comparison

The next development trial selected two verbatim summary sentences from each of the six newest merged PRs in local HEAD history (#352, #351, #350, #349, #346, #345), before evidence review. Packets used pinned before/after code and available issue evidence. A separate coding-agent comparator and reference reviewer completed their annotations before TypeSafe inference. They agreed on all twelve supported-versus-not-established judgments; one unsupported-versus-insufficient dispute was excluded from exact-label scoring before inference.

All 15 requests completed: twelve primary judgments and three fixed repeats. TypeSafe matched 7/11 exact labels and 11/12 support-status judgments; the ordinary coding-agent comparator matched 11/11 and 12/12. TypeSafe retained all six supported cases, but also passed one publication claim that both reviewers considered unestablished in the packet. It called a performance audit claim contradicted despite missing the relevant audit and classified three missing-context cases as unsupported. Three repeat verdicts were stable. Reference labels are agent judgments, not human ground truth, and shared model-family errors may favor the coding-agent comparator.

This trial does not demonstrate a quality advantage or useful review reduction over ordinary review. Keep claim checking experimental; do not introduce an automatic verification gate or tune a cutoff to rescue this result. If continued, prioritize packet completeness and antecedent preservation, then a separately frozen advisory evidence-request experiment on new families. The existing holdout/adoption requirements remain unmet. Results and captures are local under `tmp/typesafe-real-claims/`; no packaged code or normal CI behavior changed.

Follow-up configuration review found no demonstrated API/model/request defect. It identified a comparison confound: coding reviewers received more explicit historical-observation and test-execution instructions than TypeSafe's general instruction against inferring empirical results. The raw binary metric also used the largest individual Choice label: the disputed supported result had probability .39 versus .61 across non-supported classes and confidence .18. No confidence-based product policy was implemented or validated. Preserve the original results, but do not interpret them as a pure model-capability comparison or proof of a confident approval error. Before attributing the gap to TypeSafe limitations, a minimal diagnostic should isolate instruction alignment on unchanged packets; evidence organization can be tested separately. Any improvement remains development evidence and requires fresh validation.

## 18. Controlled instruction, context and narrow-task diagnostics

Completed 2026-09-16: all 68 planned requests succeeded, using two credential lookups and no retries. Before inference, a fresh reviewer annotated exact outgoing requests and a separate design review checked isolation, ambiguity handling and matched denominators. The original real-PR experiment remains unchanged. The new reviewer found genuine taxonomy and scope ambiguity, including a supposedly positive graph control that can describe either a mechanism or a historical observation; this prevents treating aggregate score differences as objective correctness improvements.

Stage A compared original versus reviewer-aligned historical-evidence instructions on seven unchanged packets with one repeat each (28 calls). On matched unambiguous cases, exact agreement was 3/4 versus 4/4 on the first pass and 4/4 in both arms on the repeat; binary agreement was 5/6 versus 6/6, then 6/6 in both arms. The disputed publication claim's supported probability fell from .39/.37 under the original question to .06/.07 under aligned instructions. Original near-tie winners changed on two repeats. This demonstrates instruction sensitivity on known cases, not a replicated population accuracy gain.

Stage B added adjacent PR narrative solely for interpretation, with the same context-enabled aligned question in both arms (28 calls). No selected verdict changed on either pass. Both arms matched 4/4 exact and 5/5 binary judgments eligible in both arms; ambiguous cases remained visible but unscored. This does not establish that contextual evidence or retrieval quality is irrelevant.

Distributions did change under added context: the uniquely supported control's supported probability fell from .93/.94 to .73/.73, with confidence .91 to .63 on both passes, while its verdict stayed supported. This is a repeatable sensitivity observation, not a measured accuracy regression or gate failure.

Stage C, prepared before A/B outputs and activated afterward, separated code implication from historical-record presence using two independent Nouls on six constructed states with exact reused evidence arrays (12 calls including repeats). Each dimension had three positive and three negative controls. All twelve primary judgments matched independently reviewed references; all twelve repeat labels agreed. This tests what implementation and supplied records establish at a narrow scope, not whether historical events independently happened. Changing task and primitive together prevents attributing success specifically to Noul.

The diagnostic sequence is exhausted. Retain focused judgments as experimental components; broad PR verification remains outside automatic acceptance and normal CI. New-code utility is still unmeasured. A distinct prospective next test could compare selection of implementation/spec examples before already-approved feature work, with equal candidate sets, ordinary-agent comparison, executable acceptance checks and total preparation/authoring effort. No production feature should be invented solely for that experiment. The holdout/adoption requirements remain unchanged. Local evidence is under `tmp/typesafe-controlled-followup/` and `tmp/typesafe-narrow-followup/`; no packaged behavior changed.

## 19. Prospective context-selection pilot and operational stop

Reviewed and attempted 2026-09-16. The selected task was the already-planned, source-only `Evidence.read(root:, manifest:)` loader: strict manifest validation, confined regular-file reads, bounded bytes, UTF-8, SHA-256 and typed failures. Stimulus and seed extraction were rejected before selection because their public extraction scope was too broad. This did not invent a production feature for the experiment, and no evidence-reader implementation was written.

Before either selector ran, reviewers froze a complete task contract, ten implementation/spec packets, candidate mechanism/pitfall annotations and independent acceptance checks. The checker has 116 behavioral cases, 17/17 harness-health checks and an observed missing-API baseline failure; that baseline is not 116 individually observed behavior failures. Its author disclosed incidental exposure to the unscored candidate responsibility table, without reading candidate source or selector outputs. Runtime/auditing and actual Ruby 3.0 limitations remain explicit in its review.

All 73 source excerpts were verified against HEAD `55a74ea4f3a7c3e798493a92663003aab85a2301`. Two omitted helper/declaration spans were repaired before selection. Preserving complete packets required prospectively increasing the shared allowance from 12,000 to 13,000 bytes per packet and 36,000 to 39,000 optional bytes per author. The final pool was 84,680 bytes. Both selectors received identical mandatory context and packet bytes; reference annotations and hidden checks remained separate. These are byte budgets, not token estimates.

The ordinary agent jointly selected at most three examples. TypeSafe's frozen policy used ten independent Nouls in one shared-state request, selected at most three first-pass values strictly above 0.5, and broke exact ties by ID. An exact second batch was diagnostic only. Batching replaced the earlier separate-request proposal before inference. The symmetric authoring gate compared semantic signatures under every preserved annotation mapping and would advance on any unambiguous difference, regardless of which arm appeared preferable. This compares complete selection policies, not isolated model capability.

The ordinary selector chose E01 and E05 (locale/UTF-8 regression and resolved-root/symlink examples) in 105.58 seconds to its output file. Exact provider model identity and token usage were not exposed by its orchestration. TypeSafe's 180,409-byte primary request to `jev-1.13.0` returned HTTP 400 after 591.35 ms, with no usable answers. The runner stopped without retry or repeat, so **the pilot is an operational failure; context-selection quality and new-code benefit remain unmeasured**. No paired authoring began. A local 256 KiB request cap did not establish provider acceptance. The original runner discarded the error body, so that capture cannot identify the cause.

A separately reviewed operational diagnosis then tested harmless marker questions without retaining probabilities. A 1,247-byte state/request with ten questions succeeded (HTTP 200, ten validated answers, 525 input and 185 output tokens). The exact original state with one marker question failed (170,033 bytes, HTTP 400). The conditional third probe was not sent. This demonstrates small-state ten-question support and implicates the full-state size/content/representation path; it does not establish an exact context limit or prove the original cause. No diagnostic error category survived the strict allowlist. Marker wording and omission of the original criteria prevent treating these probes as a selection rerun.

Across the failed primary and separate diagnosis: three HTTP requests, two once-per-batch credential lookups, no retries, one small marker success and zero selection results. Failed-request usage/cost is unknown. Credentials stayed in process memory. Original freezes, request, baseline and failed capture remain unchanged under `tmp/typesafe-context-pilot/`, alongside the protocol, reviews, acceptance checks and result report. The existing replay and release metadata preflight passed 50 examples with no failures. No executable source changed, so the full Woods suite/lint and runtime lanes were not rerun for these research artifacts.

Revised continuation: first establish an accepted compact request envelope, using a short task brief and bounded code/spec snippets with full provenance metadata retained in an offline sidecar. Give both selectors identical compact evidence and hydrate selected IDs to complete source context for authors. This needs a new prospective review/freeze and must preserve the failed original trial; do not silently crop and retry it. Reusing this task is development work with a known baseline selection, not a fresh holdout. Reuse the acceptance work if the task remains needed, and perform paired coding only after successful selection and the symmetric difference gate. Substantial shared preparation effort is a real workflow cost. Keep TypeSafe experimental, with no production dependency, automatic acceptance or CI gate; the original holdout/adoption requirements remain unmet.

## 20. Compact context-selection retry and offline reader

Completed 2026-09-16. A separately reviewed retry retained the same exposed development task and ten candidate identities, using 41 verified source/spec spans in compact cards. Both selectors received identical cards, the complete task, and a concise inventory of mandatory author context; full provenance stayed offline. The primary request was 24,471 bytes instead of 180,409. Compaction changed visible content as well as representation and size, so its success does not establish the original HTTP 400 cause or a provider limit.

An operational marker preflight succeeded; its answer was discarded. A new ordinary selector then chose E01/E05/E06 (locale regression and two path-containment examples). TypeSafe chose E06/E05/E09 (the same path examples and a metadata validator). Its exact repeat preserved all ten threshold decisions and the selected set, with maximum probability change .03. Both annotation mappings required paired coding. The policy remained joint ordinary selection versus independent Nouls and deterministic top-three selection, without threshold tuning or portfolio repair. These subjective selections have no gold usefulness labels.

All three retry requests returned HTTP 200 with validated `jev-1.13.0` answers: 19,700 input and 388 output tokens including preflight, or 13,350/368 for primary plus repeat. One credential lookup supplied the batch entirely in process memory. Primary and repeat HTTP times were 437.98 and 385.69 ms; the ordinary selector took 38.10 seconds to its output file, with provider identity/token usage unavailable. At the published $0.042 per million input tokens and free output, the primary selection is approximately **$0.00028035** and the entire retry **$0.0008274**. These are API estimates, not invoice verification. The very low selection cost is a credible economic opportunity even without superior code; missing comparator usage prevents quantifying savings. One-time research preparation must be reported separately from recurring packet construction, authoring and review. See section 21.

Two fresh authors received the same full common context and their selected original full packets, with no selector rationales, scores or compact cards. Both started from the same HEAD and untracked overlay, under the same inherited model/settings, with concurrent 20-minute budgets. Delivered optional contexts were 23,993 bytes for ordinary selection and 28,968 for TypeSafe, within the same 39,000-byte allowance. Isolation relied on explicit instructions and activity logs, not an OS sandbox. Both logs report using their supplied examples without independently discovering the other arm's examples.

Both first submissions froze before their deadlines, with no unowned source changes. The unchanged independent checker passed **116/116 behavioral cases in each arm**. The ordinary-context author added 114 examples; the TypeSafe-context author added 84. Their final full suites passed 8,351 and 8,321 examples respectively, with zero failures and the same three existing optional-tokenizer pending examples. The coordinator independently repeated both complete suites, focused checks, full RuboCop, release contract specs, package exclusion and public-surface inventory verification; all passed without modifying either submission. A reviewer blind to arm provenance found no material contract violations or integration blockers; root review agreed.

Under the predeclared rule, **both succeeded: no completion advantage for TypeSafe was demonstrated**. This is one reused development task with two authors and agent-based review, not a replicated or held-out estimate. No speed, accuracy, context-quality or review-reduction benefit follows from stable selections, example counts, or a small timing difference. The same mandatory context, overlapping selected examples, ordinary repository access and shared model-family review further limit attribution.

Integrated the TypeSafe-context author's `Evidence.read` source and specs byte-for-byte after the blind reviewer narrowly preferred its fixed, useful error messages and suppression of wrapped exception causes. The ordinary-context implementation was also viable; this maintenance preference is separate from the experimental outcome. No post-submission code repairs were needed. The reader validates materialized local bytes and hashes, not source lineage; it remains an offline source-checkout API without CLI integration. README status was merged with the existing experiment history.

Keep TypeSafe experimental and retain ordinary coding/review plus executable checks as the current workflow. The planned retry is exhausted; further tuning on this task would not establish general value. Its combination of a successful coding outcome and negligible selector API cost does justify a fresh cost-efficiency comparison, rather than requiring it to produce better code to count as useful. Section 21 outlines that separate direction. Full provenance/corpus infrastructure remains deferred. No runtime extraction, MCP, packaged task, configuration, plugin, release version, dependency or CI inference changed. Ruby 4.0.6 was exercised; Ruby 3.0 syntax/API compatibility was inspected and linted, but that runtime was not installed. Rails/live-backend lanes do not apply to this isolated reader.

Original failed artifacts remain untouched in `tmp/typesafe-context-pilot/`; retry freezes, exact requests/captures, submissions, independent results, validation logs and blind review are under `tmp/typesafe-context-retry/`. These are local ignored research artifacts, not shipped reproducibility assets or an automated acceptance gate.

## 21. Cost-efficiency as a separate benefit

The user highlighted price after the coding submissions and their independent outcomes were frozen. [TypeSafe's published pricing](https://typesafe.ai/blog/introducing-system-one-models-and-jev), checked 2026-09-16, confirms $0.042 per million input tokens and free output. Do not reinterpret the original completion endpoint, but do not confuse “no completion advantage” with “no economic value.” A selector that preserves acceptable coding outcomes at a much lower recurring cost can be worthwhile.

| Measured retry scope | Input tokens | Estimated API cost |
| --- | ---: | ---: |
| One primary selection of ten candidates | 6,675 | $0.00028035 |
| Primary plus diagnostic repeat | 13,350 | $0.0005607 |
| Entire compact retry including preflight | 19,700 | $0.0008274 |
| 1,000 primary selections with the same token volume | 6,675,000 | $0.28035 |

These multiply observed usage by the published input rate; output is free. They exclude earlier failed requests with unknown usage and are not account invoices. A production estimate would normally use one selection, not the research preflight/repeat schedule. The ordinary selector's tokens, actual billing and subscription-meter impact were not exposed, so no savings ratio can be calculated. The 437.98 ms HTTP observation also cannot be compared directly with a 38.10-second whole agent turn as an isolated model benchmark.

Recommended next direction: evaluate TypeSafe as a low-cost substitute for repeated bounded context-selection or triage decisions, with ordinary agents retaining code generation and consequential review. Favor automatically generated, reusable candidate cards from Woods' index over manually preparing a new dossier for every call. The present cards were curated and are not yet such an automated pipeline. Cheap inference also makes batched screening of many candidate examples attractive, but larger candidate coverage and selection quality still need testing.

A new prospective study should:

1. Use fresh, already-needed coding tasks and compare TypeSafe selection, ordinary-agent selection, and a cheap deterministic/no-semantic-selector baseline on identical candidate availability. Preserve independent behavioral acceptance and blind code review. Predeclare the quality floor, acceptable noninferiority margin and adequately supported task-family sample size before observing outcomes; one success per arm cannot establish equivalence. Cheap failures do not satisfy that quality constraint.
2. Capture actual selector input/output/cache usage and applicable rates, plus authoring, repair, escalation and review costs. Report recurring context construction and failed calls. Separate paid API charges from subscription capacity and wall time; do not invent a marginal cash cost for an already-paid subscription.
3. Separate one-time harness/curation/research effort from recurring operation, disclose an explicit amortization volume, and report both total experiment expense and estimated steady-state cost. Do not charge duplicated research comparisons to every future TypeSafe invocation, or assume manual packet preparation disappears for free. The larger selected context in the TypeSafe arm could affect downstream author costs; bytes alone do not measure those tokens.
4. Compare cost per independently accepted task subject to the fixed quality constraint. TypeSafe can qualify through lower total cost at acceptable quality; it need not beat the stronger model's raw accuracy. Its selection-stage break-even is the displaced ordinary selection cost exceeding $0.00028035 plus incremental preparation, downstream context, escalation and maintenance costs at this observed token volume. Repeating both selectors on every ordinary task would add cost rather than replace that expense.

This is a new economic hypothesis and proposed evaluation direction, not a retrospectively passed adoption gate. Existing profile decisions and holdout requirements remain intact until a separate cost-focused protocol is prospectively reviewed and frozen. The current evidence supports **promising low-cost context selection**, with successful feasibility and unmeasured end-to-end savings, rather than either routine adoption or dismissal for failing to produce better code.
