# Woods Visualize Navigation Redesign

## Goal

Replace the current flat graph views with a Liam ERD-inspired hybrid navigation system: left sidebar for browsing/filtering, center canvas with enhanced node rendering (model nodes show columns/types), right detail panel on click, and highlight/dim behavior for connected nodes. Solve the 6K+ node scale problem through visibility filtering rather than a layout engine change.

## Architecture

Incremental enhancement of the existing Svelte 5 + @xyflow/svelte + dagre stack. No new framework dependencies. The Flows tab is removed (deferred until FlowPrecomputer produces multi-step data). Two tabs remain: Dependencies and Clusters, each getting the full sidebar + enhanced nodes + highlight/dim treatment.

### Reference

Liam ERD (github.com/liam-hq/liam, Apache 2.0) serves as the primary UI/UX reference. Key patterns adopted: three-zone layout, highlight/dim on selection, per-entity visibility toggles, type-grouped sidebar with filter. Patterns deferred: command palette (Cmd+K), show mode toggle, ELK.js layout engine, URL-encoded state.

## Layout

Three-zone horizontal layout filling the viewport:

- **Left sidebar** (240px, fixed): Unit browser with filter input, type-grouped collapsible sections, per-unit visibility toggles, bulk Show All / Hide All
- **Center canvas** (flex: 1): @xyflow/svelte canvas with dagre layout, controls, minimap. Tab bar (Dependencies / Clusters) overlaid at top-left
- **Right detail panel** (280px, conditional): Slides in from right on node selection. Shows unit metadata, dependency/dependent counts. Closes on X or clicking canvas background

The sidebar is always visible. The detail panel only renders when a node is selected (`activeNodeId !== null`).

## Tabs

### Dependencies

The primary view. Shows the full dependency graph with all unit types. Sidebar lists all extracted units grouped by type. Visibility toggles control which nodes appear on the canvas. Layout recalculates when visibility changes.

### Clusters

Shows domain clusters from GraphAnalyzer. Sidebar adapts to show cluster members grouped by cluster name (not by type). Boundary edges render with dashed cyan styling (existing behavior). Same highlight/dim and detail panel behavior as Dependencies.

### Flows (Deferred)

Removed from the UI for now. The FlowPrecomputer currently produces single-step flows (one controller action with operations nested as an array). This renders as a single node with zero edges — not useful as a graph visualization. Flows will return when the gem produces multi-step flow data with proper step-to-step edges.

## Sidebar

### Filter Input

Text input at the top of the sidebar. Filters the unit list in real-time by substring match against unit names (case-insensitive). The filter only affects sidebar rendering — it does not hide nodes on the canvas. This separation is intentional: filtering is for finding things in the list, visibility toggles are for controlling what's on the canvas.

### Type Groups

Units are grouped by their `unitType` into collapsible sections. Each section header shows:
- Collapse/expand chevron
- Type color dot (matching node border color on canvas)
- Type name (e.g., "Models", "Controllers")
- Count of units in that type

All groups start collapsed except the first. Collapse state is UI-only — no effect on canvas visibility.

Type groups and their colors (from existing theme.js TYPE_COLORS):
- Models (blue #3b82f6)
- Controllers (green #22c55e)
- Jobs (amber #f59e0b)
- Services (purple #a855f7)
- Mailers (pink #ec4899)
- Concerns (cyan #06b6d4)
- Middleware (orange #f97316)
- Routes (lime #84cc16)
- Channels (indigo #6366f1)
- Configurations (slate #64748b)
- All other types use their existing theme colors

### Unit List Items

Each unit in an expanded type group shows:
- Unit name (truncated with ellipsis if too long)
- Visibility toggle (eye icon): click to show/hide this unit on the canvas

Click behavior:
- **Click unit name**: Pan canvas to that node, select it (triggers highlight/dim), open detail panel
- **ALT+Click (Option+Click on Mac) unit name**: Focus mode — hide all nodes except this unit and its direct dependencies/dependents, re-run layout. "Show All" resets

### Bulk Visibility

"Show All" and "Hide All" links below the filter input. Show All makes all units visible on the canvas. Hide All hides all units. These are the reset mechanisms — users always start from "everything visible" and filter down.

## Node Rendering

Two node components replace the current `WoodsNode.svelte`:

### ModelNode

For units with `unitType === 'model'`. Shows:

**Header row:**
- Type color dot (8px square, border-radius 2px)
- Model name (bold, truncated with ellipsis)
- Role badge if applicable: "HUB" or "BRG" (right-aligned, small text)

**Column rows** (below header, separated by 1px borders):
Each column shows:
- Key indicator icon:
  - Primary key: key icon
  - Foreign key: link icon
  - Required (not null, not key): filled diamond
  - Optional (nullable): empty diamond
- Column name
- Column type (right-aligned, muted color)

Column data comes from the API (see API Changes section).

### CompactNode

For all non-model units. Shows:

**Header row:**
- Type color dot
- Unit name (bold, truncated)
- Role badge if applicable

**Attribute row(s)** (below header, separated by 1px borders):
Type-specific content:
- **Controllers**: action names (comma-separated: index, show, create, update, destroy)
- **Jobs**: queue name
- **Mailers**: mail method names
- **Services / POROs / Libs**: file path (relative to app/)
- **Concerns**: included-by list (which models/controllers include this concern)
- **Middleware / Engines**: mount path or class name
- **Routes**: HTTP method + path pattern
- **Other types**: file path as fallback

### Highlight / Dim Behavior

Triggered when a node is selected (clicked on canvas or clicked in sidebar).

Three visual states:

1. **Active node** (the selected one):
   - 2px solid green border (#22c55e)
   - Green glow box-shadow: `0 0 20px rgba(34, 197, 94, 0.3)`
   - Full opacity

2. **Related nodes** (connected to active via edges, either direction):
   - 1px solid green border (#22c55e)
   - Subtle glow: `0 0 12px rgba(34, 197, 94, 0.2)`
   - Full opacity

3. **Unrelated nodes** (no connection to active):
   - Default border at 50% opacity
   - Node content at 40% opacity
   - No glow

**Edge highlighting:**
- Edges connecting to/from the active node: green stroke, elevated z-index
- All other edges: dimmed to 30% opacity

The highlight state is computed by building an adjacency set from the edge list (bidirectional), then classifying each node. This is a pure function: `(nodes, edges, activeNodeId) => classifiedNodes`. The classification is stored in the node `data` object as `isActive` and `isHighlighted` booleans, and CSS responds to these flags.

Clicking the canvas background (not a node) clears the active selection and removes all highlighting.

## Detail Panel (Right)

The existing `NodeDetail.svelte` component, enhanced with:
- **Dependency count**: Number of units this node depends on
- **Dependent count**: Number of units that depend on this node
- **Column detail** (model nodes only): Repeat of column list for reference when zoomed out

The panel slides in from the right with a CSS transform transition (existing behavior). It renders only when `activeNodeId` is set.

## API Changes (Ruby)

### Transformer Updates

The `Transformer` class needs to enrich node data for the frontend.

**Model nodes** get a `columns` array:
```json
{
  "id": "Account",
  "data": {
    "label": "Account",
    "unitType": "model",
    "columns": [
      { "name": "id", "type": "bigint", "primary": true, "nullable": false },
      { "name": "account_id", "type": "bigint", "foreign": true, "nullable": false },
      { "name": "name", "type": "string", "primary": false, "foreign": false, "nullable": false },
      { "name": "email", "type": "string", "primary": false, "foreign": false, "nullable": true }
    ]
  }
}
```

Column data is sourced from the `ExtractedUnit`'s serialized output — the `ModelExtractor` already extracts schema columns with types, nullability, and key status. The `NodeBuilder` reads this from the unit data and includes it in the Svelte Flow node's `data` hash.

**Non-model nodes** get an `attributes` field with type-specific content:
```json
{
  "id": "AccountsController",
  "data": {
    "label": "AccountsController",
    "unitType": "controller",
    "attributes": ["index", "show", "create", "update", "destroy"]
  }
}
```

The `attributes` field is a flat array of strings. Content varies by type:
- Controllers: action names
- Jobs: `["queue: default"]`
- Mailers: method names
- Services/POROs/Libs: `["app/services/account_service.rb"]` (relative file path)
- Concerns: names of including classes
- Other: `[relative_file_path]`

### Symbol-or-String Cleanup

The transformer currently uses fallback patterns like `step[:unit] || step['unit']` throughout. Since `JSON.parse` always produces string keys, all symbol-key fallbacks are dead code. Clean these up to use string keys only. This is a correctness fix — the fallback pattern masks data shape issues.

### Dependency/Dependent Counts

Add `dependencyCount` and `dependentCount` to each node's data. These are already available from the `DependencyGraph` — count of forward edges and reverse edges per node.

## Frontend State

All state lives in `App.svelte` using Svelte 5 runes. No external stores.

| State | Type | Purpose |
|---|---|---|
| `activeTab` | `$state('graph')` | Current tab: 'graph' or 'clusters' |
| `activeNodeId` | `$state(null)` | Selected node ID, drives highlight + detail panel |
| `visibleNodeIds` | `$state(new Set())` | Which nodes are visible on canvas. Starts as all nodes |
| `filterText` | `$state('')` | Sidebar filter input value |
| `collapsedTypes` | `$state(new Set(allTypeNames.slice(1)))` | Which type groups are collapsed in sidebar. Starts with all collapsed except first type |
| `allNodes` | `$state.raw([])` | Full node array from API (never filtered) |
| `allEdges` | `$state.raw([])` | Full edge array from API |

Derived values (using `$derived`):
- `visibleNodes` — `allNodes` filtered by `visibleNodeIds`, with highlight flags applied based on `activeNodeId`
- `visibleEdges` — `allEdges` filtered to only include edges where both source and target are visible, with highlight flags
- `filteredSidebarUnits` — `allNodes` filtered by `filterText` for sidebar display
- `groupedUnits` — `filteredSidebarUnits` grouped by `unitType`

## New Svelte Components

| Component | File | Purpose |
|---|---|---|
| `Sidebar.svelte` | `frontend/src/components/Sidebar.svelte` | Left panel: filter, type groups, unit list, visibility toggles |
| `TypeGroup.svelte` | `frontend/src/components/TypeGroup.svelte` | Collapsible section within sidebar |
| `ModelNode.svelte` | `frontend/src/components/ModelNode.svelte` | Node for model units with column list |
| `CompactNode.svelte` | `frontend/src/components/CompactNode.svelte` | Node for non-model units with type-specific attributes |

### Modified Components

| Component | Changes |
|---|---|
| `App.svelte` | Add sidebar, refactor state management, add highlight logic, remove Flows tab |
| `GraphView.svelte` | Accept visibility/highlight props, pass filtered nodes/edges to SvelteFlow |
| `ClusterView.svelte` | Same sidebar integration as GraphView but with cluster-grouped sidebar |
| `NodeDetail.svelte` | Add dependency/dependent counts, column detail for models |

### Removed Components

| Component | Reason |
|---|---|
| `WoodsNode.svelte` | Replaced by ModelNode + CompactNode |
| `FlowView.svelte` | Flows tab deferred |

## CSS Changes

### app.css Updates

- Add `.sidebar-panel` styles (240px fixed width, flex column, overflow-y scroll for unit list)
- Add `.filter-input` styles
- Add `.type-group` collapsible section styles
- Add `.unit-item` with hover state and active highlight
- Add `.visibility-toggle` eye icon button styles
- Update `#app` grid to accommodate sidebar: `grid-template-columns: 240px 1fr`
- Update `.flow-container` to work within the new grid
- Remove `.flow-selector` styles (Flows tab removed)

### Node CSS

Column rows in ModelNode use `border-bottom: 1px solid var(--border)` between each row for clear visual separation (per user requirement).

Highlight/dim states use CSS classes:
- `.node-active` — 2px green border + glow
- `.node-highlighted` — 1px green border + subtle glow
- `.node-dimmed` — 50% border opacity, 40% content opacity

### Accessibility (Core Requirement)

All color choices must meet **WCAG AA** minimum contrast ratios against the dark background:
- Text on `--bg-primary` (#0f172a): minimum 4.5:1 for normal text, 3:1 for large text
- Text on `--bg-secondary` (#1e293b): same ratios
- Green highlight (#22c55e) on dark backgrounds: verify 3:1 minimum for the border/glow (non-text element)
- Highlight state must be distinguishable without relying on color alone — the border width change (1px default → 2px active) and glow shadow provide non-color signals
- Type color dots in sidebar must not be the sole differentiator — the type group label text provides the primary identification
- Eye toggle icons need sufficient contrast in both visible and hidden states
- Focus indicators for keyboard navigation on all interactive sidebar elements

## Future Enhancements (Not In Scope)

### Command Palette (Cmd+K)

Floating dialog triggered by keyboard shortcut. Fuzzy search across all units with a live node preview panel on the right side. Liam ERD uses the `cmdk` library (React); Svelte equivalent would be a custom implementation or `svelte-command-palette`. The palette would also surface commands: Zoom to Fit, Re-layout, Show All, Hide All.

**When to add:** After the sidebar + filter covers the basic navigation use case and users report needing faster keyboard-driven navigation.

### Show Mode Toggle

Three display density modes:
- **All Fields** (current/default): model nodes show columns, non-model nodes show attributes
- **Compact**: all nodes show only name + type badge
- **Name Only**: minimal nodes, just the name text

**When to add:** When users with smaller codebases want the current dense view but users with larger codebases want a zoomed-out overview that's still readable. The toggle goes in the bottom toolbar area.

### ELK.js Layout Engine

Replace dagre with ELK.js (`elkjs` npm package, ~180KB) for the layered layout algorithm. ELK provides:
- Better edge cross-minimization (fewer crossing edges)
- Component separation (disconnected subgraphs laid out in distinct regions)
- Orphan node grouping (non-related nodes collected into a container)
- Configurable node/edge spacing

**Migration strategy:**
1. The layout logic is isolated in `frontend/src/lib/layout.js` (`getLayoutedElements` function)
2. Create `frontend/src/lib/layout-elk.js` with the same function signature
3. ELK layout is async — wrap in a loading state (show spinner overlay during layout computation)
4. Swap the import in GraphView/ClusterView
5. Recommended ELK options (from Liam ERD):
   ```js
   {
     'elk.algorithm': 'layered',
     'elk.layered.spacing.baseValue': '40',
     'elk.spacing.componentComponent': '80',
     'elk.layered.spacing.edgeNodeBetweenLayers': '120',
     'elk.layered.considerModelOrder.strategy': 'PREFER_EDGES',
     'elk.layered.crossingMinimization.forceNodeModelOrder': 'true',
     'elk.layered.mergeEdges': 'true'
   }
   ```
6. The `getLayoutedElements` interface stays the same: `(nodes, edges, direction) => { nodes, edges }` — just returns a Promise instead of synchronous result

**When to add:** When dagre's layout quality becomes a user complaint (wide/shallow graphs, excessive edge crossings). The sidebar + visibility filtering may reduce this pressure significantly by keeping visible node counts manageable.

### URL-Encoded State

Encode view state in URL query parameters for shareable views:
- `?tab=graph|clusters`
- `?active=AccountModel` (selected node)
- `?hidden=compressed_id_list` (LZ-string compressed, per Liam ERD pattern)

**When to add:** When users need to share specific filtered views with teammates or bookmark commonly-used configurations.

### User Customization for Node Attributes

Allow users to configure which attributes appear on non-model nodes per type, beyond the defaults. Could be a settings panel or per-type configuration in the Woods initializer.

**When to add:** After observing which attributes users actually find useful vs. noise.

## Testing

### Ruby Specs

- `Transformer` specs: verify `columns` array present on model nodes, `attributes` on non-model nodes, `dependencyCount` and `dependentCount` on all nodes
- `NodeBuilder` specs: verify enrichment logic for different unit types
- Symbol-or-string cleanup: existing specs should continue to pass (they exercise the string-key path)

### Frontend

Manual testing in the host app:
- Sidebar filter narrows list correctly
- Eye toggle hides/shows nodes and triggers re-layout
- Click unit name in sidebar → canvas pans to node, highlights, opens detail panel
- ALT+Click → focus mode shows only selected + relations
- Show All resets to full graph
- Highlight/dim behavior on node click: active (2px green), related (1px green), unrelated (dimmed)
- ModelNode renders columns with borders between rows
- CompactNode renders type-specific attributes
- Tab switching between Dependencies and Clusters preserves no stale state
- Detail panel shows dependency/dependent counts
- All text meets WCAG AA contrast ratios against dark backgrounds

## Tech Stack

No new runtime dependencies. The implementation uses:
- Svelte 5 (runes: `$state`, `$state.raw`, `$derived`, `$props`)
- @xyflow/svelte 1.5.x (SvelteFlow, Controls, MiniMap, Background)
- @dagrejs/dagre 1.x (layout engine, existing)
- Vite 6.x (build tool, existing)
