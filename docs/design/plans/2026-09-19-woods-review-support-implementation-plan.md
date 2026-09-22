# Woods review support: proposed changes and implementation plan

2026-09-19. Baseline: `2885f7550f2ee58f627806f73c86feb7aea5e1d7`.
This plan covers the Woods gem and our existing `script/typesafe/` development
tooling. The admin application is the code under review; a Claude Code agent invokes
a standalone CLI runner. The receiving agent owns that project's runner integration
and private trial fixtures. No application UI, background job, database tables, or
in-process Rails integration are part of this plan. The final feedback was delivered
first in `2026-09-19-admin-jev-final-feedback.md`; both documents now incorporate
the corrected CLI execution boundary.

**Recommended order: correct the documentation, strengthen the reusable evidence
and request contracts, and make callback-analysis coverage explicit.** Keep the
admin pilot independent of these improvements. These are proposed changes; this
turn does not implement them or start paid inference.

## Current implementation and concrete gaps

| Existing component | What it already does | Gap this work should address |
|---|---|---|
| `ModelExtractor` and its reference guide | Publishes enriched model source and metadata-derived chunks | The guide incorrectly promises dedicated scope/method source chunks from this builder. |
| `CallbackAnalyzer` | Detects patterns in a located callback body | Missing method, unparseable source, unsupported filter, and no detected effects can yield the same empty arrays; analyzed bodies and unexpanded calls are not disclosed. |
| `ReviewPacket` | Pins a numbered generation, preserves typed identities, exact selected physical files, full unit data, and artifact hashes | No explicit review snapshot/range, built-in source-freshness result, or per-question evidence ledger. Its 8MiB byte ceiling is not a Jev request-token budget. |
| `ExtractionReceipt` | Checks declared local source/producer/index bytes around a capture | Does not authenticate Git identity or implement the newer built-in source-freshness contract. Keep its historical meaning separate. |
| `GraphEvidence` | Preserves typed graph records and validates explicit-root paths; deliberately refuses an ambient `Rails.root` | This boundary already suits the standalone CLI. Preserve it rather than adding in-process Rails support. |
| `Response`, `Replay`, `Profiles` | Strict offline validation/replay for the frozen assertion experiment | Score answers are unsupported, the profile/state shape is fixed, and requested/returned model IDs must match exactly. These are intentional experiment boundaries, not a general bank runner. |
| Existing fixtures and Rails testbed captures | Supply portable regression examples and previously verified runtime evidence | The six portable candidates are three generic Ruby families. They do not establish effectiveness of the Rails question bank on the admin application. |

The experimental scripts/specs are currently untracked alongside substantial
existing research material. Preserve all unrelated work and explicitly select
the files belonging to each change. Recheck HEAD and adjacent-session work before
implementation; this plan is not evidence that those files remain unchanged later.

## Proposed change list

| Order | Change | Scope | Completion evidence |
|---|---|---|---|
| 1 | Correct the model-chunk documentation and explain its limits | Woods docs | Claims match actual emitted payloads and the separate source chunker. |
| 2 | Add snapshot identity and a three-part ledger to a versioned review packet | Development tooling | Stale, mismatched, missing, and current evidence remain distinguishable; v1 behavior survives. |
| 3 | Add request assembly and general typed-response validation for review trials | Development tooling | Relevant source survives; Score/Choice/Noul and partial/error runs have explicit handling. |
| 4 | Publish bounded callback-analysis provenance | Woods extraction | Located/unknown/failed analysis differs visibly; existing effect semantics remain documented. |
| 5 | Add a reusable workflow evaluation record and public Rails smoke cases | Development tooling/testbed | Reports total effort, confirmed findings, false leads, and no-finding runs without label leakage. |
| 6 | Update agent guidance and publish a new portable handoff edition | Docs/skills where affected | New capabilities are version-qualified and all exported claims match fresh evidence. |

Steps 2–3 form the shortest tooling path to a useful trial. Step 4 can be a
separate change and must not block the other agent's first admin-app result.

## 1. Correct the chunk contract first

Owned files: `docs/EXTRACTOR_REFERENCE.md`; inspect nearby field-reference claims
and `docs/RETRIEVAL_GUIDE.md` for the same conflation.

Replace the incorrect list with `summary`, `associations`, `callbacks`,
`callback_effects`, and `validations`, explaining conditional emission. State that
these are summaries derived from metadata and do not preserve every body,
condition, validator option, or schema detail. Distinguish the separate source
chunker and the full `source_code` field.

Do not add a test that merely hard-codes a prose sentence. Verify against the
builder and a representative emitted unit. The existing downcase/upcase probe is
useful evidence of the limitation, not a reason to change extraction semantics
inside this documentation fix. No gem version or release-fence edit is needed.

## 2. Introduce a review packet v2 with explicit provenance

Primary files: `script/typesafe/review_packet.rb`, `evidence.rb`,
`export_review_packet.rb`, `REVIEW_PACKETS.md`, and their development specs.
Suggested new responsibilities: `review_snapshot.rb` and `review_ledger.rb`.
Exact filenames can follow the existing organization during implementation.

### Snapshot selection

Support explicit committed-range and captured-working-tree modes. Record what the
range means: direct endpoint comparison or merge-base comparison, selected base,
target revision, and actual materialized content identity. Git commands should use
argument arrays and NUL-safe path handling, with checked exit status.

Keep before and after identities for additions, deletions, renames, and ordinary
edits. A deleted file has no after-body; that is a change record, not a failed file
read or an empty-file substitution. Capture working-tree bytes once and build from
that materialized snapshot so later edits cannot silently alter an in-flight run.
Define whether untracked files are included, and record that choice.

Do not relax the strict v1 evidence schema silently. Add an explicit v2 format or
new snapshot envelope with a deliberate v1 conversion path. Preserve UTF-8, exact
bytes, hashes, typed collisions, and unmapped-file visibility already covered by
the existing specs.

### Pinned freshness and per-check evidence

Use the existing `Woods::SourceInputs::Status` path against the **same payload and
generation** held by `PublishedIndex`; do not perform an independent newest-index
check and attach its result to an older packet. Verify supported APIs/version at
implementation time. Keep missing keys/manifests, scan-budget exhaustion, and
unverified boot boundaries as unknown with their reasons. Do not copy private
freshness keys into exported packets.

Represent separately:

- source freshness and its scope/reasons;
- selected review revision/snapshot identity and its verification;
- question-specific supplied, missing, or unknown context.

Retain the older optional extraction receipt under its existing attestation name.
A v1 receipt should not upgrade a packet into “built-in freshness current.” Emit a
materialized packet digest and record that the source/index checks occurred at
capture time; this is not a guarantee that a live checkout cannot change later.

Release the index lock after materialization, before provider/network work.

### Preserve the standalone CLI boundary

Keep the existing standalone exporter valid. Its current `GraphEvidence` guard is
intentional: `DependencyGraph.from_h` rebases paths through ambient `Rails.root`.
Deleting that guard would hide a provenance problem.

Document standalone invocation with explicit source, index, and output roots.
Keep diagnostics separate from machine-readable output and document exit statuses.
The current development exporter is not packaged with the gem; an adopting project
must deliberately install/vendor the runner or implement its small adapter over
the stable `PublishedIndex` API. Do not require Rails initialization merely to
read the index. No explicit-root graph-loader API expansion is needed for this CLI
scope, and global `Rails.root` must not be mutated as a workaround.

### Acceptance cases

Changed source with identical size/mtime; stale cached index; wrong target SHA;
missing private freshness key; concurrent publication; retained old generation;
deleted/renamed file; Unicode/newline path; dirty current source versus committed
diff; unavailable helper; old v1 packet/receipt. A failure must not produce a
misleading current/complete packet or silently drop a changed path.

## 3. Build review requests without rewriting the old experiment

Primary existing files: `response.rb`, `replay.rb`, `profiles.rb`, `cli.rb` and
development specs. Add a separate bank/request/run layer, rather than expanding
the frozen assertion profile until its original results change meaning.

### Bank and state preparation

Accept a versioned externally supplied bank. Validate unique IDs, primitive type,
primitive-appropriate direction, kind, criteria, target/evidence requirements, and
explicit headline mapping. Do not copy private project prompts or code into the
public repository. Neutral fixtures can exercise the format.

Assemble requests from relevant full source or verified spans plus required
metadata, tests, and helpers. Cover changed DSL/config/migration/deletion cases as
well as method bodies. Keep evidence IDs and physical coordinates separate from
annotated-unit offsets. Summaries can help select context, but cannot stand in for
required implementation evidence.

Batch questions that can share adequate state. Check both provider context limits
using a documented measurement/estimation strategy, and retain usage returned by
the provider. Byte limits remain resource safeguards, not token accounting. Split
by coherent checks or report budget-limited assessment; never silently cut a
method, condition, or assertion tail. Avoid building a general call graph first.

### Answers and run records

Add Score validation against the current provider contract, retaining its raw
levels/distribution and confidence. Preserve Choice/Noul behavior and permit
provider extension fields without inventing required fields on Nouls. Missing,
invalid, and failed answers become explicit run errors or unassessed checks, not
zeros. Keep the old replay schema/profile accepted and unchanged.

Resolve moving model aliases before a comparison or explicitly record requested
and actual model identity in the new run schema. Do not weaken the old replay's
exact-match rule globally merely to accept aliases.

Record each attempt, request hash, model/bank/policy variant, usage, elapsed time,
and response/error. Keep secret loading outside request serialization, and bounded
retry behavior separate from semantic outcomes. Use the configured local credential
mechanism once per CLI invocation rather than repeatedly querying 1Password.

Initially prefer immutable saved runs over cross-run caching. If caching becomes
worthwhile, include complete selected source/metadata, questions, and model identity
in the key; the identical-summary/different-body probe must invalidate the result.

### Acceptance cases

The two polarity examples; unordered Choice options; positive and negative Score
directions; malformed/missing/extra answer IDs; nonfinite values; model alias
changes; timeouts and retries; full request versus longest-question budget; helper
and assertion preservation; source-body changes with identical summary chunks;
round-trip replay of existing captures.

## 4. Add truthful callback-analysis provenance

Owned implementation: `lib/woods/extractors/callback_analyzer.rb`,
`model_extractor.rb`, and a small helper if source-segment bookkeeping warrants
one. Tests: the corresponding extractor specs, booted extraction specs, and
incremental/full equivalence cases. Canonical guide: `docs/EXTRACTOR_REFERENCE.md`.

Add a versioned analysis object alongside existing `side_effects`. Suggested
contents, to finalize with contract specs:

- analysis status/reason distinguishing analyzed body, unsupported filter,
  missing/ambiguous body, parse failure, and unavailable source;
- `analyzed_bodies`: the actual bodies inspected, identity/hash, and location with
  an explicit coordinate space;
- `unresolved_calls`: observed calls whose implementation/effects were not followed,
  with reasons such as depth not followed, dynamic target, or unavailable source;
- scope and limitations, including whether call enumeration itself was partial.

These fields describe the work performed. A body found by syntax/name alone must
not be labeled runtime-dispatch verified. A known call that was not followed is
different from a target that could not be resolved; retain the reason.

Track raw model/concern source segments when constructing the analysis composite.
Only publish physical coordinates where the mapping is established. Otherwise
publish a clearly labeled composite location. Duplicate method names, inheritance,
and `prepend` require explicit ambiguity/ownership handling rather than assigning
the first matching AST node a confident owner.

Do not derive an exhaustive `unresolved_calls` claim from the current `operations`
array: its walker intentionally filters calls and skips parts of send-node trees.
Use inspected AST call sites with a declared scope, or mark enumeration partial.
Do not add recursive helper traversal in this slice.

Retain the existing effect arrays for compatibility where their interpretation is
unchanged. If ownership verification reveals a wrong-body extraction, handle that
as a separately reproduced behavior fix instead of hiding it inside metadata work.
New fields will change unit hashes; refresh behavior and mixed older/newer retained
units must be tested and documented. Missing analysis metadata in old units means
unknown coverage.

### Acceptance cases

Direct write, no detected effect, missing named method, parse failure, proc/object
callback, same-class helper not followed, concern-defined method, duplicate names,
inherited/overridden/prepended method, dynamic dispatch, and callback guards. Test
deterministic output across independent boots, correct physical/composite location
disclosure, and no callback execution during extraction. Empty arrays must remain
distinguishable from unavailable analysis through the new metadata.

## 5. Evaluate the whole review workflow

Add a new report layer rather than replacing old replay results. Its case/run
records should connect the exact packet and bank to the shortlist and downstream
investigation outcome. Ground-truth labels/oracles stay outside provider inputs.

Report separately:

- first-pass judgments and per-control false actionable signals;
- confirmed findings within a fixed downstream budget;
- time, provider-specific tokens, and monetary cost to the first confirmed finding;
- no-finding/budget-exhausted runs, false leads, duplicates, and additional findings;
- incomplete evidence, request failures, and actual evaluated question coverage.

Use independent baseline/report-assisted reviewer sessions with the same source,
tools, model, task, and budget. Keep any downstream persona fixed; a Jev-prefix
experiment is a separate variant. Do not rank experiments solely by probability
movement or discard unsuccessful runs when reporting savings.

Use the public Rails testbed for a few integration smoke cases: callback/helper
context, inherited authorization/filter context, job adapter/transaction premises,
and migration/schema selection. Confirm one real packet end-to-end before expanding.
These cases validate transport and interpretation. The admin application's own
dozen pairs remain the relevant usefulness trial for that application; keep its
private data and raw captures in its project.

## 6. Documentation, compatibility, and delivery

Update experimental README/schema/sample files with each tooling slice. After the
behavior is verified, update applicable canonical agent guidance and inspect the
distributed investigation/diagnosis/setup skills. Change only affected skills;
version-qualify new capabilities and follow the plugin version/pairing policy if
skill or marketplace compatibility content changes.

For public extraction changes, add an appropriate unreleased changelog entry and
verify generated surface evidence. Do not hand-edit the inventory, gem version,
or release-state fences. Public tool registration need not change for this plan.

Prepare a new edition of the portable guide after implementation and validation.
Include sanitized packet/run examples and these learned distinctions. Preserve
previous sealed ZIPs and their checksums as historical evidence; a new edition
gets a new manifest, validation record, and archive identity. Do not represent
old captures as measurements of a newer producer.

## Execution and validation sequence

1. Recheck current changes/history and adjacent work. Use an isolated checkout for
   runtime changes, carrying only the explicitly selected untracked development
   files needed for the slice. Refresh the Woods self-map if the source baseline
   has moved; use it for ownership, not Rails runtime conclusions.
2. Land the documentation correction as a small independent change.
3. Implement packet v2 and its failure cases, then request/response/run contracts.
   Preserve existing replay/spec behavior and demonstrate one complete saved request.
4. Implement callback provenance independently, starting with failing focused specs.
   Validate booted Rails and incremental/full publication semantics before integration.
5. Run public fixture/packet smoke cases and exercise the new offline workflow report.
   Live inference remains a separate explicit experiment with actual usage recorded.
6. Complete the relevant full checks and synchronize documentation/exports.

Focused commands during the appropriate slices:

```bash
bin/rspec spec/development/typesafe
bin/rspec spec/extractors/callback_analyzer_spec.rb spec/extractors/model_extractor_spec.rb
bin/rspec spec/source_inputs spec/published_index_spec.rb

WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile \
  bin/rspec spec/integration/booted_extraction_spec.rb
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile \
  bin/rspec spec/integration/booted_extraction_spec.rb

bin/rake spec
bin/rubocop
bin/rake release_v2:verify_surface_inventory
```

Run the incremental equivalence cases and other Rails appraisal lanes when the
implemented change reaches those contracts. Run live-backend tests only if a slice
changes backend behavior; do not update dependencies broadly just to run a lane.
These commands are planned validation, not a claim that they ran in this turn.

## Rollback and stop conditions

- Each slice should be independently reviewable; core extraction changes must not
  depend on a TypeSafe credential, provider response, or the admin application.
- Keep v1 packet/replay readers and saved artifacts available. New experimental
  formats are explicitly versioned; avoid silently rewriting old evidence.
- If new callback metadata proves too costly or unreliable, omit/revert that
  addition and leave the pilot using source plus existing annotations. Do not
  remove uncertainty labels to manufacture a passing result.
- If the report-assisted reviewer saves tokens but creates excessive false leads
  or misses the target cases, report that tradeoff and adjust the relevant selection
  or question once before broadening the experiment. Do not turn this into a
  release gate or an endless corpus-building project.

The first Woods deliverable is the documentation correction plus a small, honest
packet contract. The first evidence of product value comes from the admin trial.
