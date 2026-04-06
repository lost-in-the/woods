# Bidirectional Column Explorer — Design Spec

## Goal

Replace the current "show all 6000+ nodes in dagre" visualization with a focused, node-centered column explorer. One model is selected at a time. Dependencies flow left, dependents flow right. Branches expand on demand.

## Architecture

The visualization becomes a **column-based explorer** instead of a full-graph renderer. The selected node sits in the center column. Its `belongs_to` relationships appear in columns to the left, its `has_many`/`has_one` relationships appear in columns to the right. Users expand branches selectively with per-node controls, navigating the graph like a file explorer rather than staring at a spiderweb.

**Tech stack:** Svelte 5 (existing), @xyflow/svelte (existing), custom column layout (replacing dagre).

---

## Layout

### Bidirectional Columns

```
← Depends On  |  Selected Node  |  Dependents →
  (parents)    |    (center)     |   (children)
```

- **Center column**: The selected model, rendered as a full ERD card with all columns, types, and icons.
- **Left columns**: Models this node depends on (`belongs_to`, `include`). Grouped by relationship type with collapsible accordion headers.
- **Right columns**: Models that depend on this node (`has_many`, `has_one`, `code_reference`). Same grouping.

### Relationship Grouping

Within each column, nodes are organized under collapsible relationship-type headers:
- `has_many (42)` — expanded by default
- `has_one (18)` — collapsed by default
- `code_reference (8)` — collapsed
- `include (4)` — collapsed

Nodes within each group are sorted by PageRank (most connected first).

### Per-Branch Expansion

Each non-leaf node has an expand button (`»` or `«`) that floats **outside** the card, on the side the new column will appear:
- **Right-side nodes**: `»` button on the right edge of the card
- **Left-side nodes**: `«` button on the left edge of the card
- **Leaf nodes** (no further dependencies): no button shown

Interactions:
- **Click** expand button: show this node's direct children in a new column (one level)
- **Alt+click** expand button: expand the full chain recursively (max depth 5, cycle-aware — stops at nodes already visible or at cycle boundaries)
- **Click** collapse button (`«`/`»` flips when expanded): remove the child column. Cascading — collapsing a node also removes any deeper columns spawned from its children.

Expanded nodes get a green (#22c55e) highlight border. The button flips direction to indicate collapse.

### Column Headers

Each expanded column has a header showing the path that spawned it:
- `Order → has_many`
- `LineItem → belongs_to`

This traces the expansion path so the user always knows how they got to this column.

### Global Depth Control

A `Depth [− 1 +]` widget below the center node sets the baseline minimum depth. Per-branch expansions can exceed it. Reducing global depth collapses all per-branch expansions back to the baseline.

---

## Edge Rendering

### Column-Level Joins

Edges connect at the **column row level**, not card-to-card:
- Each column row in a ModelNode gets left and right Svelte Flow handles (named: `col-left-{column_name}`, `col-right-{column_name}`)
- FK columns (e.g., `account_id`) connect via their handle to the PK (`id`) handle on the related model
- Non-model nodes (CompactNode) use standard card-level handles

### Cardinality Indicators

Small labels at each end of the edge:
- `1` on the PK side
- `n` for `has_many` relationships
- `1` for `has_one` / `belongs_to` relationships

Positioned near the handle attachment point.

### `has_many :through` Relationships

Show the target model directly in the column with a subtle `via IntermediateModel` label on the edge or as a sub-label. The intermediate model is navigable — it appears if you re-center on it or encounter it through other expansion paths.

### Cross-Column Edges

Edges primarily connect adjacent columns. However, when a direct FK→PK relationship spans more than one column (e.g., a `through` relationship or a shared dependency appearing at multiple depths), the edge may span across an intermediate column. These cross-column edges render with reduced opacity and thinner stroke to avoid visual dominance.

### Edge Styling

| State | Stroke | Width | Style |
|-------|--------|-------|-------|
| Default | `#475569` | 1.5px | Solid |
| Active branch (expanded) | `#22c55e` | 2px | Solid |
| Depth 2+ connector | `#22c55e` | 1.5px | Dashed (4 2) |
| Cross-column span | `#475569` | 1px | Solid, opacity 0.4 |
| Cycle detected | `#ef4444` | 2px | Animated dash |

Cycle nodes show a cycle icon (↻) instead of an expand button.

---

## Node Rendering

### ModelNode Enhancements

- Column rows get **left and right Svelte Flow handles** for column-level edge connections
- FK columns show 🔗 icon, PK columns show 🔑 icon
- Cardinality labels rendered at handle attachment points
- Hub/bridge roles communicated subtly — thicker border weight or a small connectivity count badge rather than a prominent colored label

### Center Node Distinction

- Green border (#22c55e) with subtle box-shadow glow
- Header background tinted with green at low opacity
- Slightly larger than neighbor nodes

### CompactNode (Non-Model Types)

- Controllers, jobs, services, concerns render as simpler cards without column-level handles
- Edges connect card-to-card at standard handles
- Unchanged from current implementation

### Color System

Dark-mode focused, accessible palette. All foreground/background combinations must meet WCAG AA contrast ratios (4.5:1 for text, 3:1 for UI elements).

**Node type colors** (border + type dot):

| Type | Color | Hex |
|------|-------|-----|
| Model | Indigo | `#818cf8` |
| Controller | Teal | `#2dd4bf` |
| Job | Amber | `#fbbf24` |
| Service / PORO | Slate blue | `#64748b` |
| Concern | Violet | `#a78bfa` |
| Mailer | Rose | `#fb7185` |
| GraphQL | Cyan | `#22d3ee` |
| Route | Orange | `#fb923c` |
| Migration | Gray | `#9ca3af` |
| Lib | Emerald | `#34d399` |
| Other | Neutral | `#71717a` |

**Functional colors:**

| Purpose | Hex |
|---------|-----|
| Canvas background | `#0f172a` |
| Card background | `#1e293b` |
| Card border (default) | type color above |
| Center node border | `#22c55e` |
| Center node glow | `rgba(34, 197, 94, 0.15)` |
| Expanded branch border | `#22c55e` |
| Text primary | `#e2e8f0` |
| Text secondary | `#94a3b8` |
| Text muted | `#64748b` |
| Edge default | `#475569` |
| Edge active | `#22c55e` |
| Edge cycle | `#ef4444` |
| Expand button default | `#334155` border, `#475569` text |
| Expand button hover | `#475569` border, `#e2e8f0` text |

---

## Sidebar

### Structure

Four sections with sticky headers, top to bottom:

1. **Search** (always visible at top)
2. **Visible** — models currently shown in the graph
3. **Hidden** (collapsible) — all models not currently displayed
4. **Recent** (collapsible, sticky at bottom) — session history

### Search

- Text input at the top of the sidebar, always visible
- As the user types, a **dropdown overlay** appears below the input (command palette style)
- Results grouped by type with small type badges: `MODEL`, `CONTROLLER`, `JOB`
- Each result shows: **name** with bold substring match highlighting + type badge + connectivity count (e.g., `391 connections`)
- Max 10 results visible, scrollable if more match
- **Enter** or **click** a result: re-centers the view on that node, closes the dropdown
- **Escape** or click outside: closes the dropdown
- When the search field is empty, the dropdown is hidden — Visible/Hidden/Recent sections show underneath

### Visible Section

- Header: `Visible (8/212)` + **Clear All** button (resets to center node only)
- Lists all models currently rendered in the graph
- Center node highlighted with green text/indicator
- **Eye icon** on hover for each item — click to hide (moves to Hidden section, removes from graph)
- Click model name to re-center the view on it

### Hidden Section

- Collapsible, collapsed by default
- Contains all models not currently displayed
- Grouped by unit type with collapsible sub-sections (`Models (204)`, `Controllers (333)`, etc.)
- **Eye icon** on hover — click to show (adds to graph, moves to Visible)
- Click model name to show + re-center

### Recent Section

- Collapsible, sticky at bottom of sidebar
- Last 10 visited nodes (session memory, not persisted)
- Click to re-center on that node (adds to Visible if not already shown)

---

## Data Flow & API

### Progressive Loading

The full dependency graph JSON is ~80K lines. Loading strategy:

1. **Initial load**: New endpoint `GET /api/graph/neighbors?node={id}&depth=1` returns only the subgraph needed for the initial view (center node + depth 1 neighbors with their metadata).
2. **On-demand expansion**: When the user expands a branch (`»`), fetch that node's neighbors via the same endpoint if not already cached.
3. **Background prefetch**: After initial view renders, fetch the full graph (`GET /api/graph`) in the background. Once loaded, all subsequent operations are purely client-side.
4. **Cache with staleness check**: If the full graph is cached and the manifest hasn't changed (existing mtime check), skip the background fetch.

### New API Endpoint

`GET /api/graph/neighbors?node={identifier}&depth={n}`

Returns:
```json
{
  "nodes": { ... },
  "edges": { ... },
  "reverse": { ... },
  "unit_metadata": { ... }
}
```

Scoped to the requested node's neighborhood at the given depth. Includes unit metadata for enrichment (columns, associations).

### Client-Side State

| State | Type | Purpose |
|-------|------|---------|
| `centerNodeId` | `string` | Currently selected center model |
| `expandedBranches` | `Map<string, Set<'left'\|'right'>>` | Nodes with expanded children (can expand both directions) |
| `visibleNodeIds` | `Set<string>` | Derived from center + expansions |
| `hiddenNodeIds` | `Set<string>` | Explicitly hidden via sidebar eye toggle |
| `recentNodes` | `string[]` | Last 10 visited node IDs |
| `graphCache` | `object \| null` | Full graph once background-loaded |
| `neighborCache` | `Map<string, object>` | Per-node neighbor data from API |

### Layout Computation

Replace dagre with a **custom column layout**:
- Positions are deterministic: column index × column width for X, vertical stack index × row height for Y
- No graph layout algorithm — columns positioned left-to-right, nodes stacked vertically within each column with fixed spacing
- Simpler, faster, and produces the exact layout needed

---

## Removed / Replaced

### Removed
- **dagre dependency** — removed from `package.json`
- **`layout.js`** — deleted (replaced by custom column positioning)
- **`GraphView.svelte`** — deleted (replaced by `ColumnLayout.svelte`)
- **`ClusterView.svelte`** — deleted (deferred to future phase)
- **Cluster tab and cluster API consumption** — removed from `App.svelte`
- **"Show All" / "Hide All" bulk buttons** — replaced by sidebar eye toggles + Clear All
- **Type-based sidebar grouping as primary navigation** — replaced by Visible/Hidden/Recent sections

All dead code cleaned up: unused imports, unused components, unused CSS, dagre from dependencies.

### Kept and Adapted
- **`ModelNode.svelte`** — enhanced with column-level handles and cardinality
- **`CompactNode.svelte`** — unchanged
- **`NodeDetail.svelte`** (right detail panel) — unchanged
- **`FocusNode.svelte`** (camera centering) — kept for re-center animations
- **`api.js`** — extended with neighbor endpoint
- **`theme.js`** — updated with new color palette
- **API endpoints and `RackMiddleware`** — extended with neighbor endpoint, existing endpoints unchanged
- **`Transformer`, `NodeBuilder`, `EdgeBuilder`** — unchanged on Ruby side

### New Components
- **`ColumnLayout.svelte`** — replaces GraphView, renders the bidirectional column grid
- **`ExpandButton.svelte`** — the `»`/`«` control floating outside node cards
- **`ColumnHeader.svelte`** — relationship group label + path breadcrumb
- **`SearchDropdown.svelte`** — command palette overlay for search results
- **Updated `Sidebar.svelte`** — Visible/Hidden/Recent sections with eye toggles

### New Backend
- **`GET /api/graph/neighbors`** endpoint in `RackMiddleware` — subgraph extraction for progressive loading

---

## Default Start State

1. App loads, requests `GET /api/graph/neighbors?node={highest_pagerank}&depth=1`
2. Centers on the highest-PageRank model (Account in admin's case)
3. Shows depth 1: `belongs_to` on left, `has_many` (first group) on right
4. Background fetch of full graph begins
5. User explores from there

---

## Future Phase: Clusters

Domain cluster visualization is deferred. The 61 domain clusters could become a scoped "show cluster" feature — selecting a cluster shows its ~30 member models in a focused view. This builds on the same column infrastructure but requires the cluster bugs to be resolved first. Not in scope for this spec.
