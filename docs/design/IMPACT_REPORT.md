# Impact range core, JSON version 1

Development contract for the first slice of [W-12 / #762](https://github.com/lost-in-the/woods/issues/762),
under [#750](https://github.com/lost-in-the/woods/issues/750).
Woods owns the comparison and report; Woods Map will render it (design decision D-1).
This document describes implemented core behavior, not completion of the issue.

```ruby
require 'woods/impact/report'
report = Woods::Impact::Report.compare(index_dir, from: 'gen:41', to: 'now')
report.to_h     # recursively frozen, string-keyed values
report.to_json  # deterministic compact JSON, no write or transmission
```

## Endpoints and authority

Selectors accept positive integer payload generation numbers, explicit `gen:N`,
7–40 hexadecimal character SHA prefixes, or `now`. `to` defaults to `now`;
`from` is required. Both endpoints resolve against the retained catalog captured
when the current reader opens; `now` does not move during comparison. Each
selected `PublishedIndex` stays open through comparison and serialization value
construction. All readers close on success or exception.

A SHA matches retained manifests' `git_sha` provenance. Multiple matching
generations, including repeated captures at the identical full SHA, raise
`Woods::Impact::ResolutionError` with `gen:N` alternatives. Missing generations,
unknown SHAs and unsupported selectors fail; a missing current endpoint never
falls back to an older payload. Flat indexes are unsupported for ranges.
Errors retain the underlying I/O or parser exception for corrupt payloads.

This deliberately narrows design-study E-1's snapshot-based SHA resolution:
snapshot rows are keyed by SHA, same-SHA captures overwrite them, and incremental
extraction skips temporal capture. A snapshot row ID cannot identify a retained
payload generation. This slice therefore uses retained payloads as authority,
and reports snapshot facets as `unbound`; it never calls `SnapshotStore#diff`
as an empty-result fallback. Nearest-snapshot suggestions remain deferred.

Required inventories, manifest counts and total count must agree. Every indexed
unit must be readable through the guarded bulk reader and carry `source_code`
(string or null), object `metadata`, and array `dependencies`. Invalid inputs
raise; they never become an empty diff. Null source remains unavailable, even
on unchanged units, and is recorded per endpoint in `unknowns`.

## Envelope

| Key | Version 1 value |
|---|---|
| `schema_version` | Integer `1` |
| `range` | `from`, `to` endpoint objects |
| endpoint | Original `selector`, integer `generation`, nullable manifest `git_sha`, `manifest_checksum` (SHA-256 of its manifest) |
| `parameters` | `{"mode":"range"}`; no silently accepted filters |
| `changed` | Array sorted by identifier then actual type |
| change | `identifier`, `type`, `status` (`added`, `modified`, `removed`), `facets`, `categories`, `metadata_keys`, `diff_stats` |
| `diff_stats` | `source_before`, `source_after`: null when absent/unavailable, otherwise `bytes` and `lines` of each complete source |
| `affected`, `flows`, `tables`, `templates`, `tests`, `risks`, `commits` | Reserved empty arrays; corresponding coverage is `not_computed` |
| `coverage` | `complete:false`, `diff:"retained_payloads"`, `snapshot_facets:"unbound"`; all deferred analyses, including `focus`, explicitly `not_computed` |
| `unknowns` | Structured records for each deferred feature, unbound snapshot evidence, unavailable sources and unclassified changes |

`manifest_checksum` covers only `manifest.json`, not unit content. Different
payloads with byte-identical manifests can have the same checksum; it does not
establish payload-content integrity or uniquely identify a payload. The integer
generation identifies the retained payload within its index. The manifest
checksum is not a git SHA. Historical generation tokens are unavailable
and are omitted. The report contains no clock timestamp, random ID, source body,
snapshot row ID or host directory. Metadata key names and typed public identifiers
are retained. Consumers must treat these as index-derived content.

## Comparison and interpretation

Identity is `(identifier, actual type)` from complete unit bodies, including
shared-directory subtypes. No singularization or bare-identifier collapse occurs.
A type replacement is one removal and one addition. The synthetic fixture at
`spec/fixtures/impact/typed_range.json` exercises typed collisions, additions and removals.

The independently compared facets are `source`, `metadata`, `dependencies`, in
that order. Object keys are canonicalized recursively; array order is significant.
Generated top-level timestamps, source hash stamps, chunks and dependent summaries
are outside this slice's comparison. Added/removed units list all three facets.
These are payload-derived facet differences, not snapshot hashes from W-10.

`categories` is a separate, partial interpretation: source changes on known Ruby
behavior units, route units, templates and test units; changed dependency records;
and known metadata keys for schema, behavior, routing, templates and tests.
`RangeDiff::CATEGORY_KEYS` and `SOURCE_CATEGORIES` enumerate the supported fields
and types. Any other metadata key difference remains `unclassified_metadata`;
source changes for other types remain `unclassified_source` even if another
facet has a known category. Added null keys remain differences. These categories
do not establish runtime effects, safety or risk. Diff statistics are whole-source
sizes, not inserted/deleted lines or hunks.

JSON object keys are sorted, arrays have deterministic order, and report values
are detached and recursively frozen. Identical selectors and payload inputs
produce identical bytes. Equivalent selectors can preserve different original
selector values in provenance.

## Remaining W-12 work and dependencies

Not implemented: focus/pre-change reports, typed propagation through `reverse_via`,
depth/type/via filters, PageRank weighting, evidence paths, flows/routes, tables,
templates, suggested tests, risk detection, commit ranges, hunks, Markdown and
Mermaid renderers, rake task, MCP registration, saved reports, URLs or Map UI.
An empty reserved array means **not computed**, never “no impact” or “no risk”.

W-10 (#773) adds ordered `source`, `metadata`, `dependencies` facets to modified
snapshot diff entries with `identifier` and `unit_type`; added/deleted entries
keep their existing shape. Binding snapshot evidence to an exact payload remains
unavailable. W-11 (#774) pins payload generation N against retention, not snapshot
rows; this core uses existing reader locks and does not manage persistent pins.
W-13 (#775) publishes `flows/by_unit.json` as identifier → actual type → sorted
entrypoint strings. Membership describes expanded flow steps only; absence
cannot prove no flow reaches a unit. The core consumes none of those pending
branches and changes no extraction layout, schema, task, configuration or MCP surface.

Future propagation must use base evidence for removed units and head evidence
for current units, mark ambiguous/unavailable targets, and retain generation
provenance on paths. It must not splice generations or reuse Map's identifier-only
BlastRadius unchanged. Method-level scope and commit lists still depend on W-1,
W-6 and W-3. Testbed reproducibility and the umbrella's full/incremental matrix
acceptance remain unverified by these synthetic core contracts.
