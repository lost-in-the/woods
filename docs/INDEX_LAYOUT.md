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
│       ├── dependency_graph.json
│       ├── graph_analysis.json
│       ├── SUMMARY.md
│       ├── models/
│       │   ├── _index.json
│       │   └── <unit filename>.json
│       └── flows/
│           ├── flow_index.json
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

| Artifact | Presence and meaning |
|---|---|
| `manifest.json` | Required for a complete structural publication. Counts by extractor directory, totals, extraction timestamp and provenance. Optional fields vary by writer/version; see [writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance). |
| `dependency_graph.json` | Required for a complete structural publication. Typed graph data; an empty graph is valid. |
| `<type>/_index.json` and unit JSON | Present for extracted families. `_index.json` is an array of unit summaries; an empty array is valid. Disabled/unavailable families may be absent. Do not infer completeness from a fixed count of directories. |
| `graph_analysis.json` | Derived graph analysis when produced. Treat absence as unavailable analysis, not an empty or corrupt unit index. |
| `flows/flow_index.json` and flow documents | Optional precomputed flows. Use the index's relative paths; do not invent flow filenames. |
| `SUMMARY.md` | Generated human-readable summary, not a machine schema. |

Unit summaries identify units, but do not carry an artifact filename. Their
`file_path` names the application's source file, not the unit JSON file. To avoid
reimplementing filename normalization, scan JSON files in a needed type directory
(excluding `_index.json`) and match the JSON `identifier` **and** `type`. The same
identifier can exist in multiple types. The full unit fields are documented in
[Extractor reference](EXTRACTOR_REFERENCE.md#extractedunit-field-reference).

The graph's `nodes`, typed variants, forward/reverse relationships and relationship
metadata belong to the graph format; preserve them when transporting the index.
Do not flatten typed variants into a single node per textual identifier. The
static Woods self-map has the same publication envelope but different type
families and `manifest.provenance.mode`; it is not Rails runtime evidence.

### File profiles and file membership

`file_map[path]` lists units associated with a source file, including whole-file
profiles. It does not promise that every identifier names a Ruby constant. New
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
edge. A `null` relationship means unknown legacy evidence. Target type remains
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
