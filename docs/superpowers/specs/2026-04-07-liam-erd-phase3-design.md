# Liam ERD Phase 3: Performance & Focus Mode

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this spec.

## Context

Phase 2 added non-model node types (controllers, jobs, services, mailers) with layer toggles and sidebar sections. A real-world Rails app produces 126 tables + 497 woods nodes — 624 total React Flow nodes across a 21K x 36K px canvas. This creates three problems:

1. **Performance** — 13K DOM nodes, multi-second ELK layout on layer toggle, 600+ sidebar items
2. **Information overload** — 52% of woods nodes (257/497) are disconnected, BuyerMailer alone is 1,898px tall with 68 members
3. **No way to isolate** — developers can't inspect a single model's neighborhood without visually scanning a massive graph

Phase 3 addresses all three with performance improvements and a Focus Mode for subgraph isolation.

## 1. Performance & Node Rendering

### 1.1 Member Cap with Expand/Collapse

Woods nodes display a capped list of members with an expand toggle.

- **Default cap:** 5 members visible
- **Overflow indicator:** "+N more" button at the bottom of the member list
- **Expand:** Clicking the button reveals all members; button text changes to "Show less"
- **Collapse:** Clicking "Show less" returns to the 5-member cap
- **State:** Local to each node instance — expanding BuyerMailer does not expand other nodes
- **Impact:** Reduces the tallest node from 1,898px (68 members) to ~180px (5 members + button). Dramatically reduces ELK layout area and DOM node count.

**Implementation:** Modify `WoodsNode.tsx` to slice `members` array at cap, render a toggle button. Use `useState` for local expand/collapse state.

### 1.2 Lazy Layer Creation

Only create React Flow nodes for enabled layers. Currently `convertSchemaToNodes` creates all 497 woods nodes regardless of layer state, then `filterNodesByLayers` removes them. This wastes time creating nodes that are immediately discarded.

- **Change:** Pass `nodeLayers` into `convertSchemaToNodes`
- **Behavior:** Skip the `schema.nodes` loop for disabled layers — zero React Flow node objects created for disabled layers
- **Effect:** With all layers OFF (default), initial render creates only 127 table nodes. Toggling "Controllers" ON creates 339 controller nodes + existing tables = 466 total, still cheaper than 624.
- **Combined with `layerKey`:** The ERDContent re-mount on layer toggle still applies, but now it re-mounts with fewer nodes, making ELK layout faster.

### 1.3 Disconnected Node Grouping

Nodes with zero dependencies float as visual noise and inflate ELK layout cost. 257 of 497 woods nodes (52%) have no dependencies.

- **Grouping:** Disconnected woods nodes are placed into a collapsible group node at the bottom of the layout, similar to how `nonRelatedTableGroup` handles FK-less tables
- **Default state:** Collapsed — the group shows a summary label like "257 disconnected nodes" but does not render individual nodes
- **Expand:** Clicking the group expands it, rendering the disconnected nodes inside
- **Filter integration:** Disconnected grouping respects layer toggles — if Controllers is OFF, disconnected controllers are not counted or shown
- **Impact:** Removes ~257 nodes from ELK layout computation when layers are enabled

**Implementation:** Add a `disconnected` boolean to each woods node in `convertSchemaToNodes` based on dependency count. Filter disconnected nodes into a separate group. Create a `DisconnectedGroup` component or reuse the `nonRelatedTableGroup` pattern.

### 1.4 Sidebar Sections Default Collapsed

The sidebar renders 623 items across 5 sections. Only the Tables section should be expanded by default.

- **Default state:** Tables section expanded; Controllers, Jobs, Services, Mailers sections collapsed
- **Interaction:** Click section header to expand/collapse
- **DOM impact:** Collapsed sections render only the header — no list items in the DOM until expanded
- **Counts:** Each section header shows item count: "Controllers (339)" even when collapsed

**Implementation:** Add a `defaultOpen` prop to `WoodsNodeGroup` (or use the existing `SidebarGroup` collapsible behavior). Pass `defaultOpen={false}` for woods sections.

## 2. Focus Mode v2 (Isolation)

Focus Mode lets developers isolate a subgraph around one or more nodes, hiding everything else. The primary use case is "show me everything that touches Account" — the Account table, its FK relationships, and all controllers/jobs/services that depend on it.

### 2.1 Focus Set State

- **State:** `focusedNodes: Set<string>` replaces `focusedNode: string | null` in `useLayerState`
- **Empty set:** Normal view — all nodes visible (subject to layer toggles)
- **Non-empty set:** Focus mode active — only focused nodes and their direct neighbors are visible
- **Neighbor definition (one hop):**
  - For a **table:** other tables connected by FK constraints + any woods nodes with a dependency targeting that table
  - For a **woods node:** tables it depends on + other woods nodes it depends on + woods nodes that depend on it
  - For **multi-select:** union of all neighborhoods

### 2.2 Entry Points

Four ways to enter focus mode:

1. **Sidebar click** — clicking a node in the sidebar sets it as the sole focused node (replaces current `setFocusedNode` behavior)
2. **Cmd+click on sidebar item** — adds/removes the node from the focus set without clearing existing selections
3. **Command palette** — selecting a node from the palette focuses on it; Cmd+Enter adds to the focus set
4. **Cmd+click on canvas node** — adds/removes from focus set

### 2.3 Focus Banner

The existing `FocusBanner` component is upgraded:

- **Visual prominence:** Colored background bar (not just text) — clearly signals a filtered view
- **Content:** "Showing N nodes connected to [chips]" — the count gives immediate context that this is filtered
- **Chips:** Each focused node rendered as a removable chip with an x button
- **Exit button:** "Exit focus" button — prominent, always visible
- **Keyboard:** Escape exits focus mode entirely
- **Example states:**
  - Single focus: "Showing 34 nodes connected to `[Account x]` `[Exit focus]`"
  - Multi focus: "Showing 51 nodes connected to `[Account x]` `[Order x]` `[Exit focus]`"

### 2.4 Sidebar Behavior in Focus Mode

The sidebar is **never filtered by focus mode.** This prevents users from being trapped without a way to see what exists.

- **Focused items:** Normal appearance
- **Unfocused items:** Greyed out / reduced opacity
- **Clicking a greyed-out item:** Switches focus to it (replaces focus set)
- **Cmd+clicking a greyed-out item:** Adds it to the focus set

### 2.5 URL Shareability

Focus state is serialized to URL query parameters:

- **Format:** `?focus=accounts,orders` (comma-separated node names)
- **On load:** If `?focus` param exists, initialize the focus set from it
- **On change:** Update the URL as the focus set changes (using `pushState` or the existing `nuqs` adapter)
- **Sharing:** Copy the URL to share a focused view — recipient sees the same isolated subgraph

### 2.6 Layout Behavior

- Focus mode triggers ELK layout on just the visible subgraph — typically 5-30 nodes, near-instant
- `fitView` auto-zooms to the focused subgraph so it fills the viewport
- Exiting focus mode triggers a full re-layout of all visible nodes

## 3. Command Palette Expansion

### 3.1 Woods Node Search

Add a `WoodsNodeOptions` component alongside the existing `TableOptions`:

- **Groups:** Results grouped by type — "Tables", "Controllers", "Jobs", "Services", "Mailers"
- **Appearance:** Each result shows a colored dot (from `woodsNodeColors`) + node name
- **Search:** Searches across all node types simultaneously — typing "Account" shows the `accounts` table, `AccountsController`, `AccountBumpGenerationWorker`, etc.
- **Selection:** Selecting a result enters focus mode on that node
- **Multi-select:** Cmd+Enter adds to focus set instead of replacing

### 3.2 Interaction Hints

The command palette should teach users about available interactions:

- **Footer bar** in the palette showing keyboard shortcuts:
  - `Enter` — Focus on selected node
  - `Cmd+Enter` — Add to focus set
  - `Esc` — Close palette
- **When focus is active:** A "Clear focus" command appears at the top of the palette results (above all groups)
- **Empty state:** When no search text is entered and focus is active, show the current focus set as removable chips at the top of the palette

### 3.3 Sidebar Interaction Hints

When hovering a sidebar item, show a subtle tooltip or inline hint:

- **Click** — Focus on this node
- **Cmd+Click** — Add to focus set

This tooltip should appear on first hover only (per session) or as a persistent subtle hint near the section headers, to avoid being annoying on repeated use.

## 4. Non-Goals (Future Work)

These are explicitly out of scope for Phase 3:

- **Virtual scrolling in sidebar** — collapsing sections solves the immediate DOM problem
- **Right-click context menu on canvas** — sidebar + palette + Cmd+click provide sufficient entry points
- **Neighbor depth > 1** — showing neighbors-of-neighbors adds complexity without clear UX benefit at this stage
- **Persisted focus sets** — bookmarks/saved views for reusable isolation states
- **Per-node hide/show toggles** — granular visibility control as an escape hatch
- **Canvas node click to focus** — regular click on canvas nodes continues to select/highlight (existing behavior); only Cmd+click enters focus mode to avoid conflicting with selection

## 5. Data Flow Summary

```
schema.json (Ruby SchemaGenerator)
  |
  v
Valibot safeParse (App.tsx)
  |
  v
convertSchemaToNodes(schema, showMode, nodeLayers)  <-- lazy: skips disabled layers
  |
  v
filterByFocus(nodes, edges, focusedNodes)  <-- multi-node focus set
  |
  v
ERDContent (key includes layerKey + focusKey for re-mount)
  |
  v
ELK layout (only visible nodes — fast in focus mode)
  |
  v
React Flow render
```

## 6. Files Affected

### New files:
- `WoodsNodeOptions.tsx` — command palette woods node search
- `DisconnectedGroup/` — collapsed group for dependency-less nodes (or extend `nonRelatedTableGroup`)

### Modified files:
- `convertSchemaToNodes.ts` — accept `nodeLayers`, skip disabled layers, mark disconnected nodes
- `useLayerState.ts` — `focusedNodes: Set<string>` replacing `focusedNode: string | null`
- `filterByLayers.ts` — update `filterByFocus` for multi-node focus set with neighbor resolution
- `WoodsNode.tsx` — member cap with expand/collapse
- `ErdRenderer.tsx` — pass `nodeLayers` to converter, include focus state in key, wire new entry points
- `FocusBanner.tsx` — multi-chip display, node count, colored bar
- `LeftPane.tsx` — collapsed defaults, greyed-out unfocused items, Cmd+click support
- `CommandPaletteContent.tsx` — render `WoodsNodeOptions` alongside `TableOptions`
- `CommandPalette.tsx` — footer hints bar, clear focus command
- `App.tsx` — read `?focus` URL param, initialize focus set
