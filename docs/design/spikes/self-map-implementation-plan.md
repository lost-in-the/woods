# Implementation plan: Woods development context

Baseline: `origin/main` freshly fetched at `3d545b87`, 2026-11-03.

## Deliverable

Ship a Woods-only static development workflow with no Rails boot, embeddings or
MCP prerequisite: `woods:self_docs` and `woods:self_impact[paths,base_generation]`.
Reuse `woods:self_map`, pinned published indices and bounded impact propagation.
Keep `woods:affected_specs` compatible. Generated output stays in ignored tmp.

## Sequence and acceptance

1. **Reproduce the misleading states.** Add fixtures for comment-only references,
   helper requires, parse failures and deletion across two generations. Assert
   recorded witnesses and unknown coverage, not graph size alone.
2. **Make self-map evidence usable.** Parse reference-only spec/helper Ruby with
   the existing parser, record literal requires, omit comment/string constant
   guesses, retain explicit tree-glob dependency evidence. Publish per-file
   parse/reference health and analysis provenance atomically with the map.
   Include helpers without publishing their bodies as production definitions.
3. **Build a focused adapter.** Seed exact typed file/definition identities from
   one pinned generation. Reuse bounded typed propagation; label owner-expansion
   edges as inference. Include suggested specs with witness paths, unsupported
   paths, parse failures and budget limits. When given a retained base generation,
   compute old and new sides separately; never silently substitute a missing
   baseline. File-level queries do not claim exact method-call coverage.
4. **Publish readable views.** Generate a bounded START_HERE, area pages and JSON
   inventories from summary indices. Generate focused JSON/Markdown on demand.
   Publish completed directories through atomic pointers, preserving previous
   output on failure. Cache by input generation, root, schema/renderer and query;
   retain a small number of completed outputs. Copy provenance rather than
   indefinitely pinning old graph generations.
5. **Wire and document tasks.** Refresh the map before queries; stamp source and
   generation identity without promising that an opened document remains current.
   Inventory Git-tracked/untracked nonignored paths and classify nonmapped paths
   rather than claiming full repository coverage. Link canonical validation
   policy and public-surface evidence; do not invent executed test coverage or
   select runtime lanes solely from directory names.
6. **Validate and open a draft PR.** Run targeted regressions, real self-map
   accuracy, full unit suite and lint, public-surface regeneration/verification,
   and the required ci-local preflight. Review the complete diff and task output,
   then commit, push and create/attach a draft PR. Record unavailable lanes and
   failures precisely. Do not merge or publish.

## Plan review

- An arbitrary previous generation is not Git merge-base evidence. Baselines
  must be explicitly selected and identified; no baseline means that deletion
  coverage is unknown, not no impact. A missing requested generation is an error.
- Reusing generic focus enrichment verbatim repeatedly decodes all source bodies
  and emits irrelevant Rails facets. Reuse its typed bounded propagation over
  summary identities and pinned graph data instead; avoid another graph engine.
- Owner widening is not an observed call. Keep an explicit `owner_expansion`
  witness and distinguish paths containing it from recorded-reference paths.
- A file unit alone does not prove a parse succeeded. Publish diagnostics; legacy
  maps without those diagnostics are unknown. Do not weaken shared parser errors.
- Live source can change after refresh. Verify freshness before publishing the
  completed view and retain a generation-bound stamp; rerunning tasks is required
  after edits. Stale/partial output must never assert exhaustive absence.
- Generated docs supplement AGENTS.md and canonical policy; they do not replace
  authored architecture explanations or the required validation matrix.
- Runtime TracePoint/per-example coverage, automatic validation-policy inference
  and agent ablation remain separate follow-up experiments. This implementation
  does not advertise those as available or use suggestions to skip required tests.
- The prior Ruby 3.3.1 VM crash requires a supported newer patch runtime for a
  credible full-suite attempt. Keep dependency locks intact while provisioning.

The self-review found no need for a server, watcher, embedding provider or new
public extraction types. Task schemas, generated surface evidence and docs must
move together. Plugin instructions will be inspected and updated only where the
new Woods-checkout workflow is relevant, with installed-source capability checks.

## Implementation validation

Implemented on `feat/self-map-agent-context`. The final validation used Ruby
3.3.13 and the unchanged lock's Bundler 2.6.9 in a disposable container, with the
checkout at its actual `/workspace/woods` path and the workspace owner's UID.

- `script/ci-local --skip-booted`: passed surface inventory verification,
  repository lint, retrieval quality and the complete default suite in four
  processes: 17,390 examples, zero failures, two allowed pending examples.
  Aggregate line coverage 94.28%; branch coverage 83.23%.
- Focused context/task/helper regressions: 33 examples, zero failures.
- `WOODS_RUN_SELF_MAP=1 bin/rspec spec/self_map_accuracy_spec.rb`: five examples,
  zero failures against a real map of this checkout.
- Real `woods:self_docs` and `woods:self_impact[lib/woods/gem_mapper.rb]` smoke
  calls passed. Every generated guide link resolved; the focused report retained
  typed witness paths, source links and explicit incomplete coverage.
- Public-surface inventory regenerated through its task. The only registrations
  added are the two internal Rake tasks. Plugin guidance is capability-gated;
  its version moved to 2.3.86 without marketplace ref/compatibility changes.

Initial environment attempts exposed an old Ruby VM crash, a checkout mounted at
`/app` colliding with fixture paths, packaged-file read modes, and cache ownership.
The final runtime/mount/permissions setup resolved those failures; no unrelated
production fix or dependency lock change was made. Booted Rails, live backends,
other Ruby rows and hosted CI remain separate, unrun lanes for this source-only
workflow. Runtime execution coverage and agent ablation remain future work.
