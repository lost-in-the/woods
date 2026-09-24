---
name: woods-investigate
description: Answer codebase questions from the Woods index — search, lookup, dependency and dependents traversal, flow tracing, and graph analysis, with verification rules. Use when auditing, code-reviewing, investigating, debugging, onboarding onto, or assessing change impact in a Rails application where a Woods MCP server is connected; query the index before broad file reading or grep.
---

# Woods investigation

Woods is runtime evidence: resolved routes, schema, associations, callbacks, inlined concerns, dependencies, and execution flows extracted from the booted application. Use it to answer structural questions with less noise than file search, then verify important claims in source.

## Preflight

Supporting servers include concise MCP initialization/discovery guidance without
this plugin. That feature (#402) is available in Woods `2.0.0.beta3`; check the
installed server version, and do not require it from protocol `2024-11-05`.
Follow the [agent guide](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_GUIDE.md)
when instructions are absent. A registered tool does not establish retrieval
readiness or authorize maintenance or live Console access.

Call `woods_status` before relying on the index. Require a ready index with a current generation and non-zero counts for the types you need; verify the retrieval mode and its data before using `codebase_retrieve` (see Conceptual questions below). If status is unhealthy or the generation predates the code under review, report that and ask the owner to run `woods:incremental` or `woods:extract` — do not present "not found" as proof the code does not exist.

## The default loop

1. **Discover** with `search` when the exact identifier is unknown (regex `query`, or safer `exact_prefix`/`exact_suffix` for namespaced names; restrict `types`).
2. **Inspect** the best match with `lookup`.
3. **Traverse** with `dependencies` (what it uses), `dependents` (what uses it), or `trace_flow`, starting at depth 1–2 with filters.
4. **Verify** important claims against the returned source paths and current repository files.

Identifiers are namespaced and typed; never invent one from a filename when `search` can return the exact value.

## By task shape

- **Code review / change impact**: `lookup` the changed unit, then `dependents` at depth 1 before going deeper. Group results by relationship type and layer; report direct dependents separately from inferred downstream impact. A graph edge is not test coverage — select tests from mappings and repository search.
- **Audit / architecture assessment**: `graph_analysis` for orphans, dead ends, hubs, cycles, bridges, cross-database edges, volatile dependencies, and undeclared package edges; `domain_clusters` for architectural domains; `pagerank` for high-impact units worth reading first.
- **Investigating behavior / debugging**: find the exact indexed unit with `search` and `lookup`, then use `trace_flow` with `UnitIdentifier` or `UnitIdentifier#method` (for example, `CheckoutService#order`). Bare `order` names a unit, potentially a factory, rather than locating an application method. Receiverless local calls may remain unexpanded; inspect their source or trace the owning unit's method explicitly. Flow output is not proof of runtime execution or exhaustive call coverage. See the [flow workflow](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_GUIDE.md#trace-a-feature-flow).
- **Onboarding**: `structure` for the codebase overview, `lookup` and `dependencies`/`dependents` for a unit's neighborhood, and `domain_clusters` for the domain map, then the default loop on the units that matter.
- **Conceptual questions**: check retrieval mode and data before `codebase_retrieve`; structural `ready` alone does not establish semantic availability. On readers supporting #549, inspect `retriever.corpus`; missing or unknown counts require checking embedding artifacts. Govern with `budget` (never `limit`), then verify key units with `lookup`.

## Boundaries

The normal packaged Index Server registers 14 tools; conditional schemas register only when their wiring is configured — use the connected server's own tool list, never the source inventory. Console MCP is authorized live-data access, not another code-search mode; use Index tools for structure. Never work around a block, validation error, or redaction.

## Partial search answers

Search completeness (#410) is available in Woods `2.0.0.beta3`. Verify the installed
server version and response before relying on it; this plugin does not upgrade
the gem. On supporting versions, `result_count` counts returned rows, while
`completeness.reason: exhausted` establishes an exact total for the requested
index/query domain. `result_limit` proves at least one additional match;
`scan_budget` and `regex_timeout` leave more matches and totals unknown. Narrow
types, literal prefix/suffix filters, or deep fields when `partial` is true.
Artifact errors have unknown completeness. Missing metadata on older servers,
a full page, and an empty partial result never establish exhaustive absence.
See the [search contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#search-completeness).

## Graph coverage

Dependency tools report published relationships, not exhaustive source-reference
or call coverage. Selective method-body scanning can miss references to generic
PORO and library targets. No dependents or test-only dependents do not establish
absence of production callers; check source before making that claim.

The [post-2.0 reference expansion](https://github.com/lost-in-the/woods/blob/main/docs/EXTRACTOR_REFERENCE.md#constant-source-references)
is unreleased and planned for 2.1. Verify the loaded writer revision and full
baseline before expecting its additional edges. `code_reference` is source
evidence, not observed execution; the coverage warning remains applicable.

The same planned expansion discovers callable standalone `app/models` modules
as `poro` units with `metadata.ruby_kind: "module"`. Runtime model mixins retain
`concern` ownership. Verify the installed writer and run a full extraction before
expecting those units; namespace-only wrappers and uncertain source ownership
remain outside discovery.

The response `graph_coverage` notice, `total_is_exact` field, and human label
`witness types unambiguous` (#470/#471) are included in Woods `2.0.0`.
Verify the installed server version and actual response fields; this plugin does
not add them. Apply these limits to older servers even without the notice.
Supporting stdio and HTTP servers expose the paginated traversal payload in
`structuredContent.data` independently of the text renderer (#481, also
included in Woods `2.0.0`). Check the installed response; older default
responses may carry only text. Do not pass an unsupported `format` argument.

`total_is_exact: false` means a budget-limited prefix; a true value describes only
the requested root, depth, filters and published generation. Pagination alone
does not change exactness. On older responses inspect `partial` directly.
Treat partial `nodes_total` as a root-inclusive lower bound, including on the
last page, an empty page or an unpaged answer. See the
[coverage contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#dependency-graph-coverage).

## Partial dependency answers

Traversal budgets (`max_nodes`/`max_edges`, #311) are available in Woods `2.0.0.beta3`.
Check the installed gem version and connected tool schema before
using them; installing this plugin does not upgrade the gem. On a supporting
server, `partial`/`partial_reason` means the walk stopped early, independently
of page truncation. Do not claim an exhaustive blast radius or treat empty
deps as proof of a leaf. Narrow depth/types/via or increase a supported budget;
paging alone only visits the discovered prefix. See the
[budget contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#dependency-traversal-budgets).

## Explain recorded relationships

`explain: true` on `dependencies`/`dependents` (#414) is available in Woods `2.0.0.beta3`.
Verify the installed gem and connected tool schema before using it;
installing this plugin does not add server capabilities. Supporting servers
preserve original source-to-target direction and labels in both traversal
modes. Follow shared `parent`/`edge_id` witnesses, distinguish direct records
from transitive inferred impact, and treat `context: true` ancestors as page
context. Null attributes and candidate type ambiguities remain unknown;
`typed_path_complete: false` never establishes a uniquely typed path; true means
only that witness identities have unambiguous types, not complete source coverage.
Budget
cutoffs still apply. Verify important conclusions in source and tests, since
recorded reachability does not establish observed execution. See the
[explanation contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#traversal-explanations).

## Graph-analysis pages

Pass explicit `limit` and `offset` when paging `graph_analysis`. Enforcing the
advertised default of 20 rows per section and preserving total/offset on last
and empty pages (#519) are included in Woods `2.0.0`; check the installed
response rather than inferring support from the plugin version. On supporting
servers, read `<section>_total` and `<section>_offset` in JSON, or the human
pagination notice. An empty later page does not mean no findings. Totals count
the published report array, which may already be bounded during extraction.
See the [page contract](https://github.com/lost-in-the/woods/blob/main/docs/MCP_SERVERS.md#graph-analysis-pages).

## Volatile dependency reports

Read `stats.volatile_dependency_count` before judging the top-20 array: it
counts all qualifying edges. A frequently changed dependency can occupy most
rows. Use the installed version's ratio tuning guidance; the optional
`volatile_dependency_limit_per_target` setting (B-188) is available in Woods
`2.0.0.beta3`, so verify gem support before recommending it. Supporting versions
can cap each typed target before selecting the global top 20 and expose the
cap plus `volatile_dependency_reported_count` in stats. Re-extract after
configuration changes. Treat the report as candidates for source review, never
an automatic gate. See the
[configuration reference](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#pipeline-options).

## Report evidence

Name the tools and exact identifiers used, cite the source paths Woods returned, separate direct Woods evidence from inference, and state generation/staleness caveats. Say when a claim still needs source or test verification.

Canonical guides: [AGENT_GUIDE.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_GUIDE.md), [MCP_TOOL_COOKBOOK.md](https://github.com/lost-in-the/woods/blob/main/docs/MCP_TOOL_COOKBOOK.md).

## Lexical retrieval capability check

This is a development capability. Before proposing it, verify the installed gem
exposes `Woods::Configuration#retrieval_mode` and its matching guide documents
`WOODS_RETRIEVAL_MODE`. Keep the installed-version preflight; do not infer support
from the plugin version or an unreleased checkout.

When status reports lexical mode, use the matching fields/terms as discovery
evidence and verify key units with `lookup`. At most 20 eligible matching
candidates are considered; fewer source entries may fit the budget. This is not
exhaustive, and no lexical match does not establish absence. When the installed
server reports considered/included counts, compare them; older versions may
only describe the shortlist limit. Continue using `budget`, not `limit`.
See the [retrieval guide](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval)
for the supported contract, checked against the installed gem version.

## Explicit package or path scope

Check the connected tool's advertised input schema before sending `packages` or
`source_paths`; older installed gems may not support them. When present, both
`search` and `codebase_retrieve` apply explicit scope before candidate limits.
Use published nearest package names or application-relative directory prefixes,
then inspect `applied_scope` and search completeness. Unknown packages are argument
errors; unsupported custom vector adapters degrade instead of running a global
query. Scoping can hide relevant cross-boundary relationships, so broaden the
request deliberately when the task needs them. See the
[scope contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#explicit-package-and-source-path-scopes).

## Compact evidence capability check

Inspect the connected server's installed tool schemas before using `evidence` on
`lookup` or `codebase_retrieve`; older releases do not provide these controls.
When available, explicit `compact` selects complete published source spans and
`outline` lists declared APIs. Read omission/provenance fields and follow the
returned typed, SHA-guarded `full_evidence` lookup for verification. Published-unit
coordinates are not physical file offsets; unknown generation remains unknown.
Keep full-source access available. See the canonical
[evidence contract](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines).

## Optional context hints

Check installed `bundle exec woods-hook-context --help` before enabling
`WOODS_HOOK_CONTEXT_ENABLED=1`; this capability is available in Woods `2.0.0.beta3` and the
plugin does not upgrade the gem. Context and refresh opt-ins are independent;
`WOODS_HOOKS_DISABLED=1` disables both. Native Claude context is synchronous and
bounded, with served-generation and pre-refresh/unknown labels. Verify candidate
dependents and suggested tests manually; silence is not no impact. Do not clear
refresh queues when optional hints time out. See the canonical
[context guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#optional-bounded-context-hints)
for output/time limits, container root mapping and emitted-hint suppression.
