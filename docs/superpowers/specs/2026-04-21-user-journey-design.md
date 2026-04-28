# User Journey Visualization (Static Journey Inference)

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this spec.

## Context

Woods already extracts two datasets that, combined, describe possible user paths through the application:

1. **Routes** (`tmp/woods/routes/`) — 996 entries with HTTP verb, path, controller, and action.
2. **Navigation edges** (`tmp/woods/dependency_graph.json`) — 408 edges labeled `link_to` (129), `redirect_to` (271), and `form_action` (8). Each edge points from a source unit to a target controller via a resolved `_path`/`_url` helper.

The ERD currently renders this data as a static dependency graph. It does not answer the question *"starting at route X, where can a user end up?"* — you have to trace edges by hand. The goal of this phase is to make that question answerable in one click: pick a GET route, see the reachable subgraph, and optionally jump into adjacent flows.

Runtime session-trace data (Level 3 in the original assessment) is out of scope — no instrumentation, no request logs, no per-user data. Every edge in a journey is derivable from already-extracted static data.

## Scope

### In scope

- A slim **entry-point index** emitted by the backend into `schema.json` listing every GET route that resolves to an extracted controller.
- A new **Journey Mode** in the ERD frontend: a toggleable state where one entry point is selected and the reachable subgraph from that entry is highlighted on the existing React Flow canvas.
- **Entry-point selection** via two mechanisms: a ⌘K command palette (extended with an "Entry Points" section) and a right-click context menu item on any controller node ("Start journey from here").
- **Controller-level granularity** — one journey per controller, regardless of action.
- **Edge-type differentiation** — `link_to`, `redirect_to`, and `form_action` each render with a distinct edge style.
- **Cycle handling** — cycles detected, rendered as back-edges, never traversed twice.
- **Depth control** — default BFS walk to leaf or cycle, hard cap at 10 hops, user-adjustable via a dropdown in the journey banner.

### Out of scope (deferred)

- **Action-level granularity** (one journey per `Controller#action`). Tracked as an optional future improvement — requires per-action navigation edge attribution, which the current extractor doesn't produce.
- **Session-trace replay** (Level 3). Would need runtime instrumentation and a storage backend.
- **MCP tool for journey queries.** If an agent needs the walk server-side later, the frontend walker logic can be ported to Ruby; not doing it now to avoid premature duplication.
- **Journey persistence/sharing.** No URL state for "current journey" in this phase.

## Architecture

Three components, each independently testable.

| Component | Language | Responsibility |
| --- | --- | --- |
| `EntryPointIndexBuilder` | Ruby | Read `tmp/woods/routes/` + extracted controllers, emit `{ identifier, verb, path, controller, action }` rows for every GET route that resolves to an extracted controller. |
| `SchemaGenerator` extension | Ruby | Inject the entry-point index into `schema.json` under a new `entryPoints` key. No changes to `tables` or `nodes` output. |
| `journeyWalker` + Journey Mode UI | TypeScript/React | BFS from a selected entry point over the existing `nodes[*].dependencies` graph, filtered to navigation edges; render the result as a Journey Mode overlay on the existing React Flow canvas. |

The walker reads data that's already in `schema.json` — no new API, no additional fetch. The backend contribution is purely data projection.

## Data Flow

```
extract → tmp/woods/routes/*.json + dependency_graph.json
       ↓
SchemaGenerator
       ├─ existing tables / enums / nodes
       └─ entryPoints: [{ identifier, verb, path, controller, action }]
       ↓
frontend loads schema.json
       ↓
user triggers Journey Mode (⌘K or right-click)
       ↓
journeyWalker(schema, entryIdentifier, { maxDepth, edgeTypes })
       ↓
{ nodes, edges, layers, cycles } → Journey Mode overlay
```

## 1. Backend: Entry-Point Index

### 1.1 `EntryPointIndexBuilder`

New class at `lib/woods/erd/entry_point_index_builder.rb`. Reads the extraction output directory and produces an array of entry-point descriptors.

**Input:**
- `tmp/woods/routes/*.json` (skip `_index.json`) — each file contains `verb`, `path`, `controller`, `action`.
- `tmp/woods/controllers/*.json` — used to verify the route target is an extracted controller. Routes pointing at engines or unextracted controllers are dropped.

**Output shape (per row):**

```json
{
  "identifier": "CheckoutController",
  "verb": "GET",
  "path": "/checkout",
  "action": "new"
}
```

**Rules:**
- Only `verb == "GET"` rows are included. POST/PATCH/DELETE routes don't represent user-initiated navigation starts.
- Skip routes whose `controller` doesn't match an extracted controller identifier (unresolvable → not useful as an entry point).
- Preserve the original controller identifier from the extracted unit (e.g., `Admin::UsersController`), not the normalized route string.
- Sort output by `path` ascending for deterministic schema output (diff-friendly).

### 1.2 `SchemaGenerator` integration

Extend `SchemaGenerator#generate` to append an `entryPoints` key when the routes directory exists.

```ruby
schema['entryPoints'] = EntryPointIndexBuilder.new(@output_dir).build if routes_available?
```

- Gated on presence of `tmp/woods/routes/` — no crash in old extraction output.
- Emitted as a flat array, not nested under `nodes` (different concern).
- Schema validation: add an optional `entryPoints` field to the Valibot schema (see Section 3.1).

### 1.3 Tests

- Unit spec for `EntryPointIndexBuilder`: happy path (GET route with matching controller), filter path (POST, unresolvable controller, missing routes dir), STI/namespace path (`Admin::UsersController`).
- Integration spec: run `SchemaGenerator#generate` on a fixture output directory, assert `entryPoints` shape and count.

## 2. Frontend: Journey Mode

### 2.1 `journeyWalker` (pure function)

New module at `frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts`.

**Signature:**

```ts
type WalkOptions = {
  maxDepth?: number      // default 10
  edgeTypes?: Set<EdgeVia>  // default: new Set(['link_to', 'redirect_to', 'form_action'])
}

type WalkResult = {
  nodes: Map<NodeId, { depth: number }>
  edges: Array<{ from: NodeId, to: NodeId, via: EdgeVia, isBackEdge: boolean }>
  cycles: Array<[NodeId, NodeId]>  // pairs where a back-edge was detected
  truncated: boolean               // true if maxDepth was reached
}

function walk(schema: Schema, entryId: NodeId, opts?: WalkOptions): WalkResult
```

**Algorithm:** BFS with a visited set. At each hop, enumerate `nodes[current].dependencies` filtered by `via ∈ edgeTypes`. If a target has already been visited, record a back-edge in `cycles` but don't re-enqueue. Stop expanding when `depth === maxDepth`; set `truncated: true` if the frontier was non-empty at that cutoff.

**Why pure:** The walker has no React/React Flow dependency. Unit-testable with fixture schemas.

### 2.2 `useJourneyMode` hook

New hook at `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts`. Manages journey state:

```ts
type JourneyState = {
  entryPoint: EntryPoint | null   // null = journey mode off
  maxDepth: number                // default 10
  result: WalkResult | null       // memoized from walker(entryPoint, maxDepth)
}
```

Exposes `enterJourney(entry)`, `exitJourney()`, `setDepth(n)`. Journey state lives in React context so ⌘K, right-click menu, banner, and canvas all read/write the same state.

### 2.3 Canvas integration

Modify the existing React Flow renderer to accept a `journeyResult` prop. When present:

- **Dim non-journey nodes** to ~40% opacity via CSS class (`erd-node--outside-journey`). Keep them visible for orientation — the user can still click to *start a new journey* from a dimmed node.
- **Highlight journey nodes** — no dimming, preserve layer color.
- **Highlight the entry-point node** with a 2px accent border + subtle box-shadow glow.
- **Edge differentiation:** apply CSS classes by `via`:
  - `erd-edge--link_to` → solid stroke, default weight.
  - `erd-edge--redirect_to` → dashed stroke.
  - `erd-edge--form_action` → solid stroke, 2x weight.
  - `erd-edge--back-edge` → half-opacity overlay on any of the above for cycle indication.
- **No re-layout** when entering/exiting journey mode — same ELK layout, only visual overlay. This keeps transitions fast and preserves the user's mental map.

### 2.4 Journey banner

New component at `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx`. Sticky at the top of the canvas area when journey state is active.

Content (left to right):
- `JOURNEY` pill badge.
- `{verb} {path} → {Controller}#{action}`.
- Reach summary: `reaches N nodes · depth M`.
- Depth control (select, options 1–10).
- Edge-type toggles (three checkboxes, all on by default).
- `Exit journey` button.

### 2.5 ⌘K command palette extension

The existing cmdk palette has a "Nodes" section. Add a new section **"Entry Points"** sourced from `schema.entryPoints`.

- Display format per row: `{verb} {path} → {Controller}#{action}`.
- Selecting a row calls `enterJourney(entry)` and closes the palette.
- Group heading appears above `Nodes` (user intent here is usually "start somewhere" before "find a thing").

### 2.6 Right-click context menu

On any controller node, add a context menu item **"Start journey from here"**.

- Only shown on controllers — services/jobs/models aren't entry points.
- Resolves to the controller's identifier, constructs a synthetic `EntryPoint` (no route info), calls `enterJourney`.
- In the journey banner for this case, display `Journey from {Controller}` (no route prefix) to indicate the walk started mid-graph, not from a GET route.

### 2.7 Edge legend

Small always-visible panel in the bottom-left of the canvas during journey mode showing the three edge-type styles with labels. No toggle — it's small and self-explanatory.

### 2.8 Tests

- Walker: unit tests for BFS correctness, depth cap, cycle detection, edge-type filtering.
- `useJourneyMode` hook: enter/exit, depth change re-memoizes result.
- Integration: render journey mode with a fixture schema, assert DOM classes on nodes/edges.

## 3. Schema Changes

### 3.1 Valibot schema addition

Extend the schema package's root schema to include an optional `entryPoints` array:

```ts
const entryPointSchema = v.object({
  identifier: v.string(),
  verb: v.literal('GET'),
  path: v.string(),
  action: v.string(),
})

const schemaSchema = v.object({
  tables: v.record(v.string(), tableSchema),
  enums: v.record(v.string(), enumSchema),
  extensions: v.record(v.string(), v.any()),
  nodes: v.optional(v.record(v.string(), nodeSchema)),
  entryPoints: v.optional(v.array(entryPointSchema)),
})
```

Optional field so existing schemas without an entry-point index continue to parse.

## 4. File Inventory

### New files

| Path | Purpose |
| --- | --- |
| `lib/woods/erd/entry_point_index_builder.rb` | Builds the entry-point array from routes + controllers. |
| `spec/erd/entry_point_index_builder_spec.rb` | Unit tests for the builder. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts` | Pure BFS walker. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/walker.test.ts` | Walker unit tests. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts` | Context + hook for journey state. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx` | Sticky banner component. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyLegend.tsx` | Edge-type legend overlay. |
| `frontend/liam-erd/packages/erd-core/src/features/journey/index.ts` | Module barrel. |

### Modified files

| Path | Change |
| --- | --- |
| `lib/woods/erd/schema_generator.rb` | Append `entryPoints` key when routes dir is present. |
| `frontend/liam-erd/packages/schema/src/schema/schema.ts` | Add `entryPointSchema` + optional field on root. |
| `frontend/liam-erd/packages/erd-core/src/features/erd/**` | Accept `journeyResult` prop; apply node/edge classes. |
| `frontend/liam-erd/packages/cli/src/App.tsx` | Wrap provider; wire ⌘K section + right-click menu. |

## 5. Risks & Open Questions

| Risk | Mitigation |
| --- | --- |
| Large apps could produce 500+ entry points, making ⌘K noisy. | cmdk already fuzzy-filters; group heading keeps visual separation. Consider namespace sub-grouping (`Public`, `Admin`, `API`) in a follow-up if feedback warrants it. |
| Walker in the main render thread could stall on large walks. | Depth cap of 10 caps worst-case traversal size; walker is a pure function, can be moved to a Web Worker if profiling shows an issue. Not doing it preemptively. |
| Dimming level is subjective. | Ship at 40% opacity, make it a CSS variable so it's a one-line tweak without rebuilding. |
| Users might expect journeys to walk non-navigation edges (e.g., `belongs_to`). | Edge-type toggles include `link_to`/`redirect_to`/`form_action` only in this phase. If users ask for model edges, add a fourth toggle in a follow-up. |
| Right-click menu "Start journey from here" on a controller with no GET route in the index — banner shows the synthetic label. | Display `Journey from {Controller}` (no route) to make the partial information explicit. |

## 6. Acceptance Criteria

1. `schema.json` produced by `SchemaGenerator` in a host app includes an `entryPoints` array with one entry per reachable GET route.
2. Loading the ERD in a browser against a host app shows the existing graph with no visual change when journey mode is inactive.
3. Pressing ⌘K shows an "Entry Points" section alongside "Nodes"; selecting an entry enters journey mode.
4. Right-clicking a controller node shows a "Start journey from here" item; selecting it enters journey mode.
5. In journey mode, the banner displays the entry point, reach count, and depth; non-journey nodes are visibly dimmed; edges render with the three differentiated styles; back-edges render with reduced opacity.
6. The depth dropdown changes the visible subgraph without reloading the page or re-laying out the canvas.
7. Exiting journey mode restores full-color nodes and hides the banner/legend.
8. Walker unit tests cover BFS correctness, depth cap, cycle detection, and edge-type filtering.
9. No regressions in existing ERD functionality (layer toggles, Focus Mode, Diff, etc.).
