# Offline Woods review-context packets

This development tool supplies the input side of a Rails-aware Jev review trial:
exact selected source/test files plus the Woods graph and extracted-unit context
associated with those paths. It runs from this Woods source checkout with its
bundle, requires no Rails boot, and makes no model, network or credential calls.
It is excluded from the packaged gem and is not a new MCP tool.

The prior audit found two avoidable sources of evidence loss: adapters that kept
only one unit per path or textual identifier, and test summaries that retained
setup while dropping assertions. This exporter addresses those input problems.
It does not establish that Jev identifies bugs accurately, and a valid packet is
not approval to merge code.

## Run it

Use a modern, already published Woods index and an explicit source root. Run the
exporter outside Rails: an ambient `Rails.root` is rejected because the native
graph loader would otherwise rebase paths implicitly. The source root can be a
separate application checkout; the index must be visible on this machine.

First create a selection manifest using the existing `Evidence.read` schema.
Choose implementation files, relevant complete specs, and the helpers/shared
examples they need. This illustrative Ruby snippet writes only the manifest:

```ruby
require 'json'
require 'digest'
require 'pathname'

root = Pathname.new('/absolute/path/to/app')
paths = [
  'app/models/order.rb',
  'spec/models/order_spec.rb',
  'spec/support/order_helpers.rb'
]
manifest = {
  'schema_version' => 1,
  'evidence' => paths.map do |path|
    {
      'evidence_id' => path,
      'path' => path,
      'sha256' => Digest::SHA256.file(root.join(path)).hexdigest
    }
  end
}
File.write('/tmp/review-selection.json', JSON.pretty_generate(manifest))
```

From the Woods checkout:

```sh
bundle exec ruby script/typesafe/export_review_packet.rb \
  /absolute/path/to/app /absolute/path/to/app/tmp/woods \
  /tmp/review-selection.json > /tmp/review-packet.json
```

Exit 0 means export succeeded. Exit 2 means invalid/unreadable input, unsupported
index layout, or a size limit failure. No partial JSON or source bytes are printed
on failure. Shell redirection can still create an empty output file on failure;
check the exit status before using it. Stdout is one compact JSON object plus a
newline. It contains source code; keep it with the experiment's local artifacts.

The selection JSON is limited to 128 KiB. The evidence reader permits 1–100
entries, 1 MiB per file and 4 MiB in total. The complete compact packet is limited
to 8 MiB, excluding the trailing CLI newline. These are local experiment limits,
not TypeSafe context limits. Overflow fails rather than trimming code, tests or
indexed metadata. Select a smaller, coherent context when it fails; do not split
off an assertion or helper merely to fit. No token estimate or provider request
budget is inferred from the byte limit.

## Packet fields

The Ruby API is:

```ruby
require_relative 'script/typesafe/review_packet'

packet = WoodsDevelopment::TypeSafe::ReviewPacket.build(
  root: '/absolute/path/to/app',
  index_dir: '/absolute/path/to/app/tmp/woods',
  manifest: manifest
)
```

The packet has `schema_version: 1`, `purpose: "woods_review_context"`, and:

| Field | Meaning |
| --- | --- |
| `source_lineage` | `unverified` by default; `recorded_extraction` only when the Ruby API verifies a matching local extraction receipt. |
| `test_context` | Always `explicit_files_only`; test closure is supplied by the caller. |
| `index.generation` | Number of the one generation pinned for the whole index read. |
| `index.manifest` | Full parsed manifest, including any writer version, extraction time, Git fields and static-map provenance. Missing provenance is not fabricated. |
| `index.manifest_sha256`, `index.graph_sha256` | SHA-256 of the exact artifact bytes consumed. The manifest digest does not hash the whole index. |
| `evidence` | Manifest-order entries with `evidence_id`, `path`, `sha256`, exact UTF-8 `content`, and `unit_keys` as `[identifier, type]` pairs. |
| `units` | Unique records sorted by identifier and type, each with `identifier`, `type`, `node`, `edges`, `unit_status`, `data`, and `data_sha256`. |
| `unmapped_paths` | Selected file paths for which no typed graph membership was found. Files themselves remain in `evidence`. |

`data` is the full typed unit read through `PublishedIndex`. It is not an excerpt
or a replacement for the physical file. Indexed `source_code` can contain inlined
concerns and generated/schema context. `data_sha256` hashes Ruby's compact
`JSON.generate(data)` bytes, preserving parsed insertion order; it is **not** the
digest of the on-disk unit JSON or a language-independent canonical JSON hash.
Archive the emitted packet and hash its bytes separately for transport/replay.

If the graph unit cannot be hydrated, its record is retained with
`unit_status: "unavailable"`, `data: null`, and `data_sha256: null`. Export still
succeeds so the missing evidence remains inspectable. A hydrated unit with the
wrong identifier/type is an error. `gem_source` uses Woods' `rails_source` storage
locator while keeping the actual `gem_source` identity.

Consumers must inspect both `unmapped_paths` and every `unit_status`. Neither an
unmapped path nor an unavailable unit proves absence of behavior or test coverage.
Specs commonly have no standalone index entry. There is no overall
`complete: true` flag and no automatic passing/failing review judgment.

## Graph and source preservation

The adapter uses Woods' native `DependencyGraph.from_h`, typed node accessors and
`edge_records`. It enumerates primary **and variant** nodes. Selection takes the
union of native `units_for_path` membership and every node whose path matches, so
a legacy scalar file map does not hide another registered node in the same file.
Historically discarded nodes cannot be reconstructed. The original index is never
changed.

Each record retains the source type owning its edges, plus native relationship
attributes such as `via`, `through`, `through_db` and `disable_joins`. Target
identifiers stay identifiers: the exporter does not invent a unique target type
or automatically hydrate target/dependent files. A native file-map fallback can
associate a path with a node whose recorded path differs; its original `node`
remains in the packet so this discrepancy is visible.

The explicit graph records contain forward edges. The exporter performs no
reverse-dependent expansion, relationship filtering, or entry-point counting.
Full unit `data` can contain an original unfiltered `dependents` array; its presence
does not make it a list of callable entry points or verified change impact.

Paths match exactly as relative names or absolute names beneath the supplied
root. There is no basename match or automatic translation of an old container
root into the current host root. Such paths remain unmapped. Symlink aliases do
not create extra graph memberships. Selected source files must resolve inside
the source root and obey the evidence reader's regular-file, UTF-8 and path rules.

Whole physical files are preserved, including Unicode names, CRLF, empty files
and missing final newlines. Hashes are checked before admission. No RSpec regex
compaction, code evaluation, Git command, shell expansion or extension filtering
is involved. Ruby, Rake, ERB, YAML and ordinary text can be explicitly selected.
Invalid UTF-8 is rejected; the exporter is intended for text and does not detect
file formats.

## Snapshot guarantees and remaining limits

`PublishedIndex.open` pins and locks one numbered generation until all reads and
packet construction finish. Publishing a newer generation cannot mix its units
into this packet. Cooperating retention cannot remove the pinned payload while
the reader holds it. Flat legacy indexes are rejected because they do not offer
an atomic multi-file publication. See the [native reader contract](../../docs/PUBLISHED_INDEX.md)
and [filesystem layout](../../docs/INDEX_LAYOUT.md).

The index is trusted Woods-generated data, not an untrusted archive sandbox.
Native readers load its JSON into memory; the final packet cap is not a bound on
total process memory. Locks do not prevent manual deletion, hostile concurrent
filesystem changes, or arbitrary edits to published payload files. Physical
source files are separately read and hash-checked, not locked with the index.

The source manifest authenticates neither Git history nor runtime freshness.
An index's Git SHA, matching writer version, or matching file path cannot prove
that its metadata describes the selected source bytes. A static Woods self-map
has no Rails runtime fidelity; its manifest provenance is retained verbatim.
Before a meaningful Rails review trial, capture the correct source/base/head,
boot and extract that application as needed, verify lineage, and preserve the
exporter/reader revision alongside the packet. Do not relabel an old runtime index
joined to today's source as a historical PR snapshot.

For callback-dependent review, also verify that the **index producer** includes
[Woods #401](https://github.com/lost-in-the/woods/pull/401), commit
`87b7c66159c231e40f1f8589875790f7b94859f6`, and fully re-extract the matching host
source into a separate index. The fix corrects omitted model lifecycle callbacks;
both affected and corrected revisions identify as `2.0.0.beta2`, so the version
string alone is insufficient. Re-exporting an old index with a newer reader does
not repair its metadata. Even corrected callback metadata does not establish
complete side-effect analysis, especially for unresolved or non-method filters.

Automatic diff capture, changed-line location, shared-example/helper discovery,
dependency closure, historical overlays, labels/oracles, provider request limits,
paid inference and review scoring remain outside this tool. The next useful
experiment is to feed **the same verified packet** to a cheap Jev screening step
and a comparator, then measure correctness, abstentions, total cost and latency.
This exporter improves that experiment's inputs; it supplies no new model-quality
evidence by itself.

## Record a fresh local extraction

The optional Ruby API can bind a newly produced index to declared application and
producer bytes. The three-argument CLI above remains unchanged and emits
`unverified` packets. Use `ExtractionReceipt.capture` around the actual extraction
process, not around copying or re-exporting an old index:

```ruby
require_relative 'script/typesafe/extraction_receipt'
require_relative 'script/typesafe/review_packet'

receipt = WoodsDevelopment::TypeSafe::ExtractionReceipt.capture(
  root: app_root,
  source_paths: declared_application_paths,
  producer_root: woods_checkout,
  producer_paths: declared_woods_paths,
  producer_revision: full_40_character_commit,
  index_dir: fresh_index_dir
) do
  # Use an argument array for the real isolated Rails extraction process.
  # system returns true only for successful process termination.
  system(*extraction_command)
end

packet = WoodsDevelopment::TypeSafe::ReviewPacket.build(
  root: app_root, index_dir: fresh_index_dir, manifest: selection,
  receipt: receipt, producer_root: woods_checkout
)
```

Capture requires an absent or empty index directory and a block returning exactly
`true`. It fingerprints declared regular files before extraction, then verifies
the same bytes after successful publication. The receipt records their paths,
SHA-256 digests and byte counts, the supplied producer revision, current generation
number/token/payload, and every JSON artifact in that payload. Schema, inventory,
file-size, total-byte, and traversal limits reject oversized inputs. Payload
symlinks and special files are rejected; source/producer paths must resolve to
regular files inside their respective roots.

Export verifies the receipt before and after unit hydration under one pinned
reader. A changed declared file, altered JSON artifact, missing selected file in
the inventory, or moved current-generation pointer fails the receipt check.
Successful export adds `extraction_receipt` and sets `source_lineage` to
`recorded_extraction`. Without this option, ordinary generation-pinning behavior
and the original packet format remain unchanged.

This is an **unsigned trusted local capture over declared inputs**, not Git
verification, authenticated origin, or a complete runtime snapshot. The caller
supplies the revision and is responsible for invoking the stated producer and
application. Added files outside the declared list deliberately do not invalidate
a receipt. Neither environment/database state nor installed dependency contents
are captured automatically. Matching before/after bytes cannot detect transient
change-and-restore, and source files are not locked. Use a frozen source snapshot,
record configuration overlays and dependency/runtime versions, and keep original
artifacts when those distinctions matter. A caller can forge a receipt; hashes
protect reproducibility and accidental mismatch, not trust between adversaries.

See [the portable fixture kit](fixtures/README.md) for executable defect/control
examples. These tools are development-only and add no packaged command, MCP tool,
API key lookup, or automatic review gate.

## Validation

```sh
bin/rspec spec/development/typesafe
bin/rubocop script/typesafe spec/development/typesafe
```

Regression coverage includes typed collisions with distinct paths and edges,
several units in one file, legacy scalar maps and bare-string edges, full assertion
preservation, Unicode, generation rollover during export, missing units, stale
selected bytes, flat-index rejection, malformed inputs and packet overflow.
