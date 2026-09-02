---
name: woods-investigate
description: Use when auditing, code-reviewing, investigating, debugging, onboarding onto, or assessing change impact in a Rails application where a Woods MCP server is connected. Query the index before broad file reading or grep.
---

# Woods investigation

Woods is runtime evidence: resolved routes, schema, associations, callbacks, inlined concerns, dependencies, and execution flows extracted from the booted application. Use it to answer structural questions with less noise than file search, then verify important claims in source.

## Preflight

Call `woods_status` before relying on the index. Require a ready index with a current generation and non-zero counts for the types you need; use `codebase_retrieve` only when status reports retrieval enabled. If status is unhealthy or the generation predates the code under review, report that and ask the owner to run `woods:incremental` or `woods:extract` — do not present "not found" as proof the code does not exist.

## The default loop

1. **Discover** with `search` when the exact identifier is unknown (regex `query`, or safer `exact_prefix`/`exact_suffix` for namespaced names; restrict `types`).
2. **Inspect** the best match with `lookup`.
3. **Traverse** with `dependencies` (what it uses), `dependents` (what uses it), or `trace_flow`, starting at depth 1–2 with filters.
4. **Verify** important claims against the returned source paths and current repository files.

Identifiers are namespaced and typed; never invent one from a filename when `search` can return the exact value.

## By task shape

- **Code review / change impact**: `lookup` the changed unit, then `dependents` at depth 1 before going deeper. Group results by relationship type and layer; report direct dependents separately from inferred downstream impact. A graph edge is not test coverage — select tests from mappings and repository search.
- **Audit / architecture assessment**: `graph_analysis` for orphans, dead ends, hubs, cycles, and bridges; `domain_clusters` for architectural domains; `pagerank` for high-impact units worth reading first.
- **Investigating behavior / debugging**: `trace_flow` from the user-visible entry point (route, controller action, job, mailer, service), `lookup` at ambiguous steps, and verify anything conditional or dynamically dispatched in source and tests — do not infer call order from a dependency edge.
- **Onboarding**: `structure` for a unit's neighborhood, `domain_clusters` for the map, then the default loop on the units that matter.
- **Conceptual questions**: `codebase_retrieve` when status says ready; govern with `budget` (never `limit`), then verify key units with `lookup`.

## Boundaries

The normal packaged Index Server registers 14 tools; conditional schemas register only when their wiring is configured — use the connected server's own tool list, never the source inventory. Console MCP is authorized live-data access, not another code-search mode; use Index tools for structure. Never work around a block, validation error, or redaction.

## Report evidence

Name the tools and exact identifiers used, cite the source paths Woods returned, separate direct Woods evidence from inference, and state generation/staleness caveats. Say when a claim still needs source or test verification.

Canonical guides: [AGENT_GUIDE.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_GUIDE.md), [MCP_TOOL_COOKBOOK.md](https://github.com/lost-in-the/woods/blob/main/docs/MCP_TOOL_COOKBOOK.md).
