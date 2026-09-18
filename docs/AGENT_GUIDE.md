# Woods agent guide

This guide is for coding agents using an already connected Woods MCP server. Woods is evidence from the running Rails application and its extracted graph; it complements file search, tests, git history, and direct source inspection.

Supporting servers also send a concise version of this workflow in MCP
initialization/discovery instructions, without requiring an installed plugin.
Check the connected server's version and registered tools; this feature is
unreleased after `2.0.0.beta2`, and protocol `2024-11-05` omits the field.
The [initialization contract](MCP_SERVERS.md#initialization-guidance) describes
availability. This guide remains the detailed reference when instructions are
absent or the client does not display them.

## Start every session with status

Call `woods_status` before relying on the index. Check:

- the index is ready and has a current generation;
- unit counts are non-zero for relevant types;
- retrieval is enabled before choosing `codebase_retrieve`;
- warnings do not indicate a stale or partial index.

If status is unhealthy, report the evidence and ask the owner to extract or refresh. Do not fill gaps by asserting that Woods found nothing.

Compare `index.woods_version` (last manifest publisher, unknown for older indexes)
with `server.version` (the MCP reader). A major-version difference warrants a
full extraction and upgrade review; a match does not prove every retained unit
was rewritten. See [manifest writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance).

## The default query loop

Use this four-step loop for most codebase questions:

1. **Discover** with `search` when you do not know the exact identifier.
2. **Inspect** the best match with `lookup`.
3. **Traverse** from that identifier with `dependencies`, `dependents`, or `trace_flow`.
4. **Verify** important claims against the returned source paths and current repository files.

Identifiers are namespaced and typed. Never invent one from a filename when `search` can return the exact value.

## Pick the smallest useful tool

| Need | Start with | Continue with |
|---|---|---|
| Find a class, route, callback, or phrase | `search` | `lookup` |
| Understand one exact unit | `lookup` | `dependencies` or `dependents` |
| Find what a change may break | `dependents` | `trace_flow`, then tests/source |
| Understand what a unit calls or includes | `dependencies` | `lookup` on important nodes |
| Follow request-to-model-to-view/job behavior | `trace_flow` | `lookup` at ambiguous steps |
| Understand a unit's neighborhood | `structure` | targeted traversal |
| Inspect Rails or gem behavior | `framework` | current source files |
| Find recently changed indexed units | `recent_changes` | git diff/history |
| Discover architectural domains | `domain_clusters` | `graph_analysis` |
| Check a join or foreign key across databases before writing it | `graph_analysis` with `analysis: "cross_database_edges"` | `lookup` on both models |
| Find dependencies that change faster than their dependents | `graph_analysis` with `analysis: "volatile_dependencies"` | `recent_changes` |
| See a Packwerk boundary before calling across it | `graph_analysis` with `analysis: "undeclared_package_edges"` | `lookup` on the package unit |
| Find central or high-impact units | `pagerank` | `dependents` |
| Ask a conceptual question | `codebase_retrieve` if status says ready | `lookup` and graph tools |
| Refresh after a published extraction | `reload` | `woods_status` |

Do not start with a broad graph or semantic query when an exact search will answer the question with less noise.

## Core workflows

### Understand a model

1. `search(query: "^Order$", types: ["model"])`
2. `lookup(identifier: <returned identifier>)`
3. Read resolved schema, associations, validations, scopes, enums, callbacks, and included concerns.
4. `dependencies(identifier: ..., depth: 1)` for collaborators.
5. `dependents(identifier: ..., depth: 1)` for callers and affected features.

Woods may inline concern behavior beside the owning model. Distinguish the resolved runtime view from the physical file that originally defined a method.

### Trace a feature flow

1. Search for the route, controller action, job, mailer, or service at the user-visible entry point.
2. Call `trace_flow` on the exact identifier.
3. Inspect important or ambiguous nodes with `lookup`.
4. Follow missing branches with `dependencies` and a narrow `via` filter when useful.
5. Verify behavior that depends on conditions, dynamic dispatch, or runtime data in source and tests.

### Assess change impact

1. Search and look up the unit being changed.
2. Call `dependents` at depth 1 before increasing depth.
3. Group results by relationship type and application layer.
4. Trace the most relevant user-facing or asynchronous flows.
5. Use test mappings and repository search to select tests; do not equate a graph edge with test coverage.

Report direct dependents separately from inferred downstream impact.

### Diagnose missing context

If an expected unit is absent:

1. Check `woods_status` and generation time.
2. Search by a broader literal prefix or suffix.
3. Search relevant source or metadata fields.
4. Confirm the extractor supports that unit type in [Extractor reference](EXTRACTOR_REFERENCE.md).
5. Ask for `woods:incremental` or a full `woods:extract` when the index predates the code.

“Not found in this generation” is evidence about the index, not proof that the code does not exist.

## Search precisely

`search` accepts a Ruby regular expression in `query`. It also supports literal `exact_prefix` and `exact_suffix`, which are safer for namespaced identifiers.

Good patterns:

```text
query: "Order|Purchase", types: ["model", "service"]
exact_prefix: "Admin::Billing::"
exact_suffix: "Controller"
fields: ["identifier", "source_code", "metadata"]
```

Start with identifier search. Add source or metadata only when name discovery fails. Restrict types and keep result limits small enough to inspect.

On supporting versions, read `completeness` before calling search exhaustive.
`result_count` counts returned rows. `result_limit` proves one more match exists;
`scan_budget` and `regex_timeout` leave that unknown. Only `exhausted` establishes
an exact total within the requested index/query domain. Narrow types, literal
prefix/suffix filters, or deep fields when `partial` is true. A detected artifact
failure remains an error with unknown completeness, never proof of no matches.

This metadata is unreleased after `2.0.0.beta2`; older servers may omit it.
Do not infer completeness from a full page or missing metadata. See the
[search response contract](MCP_SERVERS.md#search-completeness).

## Traverse deliberately

`dependencies` means “what this unit uses.” `dependents` means “what uses this unit.” Both default to bounded breadth-first traversal and accept type or relationship filters.

Start at depth 1 or 2. A deeper unfiltered traversal can obscure the direct evidence that matters. Common relationship values include associations (`belongs_to`, `has_many`, `has_one`), code references, renders, redirects, form actions, and navigation links.

Both return at most 50 nodes by default and say so with a `Showing N of M (truncated)`
line. Narrow with `depth`, `types` and `via` before paging with `limit` and
`offset`: narrowing answers the question, paging only splits the same answer
across turns. In a multi-database app each row names the unit's database.

A traversal can also stop at its independent node or edge budget. Treat
`partial`/`partial_reason` as incomplete graph evidence even on the final page;
paging cannot recover nodes the walk never reached. Check the connected schema
before using `max_nodes`/`max_edges`, and follow the
[budget contract](MCP_SERVERS.md#dependency-traversal-budgets).

When the connected schema supports `explain`, request `explain: true` to see
recorded source-to-target relationships and a shared shortest witness to each
row. Report `direct` relationships separately from `transitive` inferred impact.
Follow `parent`/`edge_id` references; `context: true` ancestors are outside the
current result page. Unknown labels and ambiguous candidate types stay unknown;
`typed_path_complete: false` does not establish a uniquely typed path. See the
[explanation contract](MCP_SERVERS.md#traversal-explanations).

Use recorded relationship labels as evidence. Do not infer execution or call
order from a dependency edge alone.

## Use ranked retrieval only when ready

`codebase_retrieve` answers natural-language questions with token-budgeted context. Use it when `woods_status` reports explicit lexical mode over a current published index, or a configured embedding provider and current vector data in semantic mode. Lexical mode explains matching terms/fields and does not infer synonyms absent from the text; a no-match response is not proof of missing behavior.

Important parameters:

- `query`: the conceptual question;
- `budget`: token budget, default 8,000;
- `types`: restrict results and opt specific types in;
- `exclude_types`: remove noisy types.

Do not pass `limit`; retrieval is governed by `budget`. Test mappings are excluded by default so filenames do not dominate semantic rank. After retrieval, verify key units with `lookup` rather than treating ranked context as exhaustive.

If retrieval is disabled, use `search`, `lookup`, and graph tools. Do not request credentials or reconfigure the project without authorization.

## Index Server boundaries

The normal packaged server registers 14 tools:

`woods_status`, `search`, `lookup`, `dependencies`, `dependents`, `structure`, `trace_flow`, `framework`, `recent_changes`, `graph_analysis`, `domain_clusters`, `pagerank`, `reload`, and `codebase_retrieve`.

Source inventory contains conditional tools for sessions, pipeline operation, feedback, snapshots, and Notion. Do not call or promise them unless they appear in the connected server's tool list and their backing collaborator is configured.

## Console Server boundaries

Console MCP is live-data access, not another code-search mode. Use it only when the user has authorized that environment and question.

The default executable registers:

- health/schema: `console_status`, `console_schema`;
- bounded records: `console_find`, `console_recent`, `console_sample`;
- projections/counts: `console_pluck`, `console_count`, `console_aggregate`, `console_association_count`.

`console_sql` and `console_query` appear only when embedded read tools are explicitly enabled. Tier 2 and Tier 3 inventory schemas and `console_eval` are not callable in supported packaged modes.

Before every Console call:

1. confirm the authorized environment;
2. use the narrowest model, fields, filters, and limit;
3. avoid retrieving sensitive columns when aggregates or counts answer the question;
4. treat redaction and scanners as defense in depth, not permission;
5. do not work around a block or validation error.

See [Console MCP setup](CONSOLE_MCP_SETUP.md) for the safety model.

## Report evidence clearly

When answering from Woods:

- name the tools and exact identifiers used;
- distinguish direct Woods evidence from your inference;
- cite source paths returned by Woods when available;
- state the index generation or staleness caveat when relevant;
- say when a conditional path still needs source or test verification;
- never claim the index is complete merely because a tool returned successfully.

A useful answer shape is:

```text
Finding: <plain-language result>
Woods evidence: <tool + identifier + relationship/source>
Inference: <what follows from that evidence>
Verification: <source/test/history checked or still needed>
```

## Common mistakes

| Mistake | Better approach |
|---|---|
| Guessing an identifier | Discover it with `search` |
| Starting with semantic retrieval for an exact class | Use `search` then `lookup` |
| Treating no result as proof of absence | Check status, generation, extractor coverage, and source |
| Traversing deeply from the start | Begin at depth 1 or 2 and filter |
| Calling inventory-only tools | Use the connected server's registered list |
| Using Console for code structure | Use Index tools |
| Asking for `limit` on retrieval | Use `budget` |
| Trusting graph edges as execution order | Verify conditions and order in source/tests |
| Changing MCP or credentials while answering | Report the missing capability and ask the owner |

## Related documentation

- [MCP servers](MCP_SERVERS.md): installation, client configuration, and exact surfaces.
- [MCP tool cookbook](MCP_TOOL_COOKBOOK.md): detailed parameters and response examples.
- [Extractor reference](EXTRACTOR_REFERENCE.md): indexed unit and edge contracts.
- [Retrieval guide](RETRIEVAL_GUIDE.md): embeddings, ranking, and token budgets.
- [Troubleshooting](TROUBLESHOOTING.md): stale indexes, disabled retrieval, and startup failures.

### Explicit retrieval and discovery scope

On a server whose tool schema advertises them, `packages` and `source_paths` narrow
`search` and `codebase_retrieve` before candidate limits. These are per-call
arguments, not configuration settings. Inspect applied scope and completeness;
a narrow graph query can omit relevant cross-boundary dependencies. See the
[scope contract](RETRIEVAL_GUIDE.md#explicit-package-and-source-path-scopes) for
root/nested ownership, path normalization, errors, storage support, and cost.

### Verify source content before relying on freshness

When supported by the installed version, inspect `woods_status.index.source_freshness`.
Repeated edits can leave the porcelain fingerprint unchanged. A quick-budget
`unknown` can justify one explicit `source_check: "deep"` call; persistent unknown
needs the reported limitation resolved, not repeated status polling. Use
`bundle exec woods-extract full` to establish verified preboot source evidence.
A named refresh does not certify unrelated consumers or external runtime state.
Follow [source freshness](SOURCE_FRESHNESS.md) and keep ordinary query scopes narrow.

### Recovering relevant code under a small context budget

Check the installed schemas before requesting `evidence: 'compact'` on retrieval
or lookup, or `evidence: 'outline'` for API orientation. These modes preserve
complete selected spans and explicitly report omissions. An outline is not proof
of implementation behavior. Follow the returned typed `full_evidence` call when
you need full source; its SHA guard refuses changed source instead of validating
a different publication accidentally. Published-unit line/byte ranges can include
synthesized or commented concern source and are not physical file coordinates.
See the [evidence contract](RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines).

### Optional hook hints

When explicitly enabled on a supporting installed gem, Claude hook context offers
a small served-generation orientation and post-edit candidate dependents. Treat
pre-refresh, unknown freshness, truncation and ambiguous identity labels as limits
on the evidence. Verify direct and inferred downstream candidates using typed
lookup and `dependents explain:true`; suggested tests do not prove coverage.
Silence does not establish no impact. See [bounded context hints](WATCH_DAEMON.md#optional-bounded-context-hints)
for opt-in, independent refresh controls, limits and repeat suppression.
