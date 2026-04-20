# ERD Column-Level Edges & Cardinality — Design Spec

Supersedes edge rendering, node rendering, and show mode sections of the original bidirectional column explorer spec (`2026-04-06-bidirectional-column-explorer-design.md`). Layout, sidebar, search, data flow, and progressive loading from that spec remain unchanged.

## Goal

Transform the column explorer from card-to-card dependency edges into proper ERD-style column-level connections with cardinality markers, configurable column display, and readonly interaction.

## Acceptance Criteria

1. All visible model nodes show their columns (not just center node)
2. Edges connect FK column handle to PK column handle — no card-to-card edges between models
3. Cardinality markers (crow's foot for many, bar for one) express `has_many`, `belongs_to`, `has_one`, `habtm`
4. Edge direction always follows FK-holder → PK-holder (consistent regardless of macro type)
5. Column display is configurable: All Fields / Key Only / Table Name — default All Fields
6. Show mode preference persisted in `localStorage`
7. Center node reflected in URL query param (`?center=X`)
8. Canvas is readonly — users cannot draw new connections (`nodesConnectable={false}`, `edgesUpdatable={false}`)
9. Center-only edge visibility — no inter-neighbor spaghetti
10. Nodes with 20+ columns show first 8 + all PK/FK + `"+ N more"` row (expandable per-node)

---

## Architecture: Approach A — AssociationEdgeBuilder

### Problem

`DependencyGraph#register` drops the `:via` key from dependencies, storing only target strings:
```ruby
@edges[unit.identifier] = unit.dependencies.map { |d| d[:target] }
```

EdgeBuilder receives `{ "Account" => ["Plan", "Country"] }` — no relationship type, no FK column, no target PK. The raw data exists in `unit_metadata[id]['metadata']['associations']` (type/macro, foreign_key, class_name, through, polymorphic) but never reaches the edge layer.

`DependencyGraph` is core infrastructure on `main` with wide blast radius (GraphAnalyzer, Retriever, PageRank, MCP tools). Changing it risks regressions for a visualization feature.

### Solution

New `AssociationEdgeBuilder` class in `lib/woods/svelte_flow/` that reads association metadata from `unit_metadata` and produces edges with full ERD semantics. Existing `EdgeBuilder` continues handling non-model edges (controller→model, job→service, etc.).

**Partition logic in Transformer:** `AssociationEdgeBuilder` handles model↔model edges; `EdgeBuilder` handles everything else. Partition is by unit type — no overlap, no deduplication needed.

---

## Backend: AssociationEdgeBuilder

### New file: `lib/woods/svelte_flow/association_edge_builder.rb`

Iterates `unit_metadata` for model-type units, reads their `metadata.associations`, and produces edges.

### Edge data shape

```json
{
  "id": "assoc-Account-belongs_to-Plan-plan_id",
  "source": "Account",
  "target": "Plan",
  "type": "association",
  "data": {
    "via": "belongs_to",
    "foreignKey": "plan_id",
    "sourceHandle": "Account-plan_id",
    "targetHandle": "Plan-id",
    "through": null,
    "polymorphic": false,
    "isCycle": false
  }
}
```

### Edge direction convention

**Source always holds the FK column; target always holds the PK column.**

| Macro | Natural direction | Edge source | Edge target | Why |
|---|---|---|---|---|
| `belongs_to` | Account→Plan | Account (has `plan_id`) | Plan (has `id`) | Natural — FK holder is source |
| `has_many` | Account→Orders | Order (has `account_id`) | Account (has `id`) | **Flipped** — Order holds the FK |
| `has_one` | Account→Profile | Profile (has `account_id`) | Account (has `id`) | **Flipped** — Profile holds the FK |
| `habtm` | Account↔Tags | (join table) | (join table) | Both get crow's foot markers |

This means the frontend never needs to interpret macro types for handle routing — `sourceHandle` is always the FK column, `targetHandle` is always the PK column.

### Deduplication

Rails associations are bidirectional: Account `has_many :orders` and Order `belongs_to :account` describe the same FK relationship (`orders.account_id → accounts.id`). The builder deduplicates by canonical key: `{fk_table}-{fk_column}-{pk_table}`. First occurrence wins.

### has_many :through

Included with `through` field populated. The direct FK edges (through the join model) already exist — `through` edges are logical shortcuts. Frontend can choose to render or hide them.

### Polymorphic associations

Flagged with `polymorphic: true`. FK column is `{name}_id` and type column is `{name}_type`. Target is the declared `class_name` or association name.

### Changes to existing files

- **`transformer.rb`**: Instantiate `AssociationEdgeBuilder` with `unit_metadata` and `cycle_edges`. Partition: association edges for model↔model, existing `EdgeBuilder` for non-model edges (filter `edges` hash to exclude model→model pairs).
- **`edge_builder.rb`**: Add `exclude_pairs` option — a `Set` of `[source, target]` pairs to skip (populated by Transformer with model↔model pairs that AssociationEdgeBuilder handles).

---

## Frontend: Node Rendering

### All model nodes show columns

Remove the `{#if isCenter}` gate in `ModelNode.svelte`. Every model node renders its column rows with handles.

### Handle ID format

Change from `col-left-{colName}` / `col-right-{colName}` to `{modelName}-{colName}`:
- Each column row gets **one handle on each side** with ID `{modelName}-{colName}`
- Left handle: `type="target"`, `position={Position.Left}`
- Right handle: `type="source"`, `position={Position.Right}`
- FK columns: visible dot on handle
- PK columns: visible dot on handle
- Other columns: handles present but visually transparent

The model name is passed as `id` on the SvelteFlow node, accessible via `$props()`.

### Show modes

Component: `ShowModeSelector.svelte` — segmented control in the header bar.

| Mode | Renders | Handle behavior |
|---|---|---|
| All Fields | Every column row | All handles active |
| Key Only | Only PK + FK columns | Only key handles active |
| Table Name | Header only, no columns | Card-level handles only |

State: `$state` in `App.svelte`, passed down as prop. Persisted in `localStorage` key `woods-flow-show-mode`. Default: `all_fields`.

### Column collapse (20+ columns)

In All Fields mode, nodes with 20+ columns show:
- First 8 columns
- All PK and FK columns (even if beyond position 8)
- `"+ N more"` clickable row at the bottom
- Click expands to show all columns (per-node `$state`)

This prevents massive nodes from dominating the layout while keeping all connection-relevant columns visible.

### Node height estimation

`column-layout.js` `estimateNodeHeight` updates:
- Remove `isCenter` branch — all model nodes use full column height
- Account for show mode: `all_fields` uses column count, `key_only` uses PK+FK count, `table_name` uses base height only
- Account for collapse: capped at 8 + FK/PK count + 1 (for the "+ N more" row) when collapsed

---

## Frontend: Edge Rendering

### Edge routing

- Edge type: `smoothstep` (clean routing around nodes)
- `sourceHandle` and `targetHandle` come directly from edge data — no heuristic name-matching
- `findFkColumn` function removed entirely

### SVG cardinality markers

Three marker definitions in the SvelteFlow container:

```
marker-bar:       │  (single vertical bar — "one")
marker-crow-foot: ─< (three-pronged fork — "many")  
marker-none:      (no marker)
```

| Relationship | markerStart (source/FK end) | markerEnd (target/PK end) |
|---|---|---|
| `belongs_to` | `marker-none` | `marker-bar` |
| `has_one` | `marker-none` | `marker-bar` |
| `has_many` | `marker-crow-foot` | `marker-bar` |
| `habtm` | `marker-crow-foot` | `marker-crow-foot` |

Markers defined as `<defs>` in a wrapper `<svg>` inside the SvelteFlow container. Referenced via `markerStart`/`markerEnd` props on each edge.

### Edge styling

| State | Stroke | Width | Style |
|---|---|---|---|
| Default association | `#475569` | 1.5px | Solid + markers |
| `:through` edge | `#475569` | 1px | Solid, opacity 0.4 |
| Cycle | `#64748b` | 1px | Dashed (4 3) |
| Non-model dependency | `#475569` | 1.5px | Solid, no markers |

### Visibility rules

- Only edges connected to the center node are shown (existing behavior, preserved)
- Inter-neighbor edges remain hidden
- When a neighbor becomes center (click), its edges become visible

---

## Frontend: Readonly & URL State

### Readonly canvas

Add to SvelteFlow component:
```svelte
nodesConnectable={false}
edgesUpdatable={false}
nodesDraggable={true}
```

Node dragging stays enabled. Users cannot draw new edges or modify existing ones.

### URL state

- `?center=X` query param reflects current center node
- Updated via `history.replaceState` on center change (no page reload, no back-button entry per navigation)
- On page load: parse `?center` param, use as initial center node
- If param value doesn't match any node ID, fall back to highest-PageRank node
- Show mode stays in `localStorage` (user preference, not shareable state)

Implementation in `App.svelte`:
- `setCenterNode` calls `history.replaceState` with updated `?center` param
- `onMount` / initialization reads `URLSearchParams` for initial center

---

## File Summary

### New files
- `lib/woods/svelte_flow/association_edge_builder.rb`
- `spec/svelte_flow/association_edge_builder_spec.rb`
- `frontend/src/components/ShowModeSelector.svelte`
- `frontend/src/components/CardinalityMarkers.svelte`

### Modified files
- `lib/woods/svelte_flow/transformer.rb` — partition edges between builders
- `lib/woods/svelte_flow/edge_builder.rb` — add `exclude_pairs` option
- `frontend/src/components/ModelNode.svelte` — remove isCenter gate, update handle IDs, show mode support, column collapse
- `frontend/src/components/ColumnLayout.svelte` — remove `findFkColumn`, use edge data handles, add readonly props, add marker defs, pass show mode
- `frontend/src/lib/column-layout.js` — update `estimateNodeHeight` for show modes
- `frontend/src/App.svelte` — show mode state, URL state, pass show mode to components

### Unchanged
- `lib/woods/dependency_graph.rb` — no changes to core
- `lib/woods/svelte_flow/node_builder.rb` — already builds columns with FK/PK flags
- `frontend/src/components/CompactNode.svelte` — non-model nodes unchanged
- `frontend/src/components/FocusNode.svelte` — viewport centering unchanged
- `frontend/src/components/Sidebar.svelte` — unchanged
- `frontend/src/components/SearchDropdown.svelte` — unchanged
- `frontend/src/lib/api.js` — unchanged
- `frontend/src/lib/graph-state.js` — unchanged
