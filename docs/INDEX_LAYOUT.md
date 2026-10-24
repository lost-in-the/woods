# Published index layout for shell and Python readers

Read `generation.json` at the configured index root, then read every structural
artifact from the payload it names. Do not require `dependency_graph.json` or
`manifest.json` at the root, and do not choose the highest directory in `payloads/`.
A directory can be present before its generation is published.

This is the filesystem contract for consumers without the Woods gem. Ruby callers
can use [Woods::PublishedIndex](PUBLISHED_INDEX.md). These examples require a
Woods 2.x payload index and a filesystem that supports the shared `flock` protocol
below. They deliberately reject legacy flat indexes instead of claiming an atomic
snapshot from them.

## Entry point and files

A typical structural index looks like this; optional entries need not exist:

```text
<index root>/
├── generation.json
├── payloads/
│   └── gen-42/
│       ├── manifest.json
│       ├── source_inputs.json          # optional on older indexes
│       ├── dependency_graph.json
│       ├── graph_analysis.json
│       ├── skipped_files.json          # optional on older indexes
│       ├── git_commits.json            # optional: absent without readable git history
│       ├── SUMMARY.md
│       ├── models/
│       │   ├── _index.json
│       │   └── <unit filename>.json
│       └── flows/
│           ├── flow_index.json
│           ├── by_unit.json             # optional inverted flow membership
│           └── <flow filename>.json
├── woods.json                 # optional configuration artifact
├── dumps/                     # optional semantic-store snapshots
└── ...                        # operational state and locks
```

The configured root can differ between a container and the host. Resolve the
relative payload against the root visible to the reader, not the writer's path.

`generation.json` is one JSON object, for example:

```json
{"number":42,"token":"978e69b524ac74fa","updated_at":"2026-09-15T12:00:00Z","reason":"incremental","payload":"payloads/gen-42"}
```

| Field | Contract |
|---|---|
| `number` | Positive integer, incremented on publication. It is local to this index; deleting/recreating the index can restart it. |
| `token` | Opaque string, changed on each publication. Compare it as well as `number`; do not depend on its length or encoding. |
| `updated_at` | ISO8601 publication timestamp, distinct from source modification times. |
| `reason` | String or null describing the publication, such as `full`, `incremental`, or `refresh`. Treat values as extensible. |
| `payload` | Relative directory name for this generation. Current writers use `payloads/gen-N`; follow the field instead of constructing it. Omitted/null means a flat layout. |

Reject an absolute payload path or one whose resolved real path escapes the index
root, including through a symlink. Unknown fields can be ignored. A missing
pointer can mean an older flat index or no index at all; it is not evidence that a
payload directory is published. An existing malformed pointer or a missing named
payload is an error to investigate, not permission to silently serve root files.
Some gem readers have permissive flat fallback for these failures; the publication
gates below deliberately fail more strictly.

### Payload artifacts

Read JSON artifacts as UTF-8 regardless of the reader process's locale. Unit
identifiers, source code, paths, and metadata can contain non-ASCII characters.
Reject invalid UTF-8 rather than replacing bytes in published source evidence.

| Artifact | Presence and meaning |
|---|---|
| `manifest.json` | Required for a complete structural publication. Counts by extractor directory, totals, extraction timestamp and provenance. Optional fields vary by writer/version; see [writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance). |
| `source_inputs.json` | Versioned source-input identities and per-consumer provenance for this exact generation; old indexes may omit it. See [source freshness](SOURCE_FRESHNESS.md). |
| `source_references.json` | Internal, versioned candidate and edge-ownership cache for this generation. Included in Woods 2.1. Older indexes remain readable without it; supporting incremental writers may require a [full baseline rebuild](INCREMENTAL_EXTRACTION.md#source-reference-baseline-and-upgrades). Preserve it when copying payloads. Not a public query schema. |
| `dependency_graph.json` | Required for a complete structural publication. Typed graph data; an empty graph is valid. |
| `<type>/_index.json` and unit JSON | Present for extracted families. `_index.json` is an array of unit summaries; an empty array is valid. Disabled/unavailable families may be absent. Do not infer completeness from a fixed count of directories. |
| `graph_analysis.json` | Derived graph analysis when produced. Treat absence as unavailable analysis, not an empty or corrupt unit index. `unmodelled_tables` lists the `database_table` units no model reads. |
| `skipped_files.json` | Swept Ruby files and GraphQL operation documents (`config.graphql_document_paths`) that produced no unit: `total`, `counts` by reason, and `files` as `{ path, reason }` sorted by path. Ruby reasons are `rejected_by:<extractor>`, `parse_error`, `no_declaration`, `namespace_only`, `not_owned` and `template` (a generator template under `lib/`); document reasons are `graphql_unavailable`, `schema_definitions` and `parse_error`. A template file named by a sweep glob is listed with `non_view_template`, `unsupported_template_engine` or `rejected_by:view_templates`. Written by full and incremental runs alike; older indexes may omit it. Informational, never a validation failure. |
| `git_commits.json` | Optional [commit table](#commit-table): HEAD-reachable commits in a bounded window that touched an indexed path, with their files, and a path => commits index. Absent when the writer had no readable git history or predates the table; absence is unknown history, not "no commits". |
| `flows/flow_index.json` and flow documents | Optional precomputed flows. Use the index's relative paths; do not invent flow filenames. |
| `flows/by_unit.json` | Optional inverted precomputed-flow membership, keyed by unit identifier, then unit type, with sorted unique entry-point arrays. See [inverted flow membership](#inverted-flow-membership). |
| `SUMMARY.md` | Generated human-readable summary, not a machine schema. |

Unit summaries identify units, but do not carry an artifact filename. Their
`file_path` names the application's source file, not the unit JSON file. To avoid
reimplementing filename normalization, scan JSON files in a needed type directory
(excluding `_index.json`) and match the JSON `identifier` **and** `type`. The same
identifier can exist in multiple types. The full unit fields are documented in
[Extractor reference](EXTRACTOR_REFERENCE.md#extractedunit-field-reference).

The graph's `nodes`, typed variants, forward/reverse relationships and relationship
metadata belong to the graph format; preserve them when transporting the index.
Extractor directories can contain multiple unit types: `graphql/` contains
`graphql_type`, `graphql_mutation`, `graphql_resolver`, and `graphql_query`, while
`rails_source/` contains `rails_source` and `gem_source`, and `routes/` contains
`route` and `route_file`. Validate and retain the
artifact's actual type instead of deriving it by singularizing the directory.

Do not flatten typed variants into a single node per textual identifier. The
static Woods self-map has the same publication envelope but different type
families and `manifest.provenance.mode`; it is not Rails runtime evidence.

### Constant-reference spans

The development writer's bounded #751 addition publishes `metadata.references`
in unit JSON separately from deduplicated graph edges:

```json
{"line": 8, "column": 4, "length": 6, "target": "Target", "target_type": "service", "kind": "constant", "confidence": "verified"}
```

The array preserves repeated reads and uses the actual typed registry target.
Line numbers are 1-based in that unit's published `source_code`; columns are
0-based UTF-8 byte offsets from the line start, and length is a byte count
(including original newlines for a multiline qualified constant). Do not use
character or UTF-16 string offsets to slice spans. Use `source_line_map` to
translate annotated lines to the primary source, or validated
`source_contributors` ranges for a composite library unit. Generated lines and
unproven source placement have no spans. An empty array reports no admitted,
placeable occurrences in this bounded pass; older indexes may omit the field.
It does not prove complete call coverage or method-level reachability.

The bounded #756 addition optionally attaches the immediate syntactic selector
to an admitted constant receiver:

```json
{"line": 8, "column": 4, "length": 20, "target": "NotifySubscribersJob", "target_type": "job", "kind": "constant", "confidence": "verified", "method": "perform_later"}
```

Coordinates still cover only the original constant, including any qualification
or root prefix. `method` is a UTF-8 string of 1–4096 bytes without control
characters. Operators, punctuation and Unicode names are supported. Both parser
backends apply the same bound; an unsupported selector is omitted while its
admitted constant span remains. Bare reads and argument constants also omit the
key, rather than using `null` or an empty string. Readers must accept mixed
seven- and eight-key records and older indexes without selector evidence.

Singleton parentheses are transparent: `(Target).call`, `Target.()`,
`Target&.call` and `Target::call` record `call`. Simple setters and indexing
record selectors such as `value=`, `[]` and `[]=`, and unary operators retain
their AST names such as `-@`. Compound writes (`Target.value += 1`,
`Target[index] ||= value`, and their other operator/boolean forms) omit a
selector on that receiver: one string cannot represent both getter and setter.
Nested calls in their arguments remain independent occurrences. Multi-expression
groups are not transparent receivers.

Rescue and `for` assignment targets, including nested destructuring targets,
also retain their admitted constant spans without a selector. Calls within their
receivers or index arguments retain their own immediate selectors. Ordinary
explicit setters remain annotated. An absent `method` means selector evidence
is unavailable in this bounded pass; it does not prove that the occurrence
cannot dispatch a call.

`verified` describes typed constant resolution, not method existence, visibility,
execution, dispatch or definition owner. For `Target.new.call`, the constant's
selector is `new`; for `Target.send(:call)`, it is `send`. Inherited job APIs and
framework-mediated mailer dispatch do not establish a method-definition owner.
This field adds no method table, excerpt, anchor or method-scoped reverse impact.

The generation-local internal reference cache is format 6 for this writer;
format 5 and earlier require a full baseline rebuild before incremental writes.
Readers may continue to serve their original generation throughout a refused
upgrade. Copy the complete selected payload, including its reference cache.
See [extractor coverage](EXTRACTOR_REFERENCE.md#constant-source-references)
and [baseline upgrades](INCREMENTAL_EXTRACTION.md#source-reference-baseline-and-upgrades).
Qualification used the complete tracked synthetic `apps/rails-8.0-large` corpus
at woods-testbed `743a755dc88e87cf6c9d71562cbd144188d55974`, with the smoke dataset,
seed `20260914` and reference time `2026-09-14T12:00:00Z`. Fresh full extractions
compared Woods baseline `d5e3cb43bc9c9e442229fb942b6df533293797f6` with reviewed
candidate `6a023b02e5cd2327bff060ebe17eb04cb928bae7` under Ruby 3.3.1, Bundler
2.5.11 and Rails 8.0.5.1 (`aarch64-linux`), with identical non-Woods dependencies.

Both corrected extraction children and the comparison passed: all 449 typed
units had identical source paths, hashes and bytes; 111 verified spans across
40 units passed validation. Complete serialized unit JSON, including empty
reference arrays, grew from 2,826,201 to 2,859,614 bytes (+33,413, **1.182258%**),
below #751's approximately 15% decision threshold on this corpus. The private
reference cache was counted separately: 76,791 to 82,048 bytes (+5,257,
6.845854%). Total active payload grew from 3,470,098 to 3,508,760 bytes (+38,662,
1.114147%); all raw byte categories reconciled without normalization or
subtraction. Keys, other generations, logs, database and bundle were excluded.
No sidecar format is introduced.

An earlier comparison using different Woods mount paths failed the middleware
source-equality gate and was not a pass. The corrected pair staged both exact
snapshots sequentially at the same physical gem path in fresh processes,
retaining the strict equality gate. The earlier differing source text was not
retained, so mount-path confounding remains an inference for that failed run.
Separate validation passed 273 focused examples and two booted source-reference
equivalence examples; no local full suite or broad backend matrix was run. These
checks qualify the measured payload-size decision on this exact corpus and
provide the listed focused/booted evidence. Companion source and installed-artifact
transition acceptance is a separate gate; ordinary CI does not execute it. They
do not complete #751, qualify the later #756 selector addition, establish
method-level reverse impact or qualify a whole release.

### Commit table

`git_commits.json` lists every HEAD-reachable commit inside the window that
touched at least one indexed path (an application-owned `file_path` or
`source_paths` entry of a unit in this generation's graph), newest first in
`git log` order. It is optional: no file is written for an application without
readable history (no `.git` at the root, git missing, a shallow clone, a linked
worktree whose git directory is not reachable) or when the walk fails. An empty
`commits` array means readable history with nothing in the window.

```json
{
  "schema_version": 1,
  "head": "361468d0c3...",
  "since": "2025-10-23",
  "window_days": 365,
  "max_commits": 5000,
  "max_files_per_commit": 100,
  "line_stats": true,
  "hunk_budget": 50000,
  "indexed_paths_sha256": "9f2c...",
  "truncated": false,
  "commits": [
    {
      "sha": "361468d0c3...",
      "parents": ["2e8d0b4a17..."],
      "author": "Leah Armstrong",
      "date": "2026-10-20T14:02:11+02:00",
      "message": "Touch the author when a post is saved",
      "description": "Authors expect their profile's updated_at to move when they publish.",
      "files": [
        { "path": "app/models/post.rb", "status": "modified", "additions": 6, "deletions": 1,
          "hunks": [{ "old": [38, 1], "new": [38, 6] }], "hunks_truncated": false },
        { "path": "spec/models/post_spec.rb", "status": "added", "additions": 14, "deletions": 0,
          "hunks": [{ "old": [0, 0], "new": [1, 14] }], "hunks_truncated": false }
      ],
      "files_omitted": 0
    }
  ],
  "paths": {
    "app/models/post.rb": ["361468d0c3...", "2e8d0b4a17..."]
  }
}
```

| Field | Contract |
|---|---|
| `schema_version` | `1`. A reader must refuse another value rather than guess. |
| `head` | The full HEAD sha the walk started from; matches the manifest's `git_sha` for the same run. |
| `since`, `window_days` | The window: commits whose committer date is on or after `since` (UTC midnight), `window_days` before the run's UTC date. |
| `max_commits`, `truncated` | The commit bound (`config.git_commit_table_limit`); `truncated: true` when older commits inside the window were dropped by it. |
| `max_files_per_commit` | The per-commit file bound (`config.git_commit_table_files_limit`). |
| `line_stats`, `hunk_budget` | Whether files carry line counts and hunks (`config.git_commit_table_line_stats`, default true) and the table-wide hunk bound (`config.git_commit_table_hunk_budget`, default 50000). Both are part of what decides the table's content. |
| `indexed_paths_sha256` | SHA-256 of the sorted, newline-joined indexed paths the table was built for. With `head`, `since` and the bounds it decides the content: an incremental run that finds them all unchanged keeps the file, and otherwise rebuilds it whole. |
| `commits[].sha`, `parents` | Full object names. A merge lists every parent; its `files` are its diff against the first parent, as for `metadata.git`. |
| `commits[].author`, `date` | The author name as git records it (no email) and the committer date, ISO 8601 with offset. |
| `commits[].message`, `description` | The subject line, and the rest of the message trimmed (`""` when there is none). |
| `commits[].files`, `files_omitted` | Every path the commit touched inside the application root, indexed or not, application-relative, in git's order, with `status` `added`, `modified`, `deleted` or `type_changed`; renames appear as a deletion and an addition. At most `max_files_per_commit` are listed; the rest, and any path that is not valid UTF-8, are counted in `files_omitted`. |
| `commits[].files[].additions`, `deletions`, `hunks`, `hunks_truncated` | When `line_stats` is true: added and removed lines (null for a binary file or one the patch walk did not report), and the hunks as `[{old: [start, length], new: [start, length]}]` in the commit's own coordinates against its first parent (git `-U0`; an empty side starts at the line before). At most 100 hunks per file and `hunk_budget` across the table, newest commits first; a file cut by either says `hunks_truncated: true` and keeps its counts. Hunks are not mapped onto the current file. |
| `paths` | Each indexed path that has a commit in the table, sorted, to its commits' shas, newest first. Never bounded by `max_files_per_commit`, so co-change is complete: the commits of one path and the other `paths` entries that list the same shas. |

The walk is the one per-unit `metadata.git` uses: HEAD only (no unmerged branches
or remote refs), rooted at the application with `git -C`, honouring
`WOODS_GIT_DIR`, and mapping a nested application's paths out of a monorepo.
`metadata.git` counts a rolling 365 days; the table's window starts at a UTC
day boundary, so near the boundary the two can differ by up to a day.

### Inverted flow membership

When flows are precomputed, `flows/by_unit.json` is published alongside
`flow_index.json` in the same generation payload. For example:

```json
{
  "OrdersController": {"controller": ["OrdersController#create"]},
  "Shared": {
    "model": ["OrdersController#create"],
    "service": ["OrdersController#create", "OrdersController#show"]
  }
}
```

The two `Shared` entries represent distinct typed units. Look up both the
identifier and type; do not flatten the types. A controller step such as
`OrdersController#create` contributes the unit identity `OrdersController`
with type `controller`. Values are entry-point keys in `flow_index.json`,
not filenames. Keys are sorted recursively and arrays are sorted and deduplicated.
An empty object is a valid index with no expanded flow steps.

Membership means that a typed step was expanded in that flow document, within
its assembly depth limit. Unexpanded operation targets and cycle sentinels
are excluded. This is bounded flow evidence, not proof of every possible runtime
path or a method-level impact report.

Incremental publication replaces memberships for reassembled controllers,
removes deleted controllers' entries, and carries untouched memberships forward.
Older generations can contain flow documents without this inverse. On the next
flow delta, Woods reconstructs retained memberships from those documents; it
aborts publication if the required documents or a present inverse are unreadable
or malformed. A no-op can leave the older generation unchanged.

The artifact is optional: older writers and indexes without precomputed flows
may omit it. Absence means the lookup is unavailable, not that no entry point
touches a unit. Consumers can derive the same mapping from typed steps in the
selected generation's flow documents, or assemble flows on demand where that
capability is available. Do not mix documents from different generations.

### Semantic graph validation

`woods:validate` checks raw graph data against the unit indexes and artifacts in
one pinned published generation. This validation is included in Woods `2.0.0`.
It checks the shapes of `nodes`, `edges`, `reverse`, `file_map`,
`type_index`, and optional `variants`; typed identities must be unique and agree
with the actual indexed units. Forward sources must exist. Reverse, file, and
type memberships must match the union of primary and variant contributions.
When present, `reverse_via` must preserve the typed forward records and their
relationship attributes, including duplicate-record multiplicity.

Cycles, recursion, shared paths, cross-type identifier collisions, nil file paths,
and legacy bare-string edges are valid. Absent optional legacy fields remain
legal. A target absent from the nodes is an unresolved reference, not automatically
corruption: current metadata cannot distinguish an intentional external target
from an internal node and unit that are both missing. Validation cannot certify a
unique target type when several types share its name. A missing node whose typed
unit remains indexed is detectable and is an error.

The checker does not repair data, rerun extraction, or become a publication gate.
It reports identity/path diagnostics through the existing validation report and
nonzero task exit. It also supports the Woods static source map's explicitly
recorded type families; that does not give the map Rails runtime fidelity.
See [running validation from Ruby](PUBLISHED_INDEX.md#validate-a-published-generation)
and [semantic error recovery](TROUBLESHOOTING.md#semantic-graph-validation-errors).

### File profiles and file membership

`file_map[path]` lists units associated with a source file, including whole-file
profiles. It does not promise that every identifier names a Ruby constant. A
node with `source_paths` (a library unit assembled from several files, or a rake
task defined or enhanced in several files) is mapped from every listed path
instead of its `file_path`, and validation expects exactly those paths. New
writers mark graph nodes of types `caching`, `configuration`, `test_mapping`,
`rails_source`, and `gem_source` with `"kind": "file_profile"`. The same field
appears on non-primary typed variants.

For example, `app/controllers/things_controller.rb` can map to both
`ThingsController` and a caching unit named `app/controllers/things_controller.rb`.
Inspect each typed node's `kind` to distinguish the profile; both retain their
file membership so a source edit refreshes both units. Do not classify units by
comparing the identifier with the path, and do not interpret a missing `kind` as
proof that the unit names a constant.

Older indexes omit the marker. Woods derives it from these known extractor types
when loading and republishing a graph, including unchanged incremental nodes.
Raw consumers of older indexes must treat absent markers as unclassified or use
the documented type list. Identifiers, `file_map`, and type membership retain
their existing shapes; older readers can ignore `kind`.

### Reverse relationship records

New writers add `reverse_via` to `dependency_graph.json`. Each target identifier
maps to its incoming relationship records, including the owning source type:

```json
{
  "reverse": { "Gadget": ["Widget"] },
  "reverse_via": {
    "Gadget": [{ "source": "Widget", "source_type": "service", "via": "render" }]
  }
}
```

The existing `reverse` arrays retain their bare identifiers. `reverse_via` includes
edges from primary nodes and typed variants; several records can share a source
and target while differing in type, relationship, or association attributes.
Optional `through`, `through_db`, and `disable_joins` values match the forward
edge. On an association edge `through` is the through association; on a
`job_enqueue`, mailer or service edge it is the sorted, comma-joined list of
the public methods that reach the target (see "Method side effects" in
[EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md)). A `null` relationship means
unknown legacy evidence. Target type remains
unresolved when the target identifier belongs to multiple types; the source type
does not resolve that ambiguity.

These are recorded dependencies, not proof that changing a target breaks every
source. For example, `factory_for` and migration `reference` edges describe
different relationships from a runtime `render` edge. Consumers can inspect one
target bucket without scanning the whole forward graph. Buckets and records are
deterministically ordered, but consumers should treat the ordering as incidental.

Older graphs omit `reverse_via`; absence means relationship detail must be derived
from forward edges and variants, not that there are no dependents. Woods rebuilds
this derived index from forward evidence when loading and republishing a graph.
Existing readers can ignore the additive field; a subsequent changed extraction
or full run publishes it. A no-op leaves the previous generation unchanged.

### What is outside this structural snapshot

`woods.json`, `dumps/`, embedding checkpoints, temporal snapshots, watch status,
pending paths, MCP task records, exporter state and extraction/startup lock files
have separate lifecycles. Their presence is configuration-dependent. Do not glob
them into a structural payload or assume `generation.json` commits them together.
A semantic/MCP deployment also needs its configured stores and artifacts; copying
a structural payload alone does not clone that deployment.

`<output>/.source-inputs.key` is private operational state used to verify source
identities. Never include it in a published/exported structural snapshot; without
it, a recipient can still read the index but source freshness is unknown.

Temporary filenames, abandoned payloads, lock sidecars, retained-directory counts,
and summary formatting are implementation details. Never remove or modify locks
to make a reader proceed.

## Atomic publication is not indefinite retention

For a payload publication, Woods writes the payload, flushes it, and atomically
replaces `generation.json` last. Capturing that pointer once selects a complete,
immutable structural generation. Opening each file through a freshly reread pointer
can mix generations and defeats that guarantee. A failed/no-op run does not advance
the pointer. [Durability details](PUBLISHED_INDEX.md#durability-the-pointer-is-the-commit-point)
explain the flush boundary.

Retention can delete an older payload after the reader selects it. The default
retains three generations, not three minutes. To keep a multi-file read or copy
safe from Woods retention:

1. Read and validate the pointer; resolve its payload inside the root.
2. Open that payload's existing `manifest.json` **read-only** and take a shared
   advisory `flock` on that open file. Do not create a new lock file.
3. Re-read the pointer and confirm it is unchanged; verify the pathname still
   names the open manifest inode. A pruner may have won between steps 1 and 2.
4. Keep the handle/lock open for **all** reads or the complete copy. Use the single
   captured payload path throughout. Once pinned, a later pointer advance is fine.
5. Close the handle when done. On a race, discard partial results and retry the
   entire operation from step 1, with a bounded retry count.

Woods retention attempts a nonblocking **exclusive** `flock` on that same manifest
before deletion and skips a payload held by readers. These are advisory filesystem
locks, not Woods' writer-coordination locks. Ordinary readers need no exclusive
lock and need not take `extraction.lock` or its guard. A lock-free reader must
accept disappearance and restart the whole read; it must never silently replace
missing files with files from another generation.

This protocol protects against cooperating retention only. It does not protect
against `woods:clean`, manual deletion, index replacement, or a filesystem that
does not coordinate `flock` across its clients. Stop writers/cleanup and read an
immutable snapshot if that protection is unavailable. Flat indexes (including
full-extraction fallback when a payload cannot be created) have individually
replaced files, not multi-file atomicity; read/copy them only with writers stopped.

### Persistent retention pins

Current source adds `woods:pin[N]` and `woods:unpin[N]` for a review base that
must survive several extractions and reader restarts. Check that the installed
Woods version includes these tasks before using them. `N` is the positive
`generation.json.number` of this index, not a Git SHA, snapshot ID, pointer token,
or payload path. Capture it before extracting the review head:

```bash
WOODS_OUTPUT=tmp/woods bin/rails 'woods:pin[42]'
WOODS_OUTPUT=tmp/woods bin/rails woods:stats
# Save the review result, then release the base:
WOODS_OUTPUT=tmp/woods bin/rails 'woods:unpin[42]'
```

The Ruby equivalent is `Woods::PayloadStore.new(output_dir).pin(42)` or
`.unpin(42)` after `require 'woods/payload_store'`. Each returns `true` when it
changes the pin set and `false` when already in the requested state. `.pins`
returns sorted integer generation numbers. Pins are a set, not reference counts:
coordinate shared ownership before unpinning a base another review still needs.

Pinning requires an existing retained `payloads/gen-N` directory at or below the
current published number, a valid atomic publication pointer, and JSON-object
manifest and graph artifacts. Missing, future, malformed, incomplete, symlinked,
and flat payloads are rejected. There is no historical publication ledger:
validation identifies retained payloads in the current index history; it cannot
certify manually restored directories. Generation numbers are local to the index
lifetime. Replacing/resetting its pointer or payload tree is outside this contract.
Woods refuses to reuse or rename over a pinned payload number during writer
recovery, preserving its bytes if the marker is lost. An existing pin can be
released even if external cleanup removed its payload.
An unpinned unknown generation is rejected rather than silently accepted.

Pins persist in `<output>/generation_pins.json`, a versioned operational JSON
object (`{"version":1,"generations":[42]}`), outside immutable payloads and
separate from temporal snapshot retention. Do not copy it into an exported
structural snapshot. Missing state means no persistent pins for older indexes;
unreadable/malformed state fails retention closed and is reported as an error.
Update pins through Woods rather than editing state or lock files directly.

Pin/unpin updates and pruning serialize on a stable advisory lock and state
updates use durable atomic replacement. If pruning wins the race and removes a
payload, pinning fails; a successful pin is visible before pruning can delete it.
Retention keeps pinned payloads **in addition to** the usual recent-generation
budget, logs each skipped persistent pin, and retries released payloads on the
next publication. `woods:stats` lists the persistent numbers. Releasing a pin
does not delete a payload immediately; an active reader's manifest lock still
protects it. Disk usage can grow until pins are released.

Persistent pins protect against cooperating Woods retention. `woods:clean`,
manual deletion, index replacement, and older Woods writers that do not understand
the registry remain outside that guarantee. Keep the manifest-lock read protocol
above for complete reads/copies, and coordinate cleanup and writer upgrades.

## Bash and jq: read one pinned generation

Requires Bash, jq, GNU `realpath`, util-linux `flock`, and Linux `/proc`. Save as
`read-woods.sh`, then run `bash read-woods.sh '/path with spaces/tmp/woods'`.
The final command reads manifest and graph under the same lock. Substitute other
reads or a complete copy **inside** the script before it exits. Printing a path
and consuming it after the script exits does not keep it pinned.

Exit 75 means a possible publication/retention race: retry the whole script a
bounded number of times (for example three), discarding any previous output.
Other nonzero exits need investigation. A persistent 75 can mean a broken index.

```bash
#!/usr/bin/env bash
set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
retry() { echo "$*; retry the whole read" >&2; exit 75; }
root=$(realpath -e -- "${1:?provide the index root}")
[[ -d "$root" ]] || fail 'Index root is not a directory'
[[ -f "$root/generation.json" ]] || fail 'Missing pointer: legacy or unpublished index'
marker=$(cat -- "$root/generation.json") || retry 'Cannot read pointer'
jq -e '
  if type != "object" then false
  elif (.number | type) != "number" then false
  else (.number >= 1 and (.number | floor) == .number)
    and (.token | type == "string" and length > 0)
    and (.payload | type == "string" and length > 0)
    and (.payload | explode | all(. >= 32 and . != 127))
  end
' <<<"$marker" >/dev/null || fail 'Invalid pointer or flat layout'
relative=$(jq -r '.payload' <<<"$marker")
[[ "$relative" != /* ]] || fail 'Absolute payload path'
payload=$(realpath -e -- "$root/$relative") || retry 'Missing payload'
[[ -d "$payload" && "$payload" == "${root%/}/"* && "$payload" != "$root" ]] \
  || fail 'Payload must resolve inside the index root'
exec 9< "$payload/manifest.json" || retry 'Missing manifest'
flock -sn 9 || retry 'Cannot pin manifest'
current=$(cat -- "$root/generation.json") || retry 'Pointer disappeared'
[[ "$current" == "$marker" && "$payload/manifest.json" -ef /proc/self/fd/9 ]] \
  || retry 'Publication changed or retention removed the payload'
jq -n --argjson generation "$marker" \
  --slurpfile manifest "$payload/manifest.json" \
  --slurpfile graph "$payload/dependency_graph.json" \
  'if ($manifest | length) == 1 and ($manifest[0] | type) == "object"
      and ($graph | length) == 1 and ($graph[0] | type) == "object"
   then {generation: $generation, manifest: $manifest[0], dependency_graph: $graph[0]}
   else error("Manifest and graph must each contain exactly one JSON object") end'
# Descriptor 9 closes on exit, releasing the retention pin.
```

## Python: keep the pin while using the payload

Requires Python 3.9+ on Unix with working `fcntl.flock`. Save as `read_woods.py`
and run `python3 read_woods.py '/path with spaces/tmp/woods'`. The context manager
retries acquisition three times. Errors during the read/copy propagate: discard
partial output before retrying the entire operation. The scripts assume a trusted
Woods-owned index; path containment is not a sandbox for hostile filesystem changes.

```python
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sys
import time


@contextlib.contextmanager
def pinned_payload(index_root):
    root = Path(index_root).resolve(strict=True)
    pointer = root / "generation.json"
    if not pointer.is_file():
        raise ValueError("Missing pointer: legacy or unpublished index")
    for attempt in range(3):
        handle = None
        try:
            raw = pointer.read_bytes()
            marker = json.loads(raw)
            if not isinstance(marker, dict):
                raise ValueError("Pointer must be an object")
            number, token, name = (marker.get(k) for k in ("number", "token", "payload"))
            if type(number) is not int or number < 1 or not isinstance(token, str) or not token:
                raise ValueError("Invalid generation identity")
            if not isinstance(name, str) or not name or Path(name).is_absolute():
                raise ValueError("Invalid payload path or flat layout")
            if any(ord(char) < 32 or ord(char) == 127 for char in name):
                raise ValueError("Control character in payload path")
            payload = (root / name).resolve(strict=True)
            if not payload.is_dir() or root not in payload.parents:
                raise ValueError("Payload must resolve inside the index root")
            manifest = payload / "manifest.json"
            handle = manifest.open("rb")
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
            if pointer.read_bytes() != raw or not os.path.samestat(os.fstat(handle.fileno()), manifest.stat()):
                raise BlockingIOError("Publication changed or payload was removed")
        except (FileNotFoundError, BlockingIOError):
            if handle is not None:
                handle.close()
            if attempt == 2:
                raise
            time.sleep(0.05)
        except BaseException:
            if handle is not None:
                handle.close()
            raise
        else:
            break
    try:
        yield marker, payload
    finally:
        handle.close()


if __name__ == "__main__":
    with pinned_payload(sys.argv[1]) as (generation, payload):
        manifest = json.loads((payload / "manifest.json").read_text(encoding="utf-8"))
        graph = json.loads((payload / "dependency_graph.json").read_text(encoding="utf-8"))
        if not isinstance(manifest, dict) or not isinstance(graph, dict):
            raise ValueError("Manifest and graph must each contain exactly one JSON object")
        # Read more artifacts, or copy the whole payload, before leaving this block.
        print(json.dumps({"generation": generation, "manifest": manifest, "dependency_graph": graph}))
```

## Shipping a structural snapshot

While the pin is held, copy the selected payload into an unpublished staging
location. Preserve the payload's relative path and pair it with the **captured**
`generation.json`, not a later pointer reread from the live index. For example,
a captured `payloads/gen-42` must still resolve to that directory in the exported
root. Validate the copied manifest and graph, then publish the staged copy as a
whole, or upload its payload first and switch the destination pointer last.
Do not upload `generation.json` first or advertise a failed/partial copy.

The retention lock is local coordination; do not copy its file descriptor or
writer lock files. Copying `manifest.json` normally copies content, which is correct.
Objects in a destination store do not inherit the source's locking guarantees;
protect any later destination pruning with that destination's own reader protocol.

## Compatibility within Woods 2.x

Consumers may rely on the pointer field meanings, relative payload resolution,
the complete-payload publication boundary, manifest/graph locations, and JSON unit
identity described here. Additive JSON fields, new extractor families, new reason
values, optional artifacts and additional root-level state may appear in 2.x.
Ignore unknown fields and inspect available types instead of hardcoding a directory
count. Existing field meanings and required-file locations are compatibility
surfaces; incompatible changes require an explicit migration contract.

Do not bind to temporary names, a fixed token length, directory listing order,
retention count, internal lock sidecars, or Markdown summary formatting. Check the
installed Woods version and its release's documentation when consuming older
prereleases; this guide describes the current source contract, not a promise that
every prerelease contains every optional field or retention improvement.
