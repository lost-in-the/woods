# Impact range core, JSON version 1

Development contract for the core and propagation slices of [W-12 / #762](https://github.com/lost-in-the/woods/issues/762),
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
| focus mode | `range:null`, top-level `endpoint` provenance and exact typed `focus` roots; `changed:[]` |
| endpoint | Original `selector`, integer `generation`, nullable manifest `git_sha`, `manifest_checksum` (SHA-256 of its manifest) |
| `parameters` | `mode:"range"`, depth, types, via and explicit finite budgets; unsupported inputs raise |
| `changed` | Array sorted by identifier then actual type |
| change | `identifier`, `type`, `status` (`added`, `modified`, `removed`), `facets`, `categories`, `metadata_keys`, `diff_stats` |
| `diff_stats` | `source_before`, `source_after`: null when absent/unavailable, otherwise `bytes` and `lines` of each complete source |
| `affected`, `flows`, `risks` | Bounded endpoint-specific evidence, described below |
| `tables`, `templates`, `tests`, `commits` | Reserved empty arrays; corresponding coverage is `not_computed` |
| `coverage` | `complete:false`, `diff:"retained_payloads"`, `snapshot_facets:"unbound"`; affected/flows `bounded` or `partial`, risks `partial`; focus mode has `focus:"typed_units"`, while deferred analyses remain `not_computed` |
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

## Typed propagation and retained flow evidence

`compare` accepts `depth` (default 2, 0..10), `types` and `via` arrays (default
null: unrestricted). Type and via filters restrict traversal at every hop,
not just displayed results. Type strings are actual published types. No hidden
singularization, query-time PageRank calculation or new graph analysis occurs.

Removed roots traverse base evidence. Modified/added roots traverse head evidence.
Every affected record and path carries `endpoint` (`from`/`to`) and `generation`.
The same typed unit can appear in both endpoints with different evidence.
Each record includes `identifier`, `type`, minimum `distance`, nullable `weight`,
and `paths`. Paths contain the typed changed `root` and typed relationship `edges`
with their published `via`, `through`, `through_db` and `disable_joins` attributes.
Edges retain dependency direction (dependent source → target); the path array
orders witnesses outward from the changed root.

Traversal consumes published `reverse_via` in its published deterministic order.
It retains exact typed source ownership and requires a matching target type hint
or a unique actual target type. Conflicting hints, ambiguous targets, and missing
source identities remain unknown. One shortest witness is retained per root and
affected typed identity; these are bounded witnesses, not exhaustive paths.
Cycles terminate. PageRank comes only from the published identifier-valued map;
typed collisions or missing scores get null weights and explicit unknowns.

Per endpoint, all roots share `max_nodes` (default 1000, cap 10000) and `max_edges`
(default 10000, cap 100000); witness visits include roots. Edge examination is
charged before record interpretation. Hitting a budget retains observed evidence
and records `node_budget`/`edge_budget`. Depth bounds the requested radius;
coverage remains bounded and never implies whole-application completeness.

W13's exact typed inverse selects entrypoints. Each flow index path must stay
inside the locked payload without symlink components or traversal. Each document
must name the expected entrypoint and contain every claimed normalized typed step.
Flow records carry endpoint/generation, `entry_point`, nullable published `route`,
and typed `changed_steps`. No historical flow is assembled from current source.
Absent/corrupt legacy artifacts produce explicit unknowns, never no-impact claims.

Flow work shares endpoint budgets: `max_flow_documents` (default 100, cap 1000),
`max_flow_steps` (default 10000, cap 100000; includes inverse memberships), and
`max_flow_operations` (default 10000, cap 100000). Calls and async operations,
including nested branches, preserve unknown expansion status and ambiguous
candidates; unit membership cannot establish method-call expansion. Cycles and
missing operation facts are explicit unknowns. Observed unknowns survive budget
exhaustion. Dynamic-dispatch operations retain `unresolved_dynamic_dispatch`
unknowns with captured target/method/ambiguity/argument hints and line evidence;
operation-level cycles remain `flow_operation_cycle`, distinct from `flow_cycle`
step markers. Nested operations use the same walk and shared work budget.
Each optional artifact is limited to 16 MiB, recorded as
`artifact_max_bytes`, with invalid UTF-8 and nonregular files refused.

## Focus and risk evidence

`Report.focus(index_dir, identities: [{"identifier" => "Example", "type" => "model"}],
at: "now", **parameters)` plans a change against one captured retained endpoint.
Identities must be exact, nonempty string-keyed identifier/type pairs (1..10000);
they are deduplicated and sorted. Missing, untyped or method selectors that do not
exist as actual typed units fail explicitly. Method names are never widened to
their owning classes. `parameters.mode` is `focus`, `range` is null, `endpoint`
holds provenance, and `focus` holds the roots. Current evidence uses side `to`.
`coverage.focus` is `typed_units`; this is not method-level acceptance of E-9.

Risk objects carry `kind`, typed `unit`, `endpoint`, `generation`, and `evidence`.
The adapter consumes the selected endpoint's `graph_analysis.json`; it never
recomputes structural analysis. Published hub/bridge flags require positive
published metrics; cycles require unambiguous typed identities throughout, and
cross-database facts require both endpoints to bind uniquely to inventory units
and distinct published database names. Collisions and truncated cycle lists stay
unknown. These remain the producer's bounded heuristic classifications.

Captured metadata can flag changes in recorded filter arrays, callback side
effects, and removed records between two complete foreign-key arrays. Missing
arrays are unavailable evidence, not empty arrays. Focus mode has no before/after
comparison and does not manufacture change flags. Jobs are flagged as
`job_without_retry_touched` only for a recorded Sidekiq job with explicit literal
retry disablement and no captured enabled retry policy. Missing/inherited or
dynamic policy stays unknown; the report does not prove global absence of retries.

All inspected units/structural records and relevant metadata array entries share
`max_risk_records` per endpoint (default 10000, cap 100000). Budget exhaustion
retains earlier evidence and records `risk_record_budget`. Risk coverage is always
partial. New instance-variable mismatch detection remains explicitly not computed;
absence of flags never proves safety. Evidence locators reference published
artifact families or metadata keys, not live files, generated URLs or runtime facts.

## Remaining W-12 work and dependencies

Not implemented: method-scoped pre-change reports, new instance-variable mismatch
detection, tables, templates, suggested tests, commit ranges, hunks, Markdown and
Mermaid renderers, rake task, MCP registration, saved reports, URLs or Map UI.
An empty reserved array means **not computed**, never “no impact” or “no risk”.

W-10 (#773) adds ordered `source`, `metadata`, `dependencies` facets to modified
snapshot diff entries with `identifier` and `unit_type`; added/deleted entries
keep their existing shape. Binding snapshot evidence to an exact payload remains
unavailable. W-11 (#774) pins payload generation N against retention, not snapshot
rows; this core uses existing reader locks and does not manage persistent pins.
W-13 (#775) publishes `flows/by_unit.json` as identifier → actual type → sorted
entrypoint strings. Membership describes expanded flow steps only; absence
cannot prove no flow reaches a unit. W-10, W-11 and W-13 are merged foundations.
This slice changes no extraction layout, task, configuration or MCP surface. It reads
W13's merged index format without changing its producer.

Propagation uses base evidence for removed units and head evidence for current
units and does not splice generations or reuse Map's identifier-only BlastRadius.
Method-level scope and commit lists still depend on W-1,
W-6 and W-3. Testbed reproducibility and the umbrella's full/incremental matrix
acceptance remain unverified by these synthetic core contracts.
