# Second pass: a development context workflow for Woods

2026-11-03, same `3d545b87` baseline as the [first spike](self-map-impact.md).
This is an assessment and executable prototype, not a new supported interface.

## Recommendation

Use Rake as the refresh/query interface and publish small, deterministic Markdown
views alongside machine-readable evidence in ignored `tmp/`. Agents should be
able to open one entry page, discover the relevant area, inspect source, and ask
for change-specific impact without starting a server. MCP can remain an optional
adapter later; it is not a prerequisite for this workflow.

Rake-only console output is insufficient as the main experience: it is ephemeral,
awkward to navigate and easily loses generation/coverage context when copied.
A single enormous generated architecture document is also a poor entry point.
Keep the source of truth in the existing atomic self-map and render bounded,
linked views of it. Preserve AGENTS.md and canonical docs as authored policy;
generated documentation links to them rather than restating their instructions.

## Additional experiments

`script/spikes/self_map_blind_spots.rb` creates a small disposable source tree,
publishes two generations and prints these observations:

| Probe | Observed behavior | Consequence for an agent |
| --- | --- | --- |
| A spec mentions `Probe::Target` only in a comment | The spec becomes a dependent of `Probe::Target` | Static suggestions include lexical false positives; they are not execution evidence |
| Change `spec/support/helper.rb`, required by a spec | No seeds or suggested specs | Excluded helper changes silently narrow the plan |
| A source file has invalid Ruby syntax | Its `ruby_file` unit remains, no class/method units, no manifest parse-failure list | Inventoried file count cannot measure parsing completeness |
| Remove a previously mapped file and refresh | Current affected-spec query has no seeds; generation 1 still finds the old spec | Deletions need an explicit before/after source binding and old-graph traversal |

These reproduce current limits, not proposed correctness tests for a finished
feature. Comments are scanned by `GemMapSpecs`' regex/token logic. The helper is
outside its `*_spec.rb` scope. Parse failures are swallowed in `RubyAnalyzer`,
then `GemMapSource` still emits the file unit. None of those states is safely
interpreted as “nothing affected.” Renames, removed dependencies and methods
also need old-graph evidence; filenames alone cannot recover lost relationships.

Across the real map, 7,542 of 7,549 method units have no recorded incoming
relationships (99.9%). This is a representation/coverage limit, not evidence
that those methods are unused. An agent-facing guide must not label these
methods dead code or rank their change risk as low from in-degree alone.

The existing accuracy lane has five known-truth examples. It is valuable but
does not measure repository-wide relationship recall, false positives or agent
success. A larger unit count is not evidence that this gap has closed.

## Generated documentation prototype

`script/spikes/self_map_guide.rb` opens one `PublishedIndex`, holds its generation
pin, and reads type inventories. It does not decode every source body or ask the
Rails-specific impact enrichment to produce an overview. It generates:

- `START_HERE.md`: generation, source checksum, unknown freshness, task workflow,
  policy links, area index and coverage limits;
- `areas/*.md`: filesystem groups with bounded samples of files and typed
  definitions, and links back to source;
- `inventory.json`: complete listed identities/types/paths for further queries;
- `manifest.json`: the generation and explicit `not_checked` freshness state.

On the current map: 10,669 units, 95 area pages, a 6,511-byte entry page, about
143 KB of Markdown in total, and a 2.69 MB inventory JSON. The original payload
is 48.15 MB across 10,677 files. Area samples contain at most eight files and
eight definitions each. Areas are filesystem groups, not inferred architectural
or runtime boundaries. Alphabetical sampling is deliberately simple; it does
not establish that the first files are the best entry points.

A local sample is under ignored `tmp/woods-agent-spike/guides/`; the script
prints the completed directory. It creates a new directory per invocation and
has no stable-current pointer or cache. Links use the source root of the running
checkout; `WOODS_GUIDE_SOURCE_ROOT` can select the link root for a container/host
pair. This override changes links only, not which index was read.

The prototype is useful for orientation, but not the final guide. The next
useful view is a focused report explaining changed files, exact and inferred
relationships, suggested specs, required validation lanes and uncovered inputs.
Generate that on demand rather than precomputing every unit's neighborhood.

## Coverage needs several independent measures

1. **Input/parse coverage:** enumerate the repository universe and classify each
   path as parsed, reference-only, excluded, failed or unsupported. Include
   `spec/support`, fixtures, `bin/`, `script/`, gemfiles, gemspec, CI, plugin
   configuration and public documentation in this inventory even when they
   cannot contribute Ruby call edges. Report additions and untracked paths.
2. **Relationship coverage:** distinguish AST constant/call references,
   inheritance/mixins, requires, owner-level expansion, observed method calls,
   public contract links and manually declared policy. Keep evidence paths and
   confidence provenance; avoid a synthetic “safe” score.
3. **Execution/test coverage:** associate observed calls or executed lines with
   the exact spec/example, source checksum, Ruby/Rails/dependency versions and
   run result. An attempted, skipped or failing run is different from a passed
   check. Test execution still does not prove an assertion covers the behavior.
4. **Behavior/matrix coverage:** identify which supported Rails/Ruby lines,
   real backends, installed artifacts, transports, error paths and incremental
   equivalence checks apply to a change. The ordinary suite's line percentage
   cannot stand in for those lanes.

SimpleCov already tracks all `lib/**/*.rb`, including unloaded files, and
measures branches; its CI floor is aggregate line coverage. It filters specs,
uses whole-process/shard results and does not currently provide a per-example
impact map. Existing percentages must not be reinterpreted as such a map.
For a first runtime experiment, collect executed files per spec process before
adding method tracing: this is simpler and may recover dependency-injection
paths at lower cost. Measure overhead and branch misses against TracePoint.
Do not infer a negative dependency from an unexecuted branch or unrecorded thread.

## Remaining blind spots and useful enrichments

- **Ownership and identities:** preserve exact typed identities, reopened
  definitions, singleton/instance methods and source spans. Show owner-level
  candidate impact separately. Ruby's lexical qualification here is an
  approximation; inherited constants and dynamic constant resolution need
  fixtures rather than a claim of full Ruby name resolution.
- **Entry points and contracts:** start from actual executable/task/registration
  wiring, not just graph centrality. The generated public-surface inventory
  already records executables, tasks, configuration and conditional MCP
  registration. Reuse it with its verification command and provenance, not as
  an independently maintained copy of those lists. Connect published artifact
  readers/writers and plugin consumers to the contracts they depend on.
- **Test prerequisites:** spec suggestions must retain opt-in metadata and
  prerequisites. A file under `spec/integration` is not automatically a booted
  Rails test, and a named spec may be excluded by default. Repository policy
  determines required checks; graph suggestions choose what to run first.
- **Changes outside the graph:** dependency bounds, appraisal gemfiles, fixture
  changes, CI, generated schemas and docs may require broader validation even
  with no Ruby reverse edges. Mark those inputs and apply explicit policy.
- **Failure visibility:** distinguish no match, incomplete parse, stale source,
  absent baseline, partial traversal, skipped hub and unavailable runtime lane.
  Preserve machine-readable details while grouping repetitive notices in prose.
- **Agent task scope:** a flat graph does not explain which behavior to preserve.
  A focused view should link invariants, public contracts, nearby examples and
  canonical docs; it should not fabricate architectural explanations from names.

## Storage, refresh and task boundary

Keep the existing index at `tmp/woods_self_map/`. A proposed view layout is:

```text
tmp/woods_self_map/                 existing atomic graph and unit payloads
tmp/woods_agent/
  current.json                     atomic pointer to a completed view
  views/<view-key>/
    START_HERE.md
    areas/*.md
    inventory.json
    manifest.json
  reports/<query-key>/              focused Markdown + complete JSON evidence
  runs/<run-id>/                    execution/coverage receipts, version-bound
```

This layout and new task names below are proposals, not shipped interfaces.
Keep only a small number of completed views/reports, honor generation pins,
and retain execution receipts according to their own source/run bindings.
Do not pin all past index generations forever merely to retain prose. Completed
views can copy their compact provenance and recorded facts. A report that needs
to reread historical bodies must hold a pin or use an explicitly retained copy.
The mapper currently retains three payload generations; this is not a substitute
for a baseline tied to the diff's actual merge-base/source state.

- Existing `woods:self_map` remains the canonical graph refresh.
- Proposed `woods:self_docs` refreshes/reuses that map and renders the guide.
- Proposed `woods:self_impact[paths]` refreshes, resolves current and baseline
  seeds, and produces a focused report. Keep `woods:affected_specs` compatible.
- Any future status command should report current/drifted/unknown and reasons;
  exit successfully only according to a documented status contract.

Start with explicit task execution and one small, stable AGENTS.md pointer once
implemented. No daemon or per-prompt full regeneration is necessary. Perform
freshness checks when answering a query or regenerating docs; merely opening a
Markdown file must never imply that it is current. Show how to refresh it.

For production, render into a staging directory, complete the manifest, then
atomically publish `current.json`. A failed refresh must leave the old view
readable and visibly stale/unknown, not partially overwrite it. Pin one input
generation for the entire view and never mix live-source excerpts into an old
snapshot without labelling their separate provenance.

## Optimizations worth pursuing

A single local process measurement (warm filesystem, not a benchmark claim):

| Operation | Wall time | Ruby objects allocated |
| --- | ---: | ---: |
| Unchanged-source map check | 0.193 s | 140,022 |
| List all unit summaries | 0.083 s | 86,921 |
| Full native focus report for GemMapper | 1.135 s | 1,665,787 |

The guide rendered in 0.091 s in a separate local invocation, excluding Ruby
startup, map construction and impact queries. These observations justify an
inventory-based overview; they do not establish speed under cold I/O or CI load.

1. Do not decode all 10,669 source bodies for every overview or repeated focus.
   Reuse immutable per-generation summaries/typed maps and batch related queries.
   Preserve validation and pins; do not bypass corrupt-artifact checks for speed.
2. Group expected reference-only/source-unavailable notices, with full detail in
   JSON. Precompute compact adjacency only if measurements show it is needed.
3. Render area pages from inventory summaries and load full source only for the
   focused neighborhood. Do not generate a diagram or a page for every method.
4. Cache by source and graph identity plus renderer/schema version, options and
   source-link root. Parser/Ruby/dependency versions affect analysis semantics;
   the existing source-only map skip cannot certify those are unchanged.
5. Keep graph build, guide rendering, querying and runtime observation separate
   enough to measure their costs. Embeddings and full-suite tracing are not
   requirements for the first useful workflow.

## Next acceptance gate

Before treating suggestions as high-recall development support, use a fixed
historical/fixture corpus including helper changes, removals, renames, parse
failures, reopened definitions, exact methods, configuration and conditional
registration. Score expected affected components/specs and record misses,
unsupported inputs and excess suggestions. Include a task with no known graph
relationships and require an honest unknown result.

Then compare agents using ordinary source search, source search plus the guide,
and source search plus guide plus focused reports, at the same baseline and
budgets. Measure resolution, missed contracts/required lanes, time/tokens and
context size. Existing `Evaluation::Ablation*` helpers and `docs/EVALUATION.md`
provide worktree isolation and reporting patterns; they need a Woods-specific
corpus/adapter and are not already a validation of this workflow. Do not use
these results to skip required suites until misses are understood.

## Reproduce and validation

```bash
bundle exec ruby script/spikes/self_map_blind_spots.rb
bundle exec ruby script/spikes/self_map_guide.rb INDEX_DIR tmp/woods-agent-spike/guides
bin/rubocop script/spikes
```

Both experiments ran using the exact repository bundle in the existing Ruby
3.3.1/Bundler 2.5.11 container. Blind-spot assertions, guide count/provenance
checks and all generated Markdown links were checked. Three spike files passed
lint. The opt-in real self-map accuracy lane plus affected-spec contracts were
rerun: 11 examples, zero failures. No production code, public Rake/MCP surface
or generated release evidence changed. The full-suite VM crash recorded in the first spike remains a known
validation limit; it was not rerun for this documentation/prototype pass.
