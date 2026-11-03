# Explainable impact for agents developing Woods

Spike, 2026-11-03. Baseline: freshly fetched `origin/main` at
`3d545b87` (five commits ahead of the starting checkout). Work branch:
`spike/self-map-impact`. No runtime, extraction, task or MCP contract changed.

## Decision

The [second pass](self-map-agent-workflow.md) revises delivery to Rake tasks plus
generated views in ignored `tmp/`; MCP is optional. It adds controlled gap
probes, a generated-guide prototype and an acceptance plan.

Reuse `Woods::Impact::Report.focus` and the published self-map. They already
provide typed, generation-bound reverse traversal with shortest witness paths,
finite budgets and incomplete-coverage reporting. A second graph engine is not
needed. A small Woods-specific adapter is needed before this is a dependable
agent workflow. Adding embeddings does not address the demonstrated gaps.

The spike is `script/spikes/self_map_impact.rb`. It generates native JSON and
Markdown reports, a compact agent JSON view with spec suggestions and witness
paths, the existing file-based affected-spec selection, and a controlled runtime
trace probe. It verifies a known mapper spec and the probe's observed caller.
The agent view preserves the native evidence and coverage; it does not claim
that a source reference establishes test execution or coverage.

## Experiments and results

All focus experiments used depth 3 and a 1,000-node budget on the same generation.
These are counts of recorded relationships, not precision/recall measurements.

| Focus | Affected units | Spec-file witnesses | Native `tests` records |
| --- | ---: | ---: | ---: |
| `Woods::GemMapper` (`ruby_class`) | 11 | 10 | 0 |
| `Woods::GemMapper#map!` (`ruby_method`) | 0 | 0 | 0 |
| `Woods::MCP::IndexReader` (`ruby_class`) | 70 | 59 | 0 |
| `Woods::AtomicFile` (`ruby_module`) | 148 | 43 | 0 |

For example, the mapper report witnesses the static method-call reference from
`file:lib/tasks/woods.rake` to `Woods::GemMapper`, and spec references to that
constant. It does not establish that a particular Rake task executed that method.

The file-based `GemMapAffectedSpecs` query for `lib/woods/gem_mapper.rb` suggested
11 specs with no skipped hubs. It seeds all three constants defined in that file
plus its file unit, so it is a different question from focusing on `GemMapper`.
It also continues traversal from a dependent method's owner, whereas native
impact propagation follows the exact typed graph nodes. These counts must not
be presented as interchangeable implementations of the same query.

The exact method returned no dependents because static method calls target
constants, not exact callee methods. The impact engine correctly keeps the
method query exact. An agent needs a separate, explicitly labelled owner-level
fallback; silently widening that query would misrepresent the evidence.

The native `tests` array stayed empty because its related-record adapter handles
`test_mapping` units. Self-map specs are reference-only `ruby_file` units.
The spike's agent view classifies the affected spec files as suggestions and
retains their witness paths, without manufacturing Rails test mappings.

Every report included 752 `source_unavailable` records for intentionally
reference-only spec files, plus unavailable flow/runtime-related evidence. The
compact view groups these notices by kind and retains the raw report separately.
A production adapter should explain intentional reference-only coverage and
separate irrelevant Rails facets from missing evidence needed by this query.

A controlled `Caller#run(collaborator)` -> `Callee#run` probe had no static
caller dependency. `TraceEnricher.record` recovered the actual caller, and merge
attached it to callee trace metadata. The caller's graph dependencies remained
empty after merging. Runtime observation is available as a building block, but
is not wired into the self-map or its reverse impact graph. This experiment
covers one thread and one executed branch; it does not measure suite-wide trace
cost or completeness.

`change_impact` is conditionally registered only when `snapshot_store:` is
supplied to the MCP server. The default self-map launcher does not supply it.
An in-process MCP dispatch against the real self-map successfully answered
`dependents` and listed 15 default tools without `change_impact`. This confirms
the registration gap; the spike does not validate the packaged stdio transport.

## Smallest implementation worth shipping

1. Introduce a Woods-specific impact adapter over the existing reader and focus
   engine. Accept changed paths or exact typed identities. Return exact impact,
   separately labelled owner-level candidate impact, suggested specs with
   witness paths, and source locations from the pinned units where available.
2. Include a coverage envelope: generation and source checksum, freshness
   result, input paths absent from the map, traversal limits, skipped hubs and
   unresolved targets. Preserve all unknowns in machine-readable output.
3. Expose internal Rake queries and generated, linked context views in ignored
   `tmp/`, with contract tests and agent instructions. MCP is an optional adapter.
   Keep unsupported Rails facets out of the main summary.
4. Evaluate against historical changes with known affected components and
   regression tests. Measure misses and noise before using suggestions to
   reduce validation. Include deleted files and method-only changes.
5. Separately prototype opt-in per-example tracing. Store observed caller and
   spec-execution edges with run identity and source checksum. Never treat an
   unobserved edge as absent, and never merge observations from different source
   states without marking that distinction.

The first three steps provide a useful static exploration experience without
claiming runtime equivalence. Trace enrichment would improve evidence for
injected collaborators and dynamic dispatch. Public-surface links (MCP wiring,
extractor registration, configuration, plugin guidance and artifact consumers)
remain another distinct relationship family to model and validate.

The current mapper includes `lib/woods.rb`, `lib/woods/**/*.rb`,
`lib/tasks/**/*.rake`, `exe/*`, and reference-only `spec/**/*_spec.rb`.
It does not cover `bin/`, `.mcp.json`, plugin guidance, docs or arbitrary new
paths. Mapping these inputs, or reporting them as unknown, is necessary for a
repository-wide blast-radius claim. The mapper also skips parse failures through
`RubyAnalyzer`; a production coverage envelope needs those failures surfaced.

## Reproduce

With a supported Ruby and the repository development bundle:

```bash
bundle exec ruby script/spikes/self_map_impact.rb /tmp/woods-impact-spike
WOODS_RUN_SELF_MAP=1 bin/rspec spec/self_map_accuracy_spec.rb \
  spec/gem_map_affected_specs_spec.rb spec/impact/focus_spec.rb \
  spec/impact/propagation_spec.rb spec/ruby_analyzer/trace_enricher_spec.rb
```

Output must be outside the checkout. The self-map uses its normal atomic
publication and unchanged-source skip. JSON/Markdown and the index are disposable;
do not commit them. The spike's fixture is generated in a temporary directory.

## Validation

Execution used the existing `woods-cloud-testbed:local` Docker image because the
host has no Ruby and cannot install system packages. Ruby 3.3.1, Bundler 2.5.11;
an external `/spike/Gemfile` resolves this checkout's gemspec plus development
checks. The repository Gemfile and lockfile were not changed. The initial external
bundle omitted optional tokenizers. The exact repository bundle was subsequently
installed without dependency-file changes for launcher checks and final validation.

- Live self-map, four native focus reports, compact views and controlled trace:
  passed. An unchanged-source rerun skipped publication.
- Focused specs, including the opt-in real self-map accuracy lane: 42 examples,
  zero failures.
- Repository `bin/rubocop --format simple` with the repository bundle: 1,473
  files inspected, no offenses. Final spike syntax and its focused lint passed.
- Full `bundle exec rake spec`: did not complete. The initial external bundle
  produced subprocess bootstrap failures when tests selected the repository
  lockfile. After installing that exact bundle, all 27 examples in
  `spec/mcp/index_path_cli_spec.rb` passed. The broader run subsequently crashed
  in Ruby 3.3.1 at `event_extractor.rb:210`, during the existing catastrophic
  regex example (`spec/extractors/event_extractor_spec.rb:973`).
- Baseline isolation: `bin/rspec spec/extractors/event_extractor_spec.rb:973`
  with the repository bundle and unchanged tracked source also aborted with
  `munmap_chunk(): invalid pointer` (exit 134), without loading the spike.
  The full-suite failures are not cleared and no full-suite pass is claimed.
  Raw logs are under `/tmp/woods-spike-runtime/` in this environment.
- In-process MCP server against the real self-map: `dependents` succeeded;
  `change_impact` absent from the 15 registered tools.
- Booted Rails, live backends and packaged MCP transport: not run; no production
  code changed and the spike does not claim validation of those behaviors.
