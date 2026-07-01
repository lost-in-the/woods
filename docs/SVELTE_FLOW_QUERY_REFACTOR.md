# Query-Driven Svelte Flow Visualization

**Status:** Phases 0–4 implemented and shipped on `claude/svelte-flow-refactor-n2df35`. The one remaining item — exact line-span highlighting — is deferred pending a product decision (see Phasing).
**Scope:** `lib/woods/svelte_flow/` (Rack middleware, exporter, transformer) + `frontend/` (Svelte app) + one manifest/config addition.
**Pairs with:** existing MCP index-server query tools (`dependencies`, `dependents`, `trace_flow`, `search`, `codebase_retrieve`). Additive — the current full-graph export/serve paths stay working.

---

## TL;DR

Today the Svelte Flow layer answers "show me the whole graph, centered somewhere." We want it to answer "**an agent asked woods a question — render *that* answer as an explorable map.**" A user asks their agent about a feature, a blast radius, or an investigation; the agent queries woods (it already has the MCP tools), gets a set of identifiers, and the visualization renders *just those units and their connections* for exploration — click a node to read its source, follow a link to the file locally or on GitHub, and share or auto-open the result by URL.

The good news: the branch is **~70% of the way there already**. Progressive neighbor loading (`/api/graph/neighbors`), URL-driven centering (`?center=`), and a node detail sidebar all exist. This refactor adds four things:

1. A **scope-by-identifier-set** API + URL param (generalizes the single-center neighbor endpoint).
2. A **source pane** in the sidebar, with local-editor and GitHub deep links.
3. A **self-contained HTML export** for the no-server / agent-driven case.
4. An **upstream `@xyflow/svelte` bump** (`^1.0` → `^1.6`) plus `:via`-aware edge styling and query-path highlighting.

Recommendation: green-light in phases. Phase 1 (scope endpoint + URL param) delivers the core value and reuses existing plumbing. Everything else layers on without reworking it. Before extending, fix the 3 pre-existing failing edge-builder specs so the feature has a green baseline.

---

## Why This Exists

### The current model: full-graph-first

`Woods::SvelteFlow::Exporter` writes the entire dependency graph, all domain clusters, and every precomputed flow to disk. `RackMiddleware` serves the whole thing and the frontend loads `GET /api/graph` (the full graph) on boot, then auto-centers on the highest-PageRank node. For a real Rails app (hundreds to thousands of units) this is a wall of nodes the user has to prune down manually. The doc itself admits it: *"For very large codebases (1000+ units), consider filtering by type before visualization."*

That's backwards for the workflow we actually want. The agent already knows the answer — it ran `dependents PaymentService` or `trace_flow CheckoutController#create`. The visualization should start *from that answer*, not from everything.

### What already exists (do not rebuild)

| Capability | Where | Status |
|---|---|---|
| Neighborhood subgraph by center + depth | `rack_middleware.rb` `serve_neighbors_json` (`/api/graph/neighbors?node=X&depth=N`) | Works; BFS over forward+reverse edges, scoped node/edge builders |
| URL-driven center | `App.svelte` `updateUrl` / `getCenterFromUrl` (`?center=X`) | Works |
| Node detail sidebar | `NodeDetail.svelte` | Works — shows type, filePath, namespace, pagerank, roles, columns. **No source.** |
| Expand/collapse per node, hide, recent history | `App.svelte`, `graph-state.js` | Works |
| Per-unit source on disk | Each `<type>/<Unit>.json` carries `source_code` (concerns inlined) + absolute `file_path` | Available, **not surfaced to the UI** |
| Manifest git provenance | `extractor.rb` writes `git_sha` / `git_branch` via `GitProvenance` | Available, **not used by viz** |
| Agent query surface | MCP index server: `dependencies`, `dependents`, `trace_flow`, `search`, `domain_clusters`, `codebase_retrieve` | Works — produces identifier sets |

The missing seam is the connection between "agent has a set of identifiers" and "render exactly that set." The neighbor endpoint proves the scoping machinery works; it just only accepts one center.

### Known baseline debt

Three specs fail on the branch **today** (pre-existing, not introduced by the main merge):

- `spec/svelte_flow/transformer_spec.rb:35` — edges between connected nodes
- `spec/svelte_flow/transformer_spec.rb:277` — non-model edge typing
- `spec/svelte_flow/exporter_spec.rb:121` — edge count

These are in the edge-building path this refactor extends. **Fix them first** (Phase 0) so new work builds on green.

---

## Goals / Non-Goals

**Goals**

- Render an arbitrary agent-supplied set of identifiers as a scoped, explorable subgraph.
- Show a unit's source in the sidebar on click; link out to the file locally and on GitHub.
- Make the result addressable by URL (server mode) *and* producible as a standalone file (offline / agent mode).
- Keep everything backend-agnostic (MySQL and PostgreSQL column normalization already handled in `NodeBuilder`).

**Non-Goals**

- Editing the graph. The canvas is intentionally read-only; upstream reconnect/click-connect features are out of scope.
- Replacing the full-graph export/serve paths. They remain for "explore everything" use.
- A new retrieval/query engine. The agent uses the *existing* MCP tools; we only render their output.
- Server-side syntax highlighting. Highlighting is a client concern.

---

## Design

### Workstream 1 — Scope by identifier set (Phase 1, core)

**New endpoint.** Generalize the single-center neighbor endpoint to accept a set:

```
GET /woods/visualize/api/subgraph?nodes=A,B,C&depth=0&via=belongs_to,render
```

| Param | Meaning | Default |
|---|---|---|
| `nodes` | Comma-separated identifiers (the agent's query result) | required |
| `depth` | Extra BFS hops to pull in around the set (0 = induced subgraph only) | `0` |
| `via` | Optional edge-type filter (reuses `dependencies_of(via:)` semantics) | all |

The handler reuses the existing pieces almost verbatim: seed `visited` with the `nodes` set instead of a single id, run the existing `collect_neighborhood` for `depth` hops, then `build_scoped_graph` → `NodeBuilder` + `EdgeBuilder`. `serve_neighbors_json` becomes a thin caller of the same core (`node=X&depth=N` ≡ `nodes=X&depth=N`). Unknown ids are dropped with a `dropped: [...]` field in the response so the agent/user can see what didn't resolve.

**URL param.** `App.svelte` learns `?nodes=A,B,C` (and optional `&depth=`, `&via=`). When present, it calls `/api/subgraph` instead of `fetchFullGraph`, and skips the highest-PageRank auto-center. `?center=` remains supported (single-node case). Encoding note: URLs have length limits — cap the inline set (≈50 ids) and, past that, fall back to a POSTed scope that the server stashes under a short id (`?scope=<id>`). Document the cap; never silently truncate.

**Agent workflow (no code, just the contract).** The agent runs e.g. `dependents PaymentService --depth 2`, collects identifiers, and constructs `…/woods/visualize?nodes=PaymentService,Invoice,Refund,…`. It prints the URL or opens it. This is why Phase 1 alone is useful — it closes the query→render loop.

### Workstream 2 — Source pane + deep links (Phase 2)

**Source endpoint (lazy).** Do **not** inline source into the graph payload — it would bloat every node. Add:

```
GET /woods/visualize/api/unit/:id/source
=> { "identifier": "...", "file_path": "app/models/user.rb", "source_code": "...", "git": { "sha": "...", "blob_url": "..." } }
```

The middleware already reads per-unit JSON in `load_unit_metadata`; this reuses that read path, keyed by identifier, returning the `source_code` field it currently discards.

**Sidebar.** `NodeDetail.svelte` gains a collapsible code pane that fetches source on demand when a node is selected. Syntax highlighting is client-side (a small Ruby highlighter, e.g. Shiki/Prism at build time — no new runtime gem).

**Deep links.**

| Target | Construction | Requires |
|---|---|---|
| Local editor | `vscode://file/<abs_path>:<line>` (and `cursor://`, `file://` fallback) | absolute `file_path` (have it) |
| GitHub | `<repo_url>/blob/<git_sha>/<rel_path>#L<line>` | new `svelte_flow_repo_url` config; `git_sha` from manifest (have it) |

`git_sha` is already in the manifest. Add one config accessor `svelte_flow_repo_url` (mirrors the existing `unblocked_repo_url` precedent) so the GitHub link is opt-in and host-specific. Relative path = strip the app root from `file_path` (`NodeBuilder#file_path_attribute` already does this trimming — factor it out for reuse). The agent can auto-open the local link via `open`/`xdg-open`.

**Highlight code tied to the query (⚠️ staged).** Exact line highlighting needs line spans that extraction does not currently emit — `source_code` is stored without line numbers, and `CallbackAnalyzer`/flow steps reference *method names and call patterns*, not ranges. Two-step plan:

1. **Now (approximation):** client-side highlight of the queried symbol/method substrings within the source pane. Cheap, no extraction change.
2. **Later (exact):** add optional line-span metadata to the relevant extractors (and flow steps) and highlight precise ranges. Larger, separable change — call it out as a follow-up, don't block Phase 2 on it.

### Workstream 3 — Self-contained export (Phase 3)

Precedent is strong: the Obsidian export (shipped on `main`) writes a fully self-contained vault, and `Exporter` already emits static JSON. Add a query-scoped, **single-file HTML** output:

```
bundle exec rake woods:map QUERY="dependents:PaymentService" DEPTH=2
# or an explicit id set:
bundle exec rake woods:map NODES="PaymentService,Invoice,Refund"
```

It computes the scoped subgraph (same core as Workstream 1), inlines the JSON + the built JS/CSS into one HTML file under `tmp/woods/svelte_flow/`, and prints the path. No server, no network — the agent opens `file://…`. This is the offline mirror of the `?nodes=` URL path; both call the same scoping core so they can't drift.

Design decision — **both** delivery modes, not one:

| Mode | Delivery | Best when | Caveat |
|---|---|---|---|
| Server + URL params | `?nodes=…` against running middleware | Rails app already up; live re-extract refresh | URL length cap; needs server |
| Self-contained HTML | `woods:map QUERY=…` → one file | CI, agents, sharing, no Rails process | Snapshot — not live |

### Workstream 4 — Upstream bump + visual polish (Phase 4)

**Upstream.** `frontend/package.json` pins `@xyflow/svelte ^1.0.0`; latest is **1.6.1**. Since 1.0: improved `fitView`, keyboard navigation + accessibility, click-connect, `EdgeReconnectAnchor`. The canvas is read-only, so reconnect/click-connect are irrelevant, but **`fitView` + a11y + TSDoc are low-risk wins**. Bump to `^1.6`, rebuild the shipped assets (`assets/build/`), smoke-test in a host app. No API-breaking changes expected within v1.

**Visual.**

- **`:via`-labeled edges.** The data already carries `:via` on every edge (`belongs_to`, `render`, `link_to`, `redirect_to`, `form_action`, `code_reference`). Surface it as edge labels + a color legend so users can tell an association from a navigation edge at a glance. `EdgeBuilder` currently flattens all of these to `relationship: dependency` — thread `:via` through instead.
- **Query-path highlighting.** When arriving via `?nodes=`, visually distinguish the queried set from depth-pulled neighbors (e.g. solid vs dimmed), so "what I asked for" vs "context" is obvious.
- **MiniMap** is already wired via `ColumnLayout.svelte` — keep.

---

## Data & API Summary

**New/changed HTTP endpoints** (server mode):

| Endpoint | Status | Returns |
|---|---|---|
| `GET /api/subgraph?nodes=&depth=&via=` | **new** | Induced subgraph over an id set (`nodes`, `edges`, `dropped`) |
| `GET /api/graph/neighbors?node=&depth=` | refactored to call subgraph core | unchanged shape |
| `GET /api/unit/:id/source` | **new** | `source_code`, `file_path`, git blob URL |
| `GET /api/graph`, `/api/clusters`, `/api/flows[/:id]` | unchanged | full-graph paths retained |

**New config** (`lib/woods.rb`):

| Option | Type | Default | Purpose |
|---|---|---|---|
| `svelte_flow_repo_url` | String | `nil` | Base repo URL for GitHub blob deep links (opt-in) |

**Frontend URL params:** `?nodes=`, `&depth=`, `&via=`, `?scope=<id>` (large sets); `?center=` retained.

No changes to `dependency_graph.json` / per-unit JSON shape — everything reads existing fields.

---

## Security & Safety Considerations

- **Source exposure.** `/api/unit/:id/source` serves file contents. It's mounted behind the same middleware as the rest of the viz; the viz is dev/internal-facing and not wired in production by default (the railtie gates it on `svelte_flow_enabled`). Keep source-serving read-only, path-validated by *identifier lookup* (never a raw path param), so it can't be turned into an arbitrary-file-read. Reuse the existing `safe_key` / basename discipline already in `serve_asset`.
- **No new attack surface for large sets.** The `?scope=<id>` fallback stores an ephemeral, server-generated id → id-set map; it holds identifiers only (no source), and ids are validated against the graph before use.
- **GitHub links are opt-in.** Absent `svelte_flow_repo_url`, no external URLs are constructed.

---

## Scope & Phasing

| Phase | Deliverable | Status | Notes |
|---|---|---|---|
| **0** | Fix failing edge-builder specs; green baseline | ✅ Done | Root cause was `{ target:, via: }` edges not handled by the viz consumers; added `EdgeData` normalizer + cleared all pre-existing rubocop debt in `svelte_flow/` |
| **1** | `/api/subgraph` + `?nodes=` URL param + agent workflow | ✅ Done | Shared scoping core; `requested`/`dropped` reporting; browser-validated |
| **2** | Source pane + local/GitHub deep links + `svelte_flow_repo_url` | ✅ Done | Lazy `/api/unit/:id/source`; connected-unit substring highlighting; blob URLs pinned to git SHA |
| **3** | `woods:map NODES=` self-contained HTML export | ✅ Done | `SubgraphScoper` + `SourceLinks` extracted for zero drift; `StandaloneRenderer` inlines graph + sources; validated over `file://` |
| **4** | `@xyflow/svelte ^1.6` bump, `:via` edge styling + legend, query emphasis | ✅ Done | Resolves 1.6.1; `edge-style.js` + `EdgeLegend`; depth-pulled neighbors dimmed |
| **later** | Exact line-span highlighting (extraction-side) | ⏸ Deferred | Needs extractor changes + a product decision (Open Question 4); substring approximation ships now |

All shipped phases were validated in headless Chromium (server mode and `file://`) and covered by specs. The line-span work is deliberately deferred — it's the only piece that needs extractor changes.

> **Note on where things landed.** The shared scoping core became `SubgraphScoper` (not a method on `Transformer`), and the deep-link building became `SourceLinks` — both are standalone modules reused by the middleware and the exporter so the live and offline paths can't drift. The `?scope=<id>` large-set fallback (Open Question 1) was deferred; the `?nodes=` list handles realistic result sets, and a cap can be added when a real app hits the URL limit. `EdgeBuilder` threads `:via` into edge `data` (it is not "flattened to `dependency`" as the earlier draft feared).

---

## Testing Plan

- **Phase 0:** the 3 named specs go green; full `rake spec` clean.
- **Scope core:** unit-test the id-set scoping (induced subgraph, `depth` expansion, `via` filter, unknown-id `dropped` reporting) against a fixture graph — mirror the existing `transformer_spec` fixtures.
- **Source endpoint:** spec that a known identifier returns its `source_code` and that a bogus/traversal id returns 404, not a file read.
- **Exporter (self-contained):** spec that `woods:map NODES=…` writes one HTML with the scoped JSON inlined and node/edge counts matching the server path (shared core ⇒ parity assertion).
- **Host-app smoke:** validate in `woods-testbed` `rails-8.0` — extract, hit `/woods/visualize?nodes=…`, click a node, confirm source + links render. Re-run on `rails-7.2` only if middleware wiring changes (it shouldn't).
- **Frontend:** manual smoke after the xyflow bump (canvas renders, fitView, minimap, `:via` legend).

---

## Open Questions

1. **Large scope transport.** Is the `?scope=<id>` server-stashed fallback worth it in Phase 1, or defer until a real app hits the URL cap? (Lean: defer; ship the cap + a clear message first.)
2. **Syntax highlighter.** Build-time Shiki (accurate, heavier assets) vs runtime Prism (lighter, good enough)? The gem ships prebuilt assets with no Node requirement for hosts, so favor whatever keeps the shipped bundle small.
3. **`woods:map QUERY=` grammar.** How much query DSL to support in the rake task (`dependents:X`, `flow:Ctrl#action`, `search:"..."`) vs. just accepting a raw `NODES=` set and leaving querying to the agent/MCP? (Lean: `NODES=` first; add DSL sugar only if asked.)
4. **Exact-highlight priority.** Is precise line highlighting (extraction change) wanted soon, or is the substring approximation sufficient for the foreseeable use? Affects whether the "later" row gets pulled forward.

---

## Appendix — Files in Play

```
lib/woods/svelte_flow/
  rack_middleware.rb   # + /api/subgraph, /api/unit/:id/source; refactor neighbors → shared core
  exporter.rb          # + self-contained HTML export path
  edge_builder.rb      # thread :via through; Phase 0 fixes
  transformer.rb       # Phase 0 fixes
lib/woods.rb           # + svelte_flow_repo_url config
lib/tasks/woods.rake   # + woods:map QUERY=/NODES= behavior
frontend/
  src/App.svelte                    # ?nodes=/&depth=/&via= handling
  src/lib/api.js                    # fetchSubgraph, fetchUnitSource
  src/components/NodeDetail.svelte  # source pane + deep links
  src/components/*Edge*/legend      # :via styling + legend
  package.json                      # @xyflow/svelte ^1.6
docs/
  SVELTE_FLOW_VISUALIZATION.md      # update once shipped
  SVELTE_FLOW_QUERY_REFACTOR.md     # this doc
```
