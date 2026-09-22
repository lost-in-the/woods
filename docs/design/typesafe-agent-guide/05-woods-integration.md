# Woods integration: trustworthy structure and editable evidence

Woods can supply structural context for a TypeSafe-assisted development workflow.
It resolves Rails structure during extraction, publishes an index, and exposes
that index without repeatedly booting the application. A selector can then judge
bounded candidates while ordinary code preserves their identity and exact source.
This chapter describes the existing Woods contracts and a **proposed optional
integration**. No TypeSafe service, routing tool, or automatic deployment is added
to packaged Woods by these experiments.

Canonical links below are pinned to Woods
[`55a74ea4`](https://github.com/lost-in-the/woods/tree/55a74ea4f3a7c3e798493a92663003aab85a2301),
the evaluated revision. Check the installed version before adopting instructions
for another release. [Evidence selection](03-evidence-selection.md) covers ranking
and packing; [architecture and operations](02-architecture-and-operations.md)
covers the TypeSafe client and failure policy.

## Choose the correct kind of map

For a **host Rails application**, use ordinary extraction in the environment
where that application boots. Runtime reflection is required for resolved Rails
callbacks, routes, Active Record relationships, eager loading, and related
behavior. Run extraction, validation, and statistics using the application's
installed Woods tasks; follow the canonical
[MCP setup guide](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/MCP_SERVERS.md)
for the exact setup. A successful index does not itself demonstrate that a
requested feature's behavior is correct; execute the relevant application tests.

For **investigating the Woods gem itself**, the internal static self-map supplies
classes, modules, methods, files, and conservative relationships without a Rails
application, database, or embeddings:

```bash
woods_map_dir="$(mktemp -d)"
bin/rake "woods:self_map[$woods_map_dir]"
bundle exec woods-mcp-start "$woods_map_dir"
```

Use this from the Woods checkout, retaining the disposable output outside source
control. It shares the publication envelope with runtime extraction but has
different provenance and type families. It cannot establish Rails runtime
behavior. These requirements are part of the repository's
[agent instructions](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/AGENTS.md).

For either map, extract the **actual source snapshot being evaluated**. An index
of a correct implementation followed by a mutation leaves answers in the
retrieval evidence and invalidates a repair experiment.

## Establish the installed and callable surface

Follow the installed-version preflight in
[agent setup](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/AGENT_SETUP.md).
The evaluated packaged Index Server registers **14 tools**:

`woods_status`, `search`, `lookup`, `dependencies`, `dependents`, `structure`,
`trace_flow`, `framework`, `recent_changes`, `graph_analysis`, `domain_clusters`,
`pagerank`, `reload`, and `codebase_retrieve`.

The other **15 schemas** in the source inventory require specialized collaborators
or configuration. Schema existence does not make a capability callable; the
packaged executable does not wire pipeline-operator or feedback-store features.
`codebase_retrieve` registers by default but needs embeddings and an available,
current semantic store to return semantic context. Structural lookup and search
do not require that setup. Verify the actual server tool list and
[canonical MCP contract](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/MCP_SERVERS.md)
before constructing any proposed TypeSafe function roster.

Start with `woods_status`. Record readiness, current generation, useful unit
counts, retrieval readiness, and warnings. Compare `index.woods_version`, the
manifest publisher, with `server.version`, the MCP reader. Missing publisher
provenance means unknown. A major-version mismatch merits extraction/upgrade
investigation; matching versions do not prove every retained unit was rewritten.
The [PublishedIndex provenance contract](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/PUBLISHED_INDEX.md#manifest-writer-provenance)
explains these distinctions.

## Use structure to find evidence

The normal investigation loop is:

1. **Discover:** search by task terms, observed identifiers, or known paths. The
   packaged `search.query` is a Ruby regular expression; escape literal user
   text or choose the supported literal prefix/suffix mode deliberately.
2. **Inspect:** `lookup` actual returned identifiers. Preserve unit type and
   namespace rather than guessing identity from a filename.
3. **Expand:** use `dependencies` for what the unit uses and `dependents` for what
   uses it. Start with a small depth and relationship/type filters appropriate to
   the question. Use available flow information when helpful.
4. **Check completeness:** inspect pagination and `partial`/`partial_reason`.
   A traversal stopped by node/edge limits is not made complete merely by paging
   through its already collected results.
5. **Verify:** read current physical source and run relevant tests. Separate
   extracted facts, inferred impact, and actual execution evidence.

Graph relationships suggest where to inspect; they do not prove call order,
authorization, or test coverage. The canonical
[agent guide](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/AGENT_GUIDE.md)
owns tool-specific guidance.

In the completed experiment, task descriptions alone generated escaped search
queries. Both selectors received the same deterministic top-80 candidate pool.
The search found nearly the entire eligible Woods source inventory, so successful
discovery does not demonstrate efficient localization on a much larger
repository. Preserve discovery and shortlist denominators before measuring
ranking quality; see [the trial ledger](06-trial-ledger.md).

## Acquire one complete generation and keep it available

A sidecar reading index files must follow the
[published filesystem contract](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/INDEX_LAYOUT.md).
Read `generation.json` at the configured root and follow its relative `payload`.
Do not choose the highest numbered directory or assume root-level structural
files are current. Reject paths escaping the root, including symlink escapes.
An existing malformed pointer or missing named payload is an error, not a reason
to silently use older root files.

Atomic publication selects a complete generation; it does not retain that
generation indefinitely. A consumer reading multiple files must hold the
documented shared lock on the selected payload's existing, read-only
`manifest.json`, then recheck pointer identity and the open manifest's inode to
close the acquisition race. Hold that handle throughout every read or complete
copy. A later publication is harmless once the generation is pinned. If
acquisition races retention, discard partial work and restart with bounded
retries. Printing a payload path and releasing the lock does not pin a later
consumer's reads.

For Ruby consumers, prefer the stable
[`Woods::PublishedIndex` block API](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/PUBLISHED_INDEX.md):

```ruby
require "woods/published_index"

Woods::PublishedIndex.open(ARGV.fetch(0)) do |index|
  unit = index.unit("Example::Order", type: "model")
  provenance = {
    generation_number: index.generation_number,
    manifest_sha256: index.external_dependency_checksum
  }
  # Materialize required evidence here, before the reader releases its pin.
end
```

The instance stays on one generation, needs no Rails boot, and is not
thread-safe. Give each thread its own reader. Supply a type when an identifier
could exist in multiple families. The advisory pin protects against cooperating
retention, not manual deletion, `woods:clean`, index replacement, or filesystems
without compatible locking. Flat indexes do not provide the same multi-file
atomicity; use a stopped-writer immutable snapshot or reject that mode explicitly.

Record provenance sufficient to distinguish two projects or recreated indexes:
repository/snapshot identity, source revision and working-tree digest, index
identity, captured generation number and token, manifest digest, writer version,
and extraction mode. Generation number alone is index-local and can restart.
Capture these fields from the same acquisition, not an unrelated later pointer
read. A materialized evidence artifact should have its own digest too.

Copy only the pinned structural payload with its matching pointer using the
canonical snapshot-copy protocol. Configuration, embedding stores/checkpoints,
watch state, and operational locks have separate lifecycles. Copying the
structural generation does not clone a complete semantic deployment.

## Convert extracted units into exact editable source

An extracted unit is useful discovery evidence. Its source representation may
include computed or combined material and should not automatically become a
patch target. Its `file_path` names application source, not the unit JSON
artifact. Find artifacts by their real identifier and type; do not reconstruct
filenames from identifiers. Consult the
[unit field reference](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/EXTRACTOR_REFERENCE.md#extractedunit-field-reference).

The experimental bridge used runtime/static units to discover physical paths,
then parsed snapshot bytes into method and supporting spans. A proposed evidence
card should carry:

- repository-relative source path and full source-file digest;
- zero-based start byte and exclusive end byte;
- exact source bytes/text, with encoding and truncation represented explicitly;
- enclosing class/module and relevant support declarations;
- originating typed unit and pinned index/snapshot identity.

These are application-owned fields, not new native Woods fields. Derive spans
from the frozen physical file; do not search for a vaguely similar method in the
current checkout and assume equivalence. Preserve `private`, `protected`, and
`public` declarations, includes, and helpers when relevant. Parsing locates source;
it does not replace Rails reflection or behavior tests.

Before applying a patch, require the expected source digest and exact byte slice.
Editing an existing delivered file is distinct from inventing permission to edit
any file named inside its comments. Conversely, a hidden curator target list
must not silently restrict an experiment that promises any delivered source file
is editable. The [authoring protocol](04-code-authoring-and-evaluation.md) defines
that boundary. Missing helper context should trigger a recorded fetch or
abstention, not an unreported expansion of the author's evidence.

## Keep container and host paths explicit

The MCP process must see both its installed bundle and the index path supplied
to it. When Woods is installed only in an application container, run MCP through
that container, commonly with `docker compose exec -T`, using its container-visible
index root. A host launch requires the host bundle and a host-visible index. The
[Docker guide](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/DOCKER_SETUP.md)
and [MCP guide](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/MCP_SERVERS.md)
own complete configurations.

Map extracted container source paths to the exact host snapshot with an explicit
root mapping and containment checks. Do not treat an identical basename as
provenance. A path in the application container, a path in a copied experiment,
and a path in the working checkout may refer to different bytes. Keep MCP stdout
protocol-only and diagnostics on stderr; normally allow protocol negotiation
without forcing `MCP_PROTOCOL_VERSION`.

## Validate against the isolated testbed

The completed trial used
[woods-testbed at `f5f603f9`](https://github.com/lost-in-the/woods-testbed/tree/f5f603f92a16f385d4fc825d72c7232a75014da4)
for a controlled newsletter repair and a genuine payment feature. Each incomplete
snapshot received fresh ordinary Rails extraction and successful index
validation. Independent reference implementations, hidden behavior acceptance,
and existing focused tests validated the tasks before model calls.

Repeat that isolation pattern for new work: freeze source; make deliberate
mutations or leave a requested feature absent only in disposable copies; boot and
extract that exact copy; apply authored patches to another copy; execute hidden
and existing tests with a fresh test database. Use an evaluator whose database
and filesystem targets cannot resolve to the live application. Keep reference
implementations and hidden acceptance outside all provider-visible state.

Passing focused tests proves those tested assertions. The later compatibility
probe found broader behavior changes in accepted SQLite rewrites, and performance
was not measured. Preserve primary outcomes while reporting additional probes
separately. Controlled mutations are experimental fixtures; independently found
product bugs are separate findings. See the
[completed evaluation](evidence/2026-09-16-typesafe-four-tests-evaluation.md).

## Proposed deployment boundary

Keep an initial integration outside the packaged extraction/MCP path: an opt-in
development process could acquire an immutable structural snapshot, select
allowlisted source evidence, run a validated TypeSafe ranker, and return exact
cards to an ordinary coding agent. A deterministic selector remains available
when the ranker fails. Source changes invalidate the experiment rather than
quietly combining old scores with new bytes. This is a proposal, not an existing
Woods configuration option or sidecar service.

Do not upload Console MCP data as part of this source-ranking workflow. Console
boots Rails and can access live application data; it has separate authorization
and enforced protections described in
[Console setup](https://github.com/lost-in-the/woods/blob/55a74ea4f3a7c3e798493a92663003aab85a2301/docs/CONSOLE_MCP_SETUP.md).
Existing application access does not make records, credentials, or raw logs
appropriate scoring state. Apply an explicit outgoing-source policy as well,
since source files can contain sensitive material.

Adoption should preserve installed-version checks, normal code review, and the
host application's tests. Start with the measured source-selection use case and
record outcome, context size, cost, and fallback. Expand into the proposals in
[concepts and patterns](01-concepts-and-patterns.md) only when a separate
evaluation establishes their value. The [agent playbook](09-agent-playbook.md)
turns these boundaries into a repeatable workflow.
