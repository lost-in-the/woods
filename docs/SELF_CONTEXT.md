# Development context for the Woods source checkout

These internal tasks help agents develop Woods itself. They produce a static
Ruby map, a browsable guide and candidate change-impact reports without booting
Rails, connecting MCP or using embeddings. They do not replace a host Rails
application's runtime extraction or the validation policy in CONTRIBUTING.md.
Use the development bundle from this checkout; installed releases may not have
these tasks. Check `bin/rake -T woods:self` before relying on them.

## Start with the guide

```bash
bin/rake woods:self_docs
```

The task refreshes `woods:self_map`, pins its published generation, and prints a
completed directory containing `START_HERE.md`, bounded `areas/*.md` pages, a
complete `inventory.json` and a provenance `manifest.json`. Open START_HERE first,
then follow source links and read the repository's AGENTS.md and canonical docs.
Areas are filesystem groups and samples are alphabetical, not architectural
boundaries or rankings of the most important code.

The default index is `tmp/woods_self_map/`; views and reports live in ignored
`tmp/woods_agent/`. `current.json` points to the latest completed guide, and
`latest-impact.json` points to the latest completed report. Their `path` values
are relative to that output root. Rerun the tasks after edits: opening generated
Markdown does not check whether its generation is still current.

## Inspect change impact

```bash
bin/rake "woods:self_impact[lib/woods/gem_mapper.rb]"
# Several paths are space-separated; quote a path containing spaces inside the argument.
bin/rake 'woods:self_impact[lib/woods/store.rb lib/woods/runner.rb]'
```

The task prints the completed report directory. Read `impact.md` for a bounded
summary and `impact.json` for all recorded results within traversal budgets.

Affected rows are capped at 20 per endpoint in Markdown, but the suggested-spec
list has no independent Markdown cap. High-fanout reports may still be large;
the JSON retains the full list within the traversal budgets.

Paths come from the argument, then `CHANGED_FILES` (shell-style quoted paths),
then the local diff against the merge base with `origin/main`, including
uncommitted and untracked work. Without a local base, only uncommitted paths are
known. The task does not fetch Git refs or prove their freshness.

Reports seed file and definition identities, follow typed reverse relationships,
and suggest specs. An `owner_expansion` witness continues from a referenced method
to its owning class/module; it is an inferred candidate relationship, not an
observed call. Original references and these inferred edges remain labelled in
JSON. File-level reports do not establish exact method-call coverage. Suggested
specs may be opt-in or require services: inspect their metadata and the required
lanes in CONTRIBUTING.md. `woods:affected_specs` remains available with its
existing newline-separated spec output.

Changed reopened definitions seed both their recorded occurrence and an existing
canonical identity of the same type, so consumers of the canonical class/module
remain reachable. Modules containing only `include` or `extend` are meaningful
definitions; pure namespace wrappers remain excluded from definition seeds.
Retained maps with an older, incorrect wrapper flag can still seed a module
when its published graph records an `include` or `extend` relationship.

### Deletions and an explicit baseline

Refresh the map before making a change if you need before/after evidence. Record
its generation number from the guide or `tmp/woods_self_map/generation.json`.
After changing or deleting files, supply that retained generation explicitly:

```bash
bin/rake 'woods:self_impact[lib/woods/removed.rb,12]'
```

Current and baseline evidence are computed separately. For a rename, pass both
the old and new paths. The selected generation is a source snapshot you chose;
it is **not verified to match Git's merge base**. Missing/pruned generations are
errors, not an implicit fallback. Without a baseline, deletion/removed-reference
coverage is unavailable. The task pins a selected baseline before refreshing so
that the refresh cannot prune it while computing the report.

## Coverage and freshness

The map analyzes `lib/woods.rb`, `lib/woods/**/*.rb`, `lib/tasks/**/*.rake` and
`exe/*`. Ruby under `spec/**/*.rb`, including helpers and fixtures, contributes
reference-only constant and literal-require relationships; its bodies and test
classes are not published as production units. Comments and plain strings do
not create constant references. Literal load-path requires consider existing
`lib/` and `spec/` candidates, including `require "spec_helper"`; if both exist,
both remain candidates rather than a claim about runtime load-path order. A
literal tree-glob read can conservatively reference the whole library. Dynamic
requires and unresolved dispatch remain outside exhaustive coverage.

The self-map manifest's optional `self_map` object records per-file states
(`parsed`, `reference_only`, `parse_failed`), source hashes, parser identity and
parse failures. Summary indices also identify actual definitions and canonical
reopened identities. The input inventory lists Git-tracked and nonignored
untracked paths; inputs outside the map are explicitly `not_mapped` or `absent`.
When Git is unavailable, its scope is only covered sources. This is not an
inventory of ignored files or a claim that every path is semantically analyzed.

The map checksum includes covered source paths/contents, analyzer version,
Ruby engine/release and Prism version. Context publication checks that this
checksum still matches before moving its pointer. This establishes a covered
source match at publication, not future freshness, executed test coverage or a
snapshot of all excluded inputs. Maps without parse diagnostics have unknown
legacy parse coverage. No dependents or test-only dependents never prove that
production callers do not exist. Reports always retain `complete: false`.

## Output lifecycle and configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `WOODS_SELF_MAP_OUTPUT` | `<woods root>/tmp/woods_self_map` | Existing self-map index root |
| `WOODS_SELF_CONTEXT_OUTPUT` | `<woods root>/tmp/woods_agent` | Completed guide/report output root |
| `WOODS_SELF_IMPACT_OPTIONS` | `{}` | JSON object accepting `depth`, `max_nodes`, `max_edges` |

Impact defaults are depth 4, 1,000 node visits and 10,000 examined relationships
per endpoint. Supported ranges are depth 0–10, nodes 1–10,000, edges 1–100,000.
A budget cutoff is reported as partial, not silently treated as a complete
result. Raising a budget does not add relationships absent from the map.

Views and reports are rendered from one pinned generation, staged and synced,
then published through atomic pointers. Identical outputs reuse their completed
directory. Each family retains three completed directories; old Markdown is
self-contained and does not pin historical graph payloads indefinitely. Source
changes or rendering failures leave the previous pointer intact. A corrupt
completed directory is an error; remove that directory and rerun to rebuild it.
The index has its own generation retention, independent of context output.

Keep generated output out of version control. When using containers, source links
refer to the filesystem visible to the task; run/read them in that same checkout
and filesystem. Regenerate after moving a checkout or changing the link root.
The first self-map build does full static analysis; subsequent unchanged runs
reuse the generation. Guides read summary indices, and focused reports reuse the
existing bounded impact walker rather than decoding every source body.
