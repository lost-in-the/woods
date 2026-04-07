# Liam ERD Phase 3: Performance & Focus Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve ERD performance for large datasets (600+ nodes) and add Focus Mode for subgraph isolation.

**Architecture:** Four independent performance improvements (member cap, lazy layers, disconnected grouping, sidebar collapse) plus a Focus Mode v2 system that replaces single-node focus with multi-node `Set<string>` selection, one-hop neighbor visibility, URL shareability, and command palette expansion with woods node search.

**Tech Stack:** React, TypeScript, React Flow (`@xyflow/react`), cmdk command palette, CSS Modules, Valibot schema validation, ELK layout algorithm

**Spec:** `docs/superpowers/specs/2026-04-07-liam-erd-phase3-design.md`

---

## File Structure

### New files:
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/WoodsNodeOptions.tsx` — command palette search results for woods nodes (controllers, jobs, services, mailers)
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.tsx` — keyboard hints footer bar for the palette
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.module.css` — styles for footer

### Modified files:
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNodeMemberList.tsx` — member cap with expand/collapse
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNode.module.css` — styles for expand toggle
- `frontend/liam-erd/packages/erd-core/src/features/erd/utils/convertSchemaToNodes.ts` — accept `nodeLayers`, skip disabled layers, mark disconnected nodes
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx` — pass `nodeLayers` to converter, wire focus state, include focus key
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/useLayerState.ts` — `focusedNodes: Set<string>` replacing `focusedNode: string | null`
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/filterByLayers.ts` — multi-node `filterByFocus` with neighbor resolution
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/index.ts` — update exports
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.tsx` — multi-chip display, node count, colored bar
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.module.css` — updated banner styles
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.tsx` — collapsed defaults, greyed unfocused items, Cmd+click
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.module.css` — unfocused item styles
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteContent/CommandPaletteContent.tsx` — render `WoodsNodeOptions`, footer, clear focus command
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/index.ts` — export new component
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/types.ts` — add `'woods'` suggestion type
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/utils/suggestion.ts` — handle `'woods'` type
- `frontend/liam-erd/packages/cli/src/App.tsx` — read `?focus` URL param, initialize focus set

### Vendor rebuild:
- `vendor/assets/liam-erd/` — rebuilt after all frontend changes

---

## Task 1: Member Cap with Expand/Collapse on WoodsNode

Woods nodes with many members (up to 68) dominate the canvas. Cap the member list at 5 with an expand toggle.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNodeMemberList.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNode.module.css`

- [ ] **Step 1: Add expand/collapse state and member slicing to WoodsNodeMemberList**

Replace the contents of `WoodsNodeMemberList.tsx`:

```tsx
import type { WoodsNodeMember } from '@liam-hq/schema'
import { type FC, useState } from 'react'
import styles from './WoodsNode.module.css'

const MEMBER_CAP = 5

type Props = {
  members: WoodsNodeMember[]
}

export const WoodsNodeMemberList: FC<Props> = ({ members }) => {
  const [expanded, setExpanded] = useState(false)

  if (members.length === 0) {
    return null
  }

  const visibleMembers = expanded ? members : members.slice(0, MEMBER_CAP)
  const overflowCount = members.length - MEMBER_CAP

  return (
    <ul className={styles.memberList}>
      {visibleMembers.map((member) => (
        <li key={member.name} className={styles.memberItem}>
          {member.name}
        </li>
      ))}
      {overflowCount > 0 && (
        <li className={styles.memberToggle}>
          <button
            type="button"
            className={styles.memberToggleButton}
            onClick={() => setExpanded((prev) => !prev)}
          >
            {expanded ? 'Show less' : `+${overflowCount} more`}
          </button>
        </li>
      )}
    </ul>
  )
}
```

- [ ] **Step 2: Add styles for the member toggle button**

Append to the end of `WoodsNode.module.css`:

```css
.memberToggle {
  border-top: 1px solid var(--overlay-10);
}

.memberToggleButton {
  display: block;
  width: 100%;
  padding: var(--spacing-1) var(--spacing-2);
  font-size: var(--font-size-6);
  color: var(--overlay-40);
  background: none;
  border: none;
  cursor: pointer;
  text-align: left;
  transition: color 0.15s;
}

.memberToggleButton:hover {
  color: var(--overlay-70);
}
```

- [ ] **Step 3: Verify in browser**

Run: `cd frontend/liam-erd && pnpm run build`

Open the ERD in a browser, enable a layer (e.g., Controllers), and confirm:
- Nodes with >5 members show only 5 + a "+N more" button
- Clicking the button expands to show all members
- Clicking "Show less" collapses back to 5
- Nodes with <=5 members show no button

- [ ] **Step 4: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNodeMemberList.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNode.module.css
git commit -m "Add member cap with expand/collapse toggle to WoodsNode member list"
```

---

## Task 2: Lazy Layer Creation in convertSchemaToNodes

Currently `convertSchemaToNodes` creates all 497 woods nodes regardless of layer state. Pass `nodeLayers` in and skip disabled layers.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/utils/convertSchemaToNodes.ts`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx`

- [ ] **Step 1: Add `nodeLayers` parameter to `convertSchemaToNodes`**

In `convertSchemaToNodes.ts`, change the `Params` type and function signature. Find the existing type definition (around line 10-14) and add `nodeLayers`:

```ts
// At the top of the file, add import for NodeLayer type
import type { NodeLayer } from '../components/LayerToggle'
```

Then find the `Params` type and add the field:

```ts
type Params = {
  schema: Schema
  showMode: ShowMode
  nodeLayers?: Record<NodeLayer, boolean>
}
```

Update the function signature to destructure it:

```ts
export const convertSchemaToNodes = ({
  schema,
  showMode,
  nodeLayers,
}: Params): {
  nodes: Node[]
  edges: Edge[]
} => {
```

- [ ] **Step 2: Gate the woods node loop on layer state**

In `convertSchemaToNodes.ts`, find the woods node creation block (around lines 106-141). Wrap the inner loop to skip nodes whose layer is disabled. The existing code starts with:

```ts
  if (schema.nodes) {
    for (const [id, node] of Object.entries(schema.nodes)) {
```

Replace that block with:

```ts
  // Map woods node type to layer key
  const WOODS_TYPE_TO_LAYER: Record<string, NodeLayer> = {
    controller: 'controllers',
    job: 'jobs',
    service: 'services',
    mailer: 'mailers',
  }

  if (schema.nodes) {
    for (const [id, node] of Object.entries(schema.nodes)) {
      // Skip nodes whose layer is disabled (lazy creation)
      if (nodeLayers) {
        const layerKey = WOODS_TYPE_TO_LAYER[node.type]
        if (layerKey && !nodeLayers[layerKey]) continue
      }
```

The rest of the loop body (creating the ReactFlow node and dependency edges) stays the same.

- [ ] **Step 3: Pass `nodeLayers` from ErdRenderer**

In `ErdRenderer.tsx`, find the `convertSchemaToNodes` call (around line 86-89):

```ts
  const { nodes, edges } = convertSchemaToNodes({
    schema,
    showMode,
  })
```

Replace with:

```ts
  const { nodes, edges } = convertSchemaToNodes({
    schema,
    showMode,
    nodeLayers,
  })
```

Note: `nodeLayers` comes from `useLayerState()` which is called just below (line 91-98). Move the `useLayerState()` call **above** the `convertSchemaToNodes` call. The full reordered section becomes:

```ts
  const {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNode,
    setFocusedNode,
  } = useLayerState()

  const { nodes, edges } = convertSchemaToNodes({
    schema,
    showMode,
    nodeLayers,
  })
```

- [ ] **Step 4: Remove redundant `filterNodesByLayers` call**

Since `convertSchemaToNodes` now skips disabled layers, the `filterNodesByLayers` call is redundant for woods nodes but still needed for table visibility. However, `filterNodesByLayers` only filters woods nodes (tables always pass through), so it's now a no-op when `nodeLayers` is passed. Remove it to avoid confusion:

In `ErdRenderer.tsx`, replace:

```ts
  const filteredNodes = useMemo(
    () => filterNodesByLayers(nodes, nodeLayers),
    [nodes, nodeLayers],
  )
  const visibleNodeIds = useMemo(
    () => new Set(filteredNodes.map((n) => n.id)),
    [filteredNodes],
  )
```

With:

```ts
  const visibleNodeIds = useMemo(
    () => new Set(nodes.map((n) => n.id)),
    [nodes],
  )
```

And update the `filteredEdges` line to use `nodes` instead of the removed `filteredNodes`:

```ts
  const { nodes: visibleNodes, edges: visibleEdges } = useMemo(
    () => filterByFocus(nodes, filteredEdges, focusedNode),
    [nodes, filteredEdges, focusedNode],
  )
```

Also remove `filterNodesByLayers` from the import:

```ts
import {
  LayerToggleDropdown,
  filterByFocus,
  filterEdgesByLayers,
  useLayerState,
} from '../LayerToggle'
```

- [ ] **Step 5: Verify and commit**

Run: `cd frontend/liam-erd && pnpm run build`

Confirm no build errors. In the browser: with all layers OFF, only table nodes render. Toggling Controllers ON should create controller nodes (and the component re-mounts via `layerKey`).

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/utils/convertSchemaToNodes.ts frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
git commit -m "Lazy layer creation: skip disabled layers in convertSchemaToNodes"
```

---

## Task 3: Disconnected Node Grouping

52% of woods nodes (257/497) have zero dependencies. Group them into a collapsible summary to reduce ELK layout cost.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/utils/convertSchemaToNodes.ts`

- [ ] **Step 1: Track which woods nodes have dependencies**

In `convertSchemaToNodes.ts`, after the woods node creation loop, add a pass to identify disconnected nodes. Find the end of the `if (schema.nodes)` block. After all woods nodes and edges are created, add:

```ts
  // Identify disconnected woods nodes (no edges at all)
  const connectedNodeIds = new Set<string>()
  for (const edge of edges) {
    connectedNodeIds.add(edge.source)
    connectedNodeIds.add(edge.target)
  }

  const WOODS_DISCONNECTED_GROUP_ID = 'woods-disconnected-group'
  let hasDisconnectedWoods = false

  for (const node of nodes) {
    if (node.type === 'woodsNode' && !connectedNodeIds.has(node.id)) {
      node.parentId = WOODS_DISCONNECTED_GROUP_ID
      hasDisconnectedWoods = true
    }
  }

  if (hasDisconnectedWoods) {
    nodes.push({
      id: WOODS_DISCONNECTED_GROUP_ID,
      type: 'nonRelatedTableGroup',
      data: {},
      position: { x: 0, y: 0 },
    })
  }
```

This reuses the existing `nonRelatedTableGroup` node type — it renders an empty container div, and ELK lays out children inside it. The ELK layout code in `convertNodesToElkNodes.ts` already handles parent-child grouping.

- [ ] **Step 2: Verify and commit**

Run: `cd frontend/liam-erd && pnpm run build`

In the browser: enable all layers. Disconnected woods nodes should cluster together in a group at the bottom of the layout, similar to how FK-less tables are grouped.

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/utils/convertSchemaToNodes.ts
git commit -m "Group disconnected woods nodes into collapsible layout group"
```

---

## Task 4: Sidebar Sections Default Collapsed

Woods sidebar sections render hundreds of items. Collapse them by default.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.tsx`

- [ ] **Step 1: Add collapsible behavior to WoodsNodeGroup**

In `LeftPane.tsx`, find the `WoodsNodeGroup` sub-component (lines 45-74). Replace it with a collapsible version:

```tsx
const WoodsNodeGroup: FC<{
  label: string
  nodeType: WoodsNodeType
  nodes: Node[]
  onFocusNode: (nodeId: string | null) => void
}> = ({ label, nodeType, nodes, onFocusNode }) => {
  const [isOpen, setIsOpen] = useState(false)

  return (
    <SidebarGroup>
      <SidebarGroupLabel
        className={styles.groupLabel}
        onClick={() => setIsOpen((prev) => !prev)}
        style={{ cursor: 'pointer' }}
      >
        <span>{label} ({nodes.length})</span>
      </SidebarGroupLabel>
      {isOpen && (
        <SidebarGroupContent>
          <SidebarMenu className={styles.tablesMenu}>
            {nodes.map((node) => (
              <SidebarMenuItem key={node.id}>
                <SidebarMenuButton
                  className={styles.button}
                  onClick={() => onFocusNode(node.id)}
                >
                  <span
                    className={styles.colorDot}
                    style={{ backgroundColor: woodsNodeColors[nodeType].border }}
                  />
                  <span>{String(node.data['name'])}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            ))}
          </SidebarMenu>
        </SidebarGroupContent>
      )}
    </SidebarGroup>
  )
}
```

Add `useState` to the existing React import at line 21 (it already imports `useCallback, useMemo` — add `useState`):

```ts
import { type FC, useCallback, useMemo, useState } from 'react'
```

- [ ] **Step 2: Verify and commit**

Run: `cd frontend/liam-erd && pnpm run build`

In the browser: when layers are enabled, sidebar sections for Controllers/Jobs/Services/Mailers should appear collapsed showing only the header with count. Clicking the header expands to show items. Tables section remains always expanded.

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.tsx
git commit -m "Collapse woods sidebar sections by default, show item count in header"
```

---

## Task 5: Focus Mode v2 — Multi-Node State in useLayerState

Replace single `focusedNode: string | null` with `focusedNodes: Set<string>` and add `toggleFocusedNode` for Cmd+click add/remove.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/useLayerState.ts`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/index.ts`

- [ ] **Step 1: Update the LayerState interface and implementation**

Replace the entire contents of `useLayerState.ts`:

```ts
import { useCallback, useState } from 'react'

export type NodeLayer = 'controllers' | 'jobs' | 'services' | 'mailers'
export type EdgeCategory = 'data' | 'dependency'

export interface LayerState {
  nodeLayers: Record<NodeLayer, boolean>
  edgeCategories: Record<EdgeCategory, boolean>
  toggleNodeLayer: (layer: NodeLayer) => void
  toggleEdgeCategory: (category: EdgeCategory) => void
  focusedNodes: Set<string>
  setFocusedNodes: (nodes: Set<string>) => void
  toggleFocusedNode: (nodeId: string) => void
}

const DEFAULT_NODE_LAYERS: Record<NodeLayer, boolean> = {
  controllers: false,
  jobs: false,
  services: false,
  mailers: false,
}

const DEFAULT_EDGE_CATEGORIES: Record<EdgeCategory, boolean> = {
  data: true,
  dependency: true,
}

export function useLayerState(): LayerState {
  const [nodeLayers, setNodeLayers] =
    useState<Record<NodeLayer, boolean>>(DEFAULT_NODE_LAYERS)
  const [edgeCategories, setEdgeCategories] = useState<
    Record<EdgeCategory, boolean>
  >(DEFAULT_EDGE_CATEGORIES)
  const [focusedNodes, setFocusedNodes] = useState<Set<string>>(new Set())

  const toggleNodeLayer = useCallback((layer: NodeLayer) => {
    setNodeLayers((prev) => ({ ...prev, [layer]: !prev[layer] }))
  }, [])

  const toggleEdgeCategory = useCallback((category: EdgeCategory) => {
    setEdgeCategories((prev) => ({ ...prev, [category]: !prev[category] }))
  }, [])

  const toggleFocusedNode = useCallback((nodeId: string) => {
    setFocusedNodes((prev) => {
      const next = new Set(prev)
      if (next.has(nodeId)) {
        next.delete(nodeId)
      } else {
        next.add(nodeId)
      }
      return next
    })
  }, [])

  return {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNodes,
    setFocusedNodes,
    toggleFocusedNode,
  }
}
```

- [ ] **Step 2: Update exports in index.ts**

In `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/index.ts`, the exports are fine as-is — the type `LayerState` is re-exported and will pick up the new shape automatically.

- [ ] **Step 3: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/useLayerState.ts
git commit -m "Replace focusedNode with multi-node focusedNodes Set in useLayerState"
```

---

## Task 6: Multi-Node filterByFocus with Neighbor Resolution

Update `filterByFocus` to accept a `Set<string>` and compute the union of all one-hop neighborhoods.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/filterByLayers.ts`

- [ ] **Step 1: Rewrite filterByFocus for multi-node support**

In `filterByLayers.ts`, replace the `filterByFocus` function (lines 23-42):

```ts
export function filterByFocus(
  nodes: Node[],
  edges: Edge[],
  focusedNodes: Set<string>,
): { nodes: Node[]; edges: Edge[] } {
  if (focusedNodes.size === 0) return { nodes, edges }

  // Compute union of one-hop neighborhoods for all focused nodes
  const visibleIds = new Set<string>(focusedNodes)
  for (const edge of edges) {
    if (focusedNodes.has(edge.source)) visibleIds.add(edge.target)
    if (focusedNodes.has(edge.target)) visibleIds.add(edge.source)
  }

  return {
    nodes: nodes.filter((node) => visibleIds.has(node.id)),
    edges: edges.filter(
      (edge) => visibleIds.has(edge.source) && visibleIds.has(edge.target),
    ),
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/filterByLayers.ts
git commit -m "Update filterByFocus for multi-node focus set with neighbor union"
```

---

## Task 7: Wire Multi-Node Focus into ErdRenderer

Update `ErdRenderer.tsx` to use the new multi-node focus API and include a `focusKey` in the ERDContent key.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx`

- [ ] **Step 1: Update destructuring from useLayerState**

In `ErdRenderer.tsx`, find the `useLayerState()` destructuring (moved in Task 2). Replace:

```ts
  const {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNode,
    setFocusedNode,
  } = useLayerState()
```

With:

```ts
  const {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNodes,
    setFocusedNodes,
    toggleFocusedNode,
  } = useLayerState()
```

- [ ] **Step 2: Update filterByFocus call**

Replace:

```ts
  const { nodes: visibleNodes, edges: visibleEdges } = useMemo(
    () => filterByFocus(nodes, filteredEdges, focusedNode),
    [nodes, filteredEdges, focusedNode],
  )
```

With:

```ts
  const { nodes: visibleNodes, edges: visibleEdges } = useMemo(
    () => filterByFocus(nodes, filteredEdges, focusedNodes),
    [nodes, filteredEdges, focusedNodes],
  )
```

- [ ] **Step 3: Add focusKey to ERDContent key**

Find the `layerKey` useMemo and add a `focusKey` after it:

```ts
  const focusKey = useMemo(
    () => Array.from(focusedNodes).sort().join(','),
    [focusedNodes],
  )
```

Update the ERDContent key:

```tsx
<ERDContent
  key={`${schemaKey}-${showMode}-${layerKey}-${focusKey}`}
  nodes={visibleNodes}
  edges={visibleEdges}
  displayArea="main"
/>
```

- [ ] **Step 4: Create a setFocusedNode wrapper for sidebar compatibility**

The LeftPane currently calls `onFocusNode(nodeId)` which sets a single node. Create a callback that replaces the focus set:

```ts
  const handleFocusNode = useCallback(
    (nodeId: string | null) => {
      setFocusedNodes(nodeId ? new Set([nodeId]) : new Set())
    },
    [setFocusedNodes],
  )
```

- [ ] **Step 5: Update FocusBanner and LeftPane props**

Replace the FocusBanner rendering:

```tsx
{focusedNodes.size > 0 && (
  <FocusBanner
    focusedNodes={focusedNodes}
    onRemoveNode={(nodeId) => {
      const next = new Set(focusedNodes)
      next.delete(nodeId)
      setFocusedNodes(next)
    }}
    onExitFocus={() => setFocusedNodes(new Set())}
  />
)}
```

Update the LeftPane props:

```tsx
<LeftPane
  onFocusNode={handleFocusNode}
  onToggleFocusNode={toggleFocusedNode}
  focusedNodes={focusedNodes}
  nodeLayers={nodeLayers}
/>
```

- [ ] **Step 6: Add Escape key handler to exit focus mode**

Add a `useEffect` in `ERDRenderer` for the Escape key:

```ts
  useEffect(() => {
    const down = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && focusedNodes.size > 0) {
        setFocusedNodes(new Set())
      }
    }
    document.addEventListener('keydown', down)
    return () => document.removeEventListener('keydown', down)
  }, [focusedNodes, setFocusedNodes])
```

Add `useEffect` to the existing React import.

- [ ] **Step 7: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
git commit -m "Wire multi-node focus state into ErdRenderer with focusKey and Escape handler"
```

---

## Task 8: Upgrade FocusBanner for Multi-Node Display

Replace the single-node banner with a multi-chip display showing node count and removable chips.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.module.css`

- [ ] **Step 1: Rewrite FocusBanner component**

Replace the entire contents of `FocusBanner.tsx`:

```tsx
import { Scan, X } from '@liam-hq/ui'
import type { FC } from 'react'
import styles from './FocusBanner.module.css'

type Props = {
  focusedNodes: Set<string>
  onRemoveNode: (nodeId: string) => void
  onExitFocus: () => void
}

export const FocusBanner: FC<Props> = ({
  focusedNodes,
  onRemoveNode,
  onExitFocus,
}) => {
  const nodeList = Array.from(focusedNodes)

  return (
    <div className={styles.banner}>
      <Scan width={14} height={14} />
      <span className={styles.label}>
        Showing nodes connected to
      </span>
      <div className={styles.chips}>
        {nodeList.map((nodeId) => {
          const displayName = nodeId.replace(/^woods-/, '')
          return (
            <span key={nodeId} className={styles.chip}>
              {displayName}
              <button
                type="button"
                className={styles.chipRemove}
                onClick={() => onRemoveNode(nodeId)}
                aria-label={`Remove ${displayName} from focus`}
              >
                <X width={10} height={10} />
              </button>
            </span>
          )
        })}
      </div>
      <button
        type="button"
        className={styles.exitButton}
        onClick={onExitFocus}
        aria-label="Exit focus mode"
      >
        Exit focus
      </button>
    </div>
  )
}
```

- [ ] **Step 2: Update FocusBanner styles**

Replace the entire contents of `FocusBanner.module.css`:

```css
.banner {
  position: absolute;
  top: 12px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 10;
  display: flex;
  align-items: center;
  gap: var(--spacing-2);
  padding: var(--spacing-1) var(--spacing-3);
  border-radius: var(--border-radius-md, 6px);
  background: var(--primary-accent, #6366f1);
  border: 1px solid color-mix(in srgb, var(--primary-accent, #6366f1) 80%, white);
  font-size: var(--font-size-2);
  color: #ffffff;
}

.label {
  white-space: nowrap;
}

.chips {
  display: flex;
  align-items: center;
  gap: var(--spacing-1);
  flex-wrap: wrap;
}

.chip {
  display: inline-flex;
  align-items: center;
  gap: var(--spacing-1);
  padding: 1px var(--spacing-2);
  border-radius: var(--border-radius-sm, 4px);
  background: rgba(255, 255, 255, 0.2);
  font-weight: 500;
  font-size: var(--font-size-2);
}

.chipRemove {
  display: inline-flex;
  align-items: center;
  background: none;
  border: none;
  color: rgba(255, 255, 255, 0.7);
  cursor: pointer;
  padding: 0;
  line-height: 1;
}

.chipRemove:hover {
  color: #ffffff;
}

.exitButton {
  display: flex;
  align-items: center;
  gap: var(--spacing-1);
  background: rgba(255, 255, 255, 0.15);
  border: 1px solid rgba(255, 255, 255, 0.3);
  border-radius: var(--border-radius-sm, 4px);
  color: #ffffff;
  padding: 2px var(--spacing-2);
  cursor: pointer;
  font-size: var(--font-size-1);
  white-space: nowrap;
  transition: background 0.15s;
}

.exitButton:hover {
  background: rgba(255, 255, 255, 0.25);
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/FocusBanner/FocusBanner.module.css
git commit -m "Upgrade FocusBanner to multi-chip display with removable nodes and colored bar"
```

---

## Task 9: Sidebar Focus Mode Behavior — Greyed Unfocused Items and Cmd+Click

Update the LeftPane to show greyed-out items when focus mode is active, and support Cmd+click to add to focus set.

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.module.css`

- [ ] **Step 1: Update LeftPane Props**

In `LeftPane.tsx`, update the Props type (around line 76-79):

```ts
type Props = {
  onFocusNode: (nodeId: string | null) => void
  onToggleFocusNode: (nodeId: string) => void
  focusedNodes: Set<string>
  nodeLayers: Record<NodeLayer, boolean>
}
```

Update the component signature:

```ts
export const LeftPane = ({ onFocusNode, onToggleFocusNode, focusedNodes, nodeLayers }: Props) => {
```

- [ ] **Step 2: Update WoodsNodeGroup to handle focus state**

Replace the `WoodsNodeGroup` component with a version that supports focus styling and Cmd+click:

```tsx
const WoodsNodeGroup: FC<{
  label: string
  nodeType: WoodsNodeType
  nodes: Node[]
  onFocusNode: (nodeId: string | null) => void
  onToggleFocusNode: (nodeId: string) => void
  focusedNodes: Set<string>
}> = ({ label, nodeType, nodes, onFocusNode, onToggleFocusNode, focusedNodes }) => {
  const [isOpen, setIsOpen] = useState(false)
  const hasFocus = focusedNodes.size > 0

  return (
    <SidebarGroup>
      <SidebarGroupLabel
        className={styles.groupLabel}
        onClick={() => setIsOpen((prev) => !prev)}
        style={{ cursor: 'pointer' }}
      >
        <span>{label} ({nodes.length})</span>
      </SidebarGroupLabel>
      {isOpen && (
        <SidebarGroupContent>
          <SidebarMenu className={styles.tablesMenu}>
            {nodes.map((node) => {
              const isFocused = focusedNodes.has(node.id)
              return (
                <SidebarMenuItem key={node.id}>
                  <SidebarMenuButton
                    className={clsx(
                      styles.button,
                      hasFocus && !isFocused && styles.buttonUnfocused,
                    )}
                    onClick={(e) => {
                      if (e.metaKey || e.ctrlKey) {
                        onToggleFocusNode(node.id)
                      } else {
                        onFocusNode(node.id)
                      }
                    }}
                  >
                    <span
                      className={styles.colorDot}
                      style={{ backgroundColor: woodsNodeColors[nodeType].border }}
                    />
                    <span>{String(node.data['name'])}</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              )
            })}
          </SidebarMenu>
        </SidebarGroupContent>
      )}
    </SidebarGroup>
  )
}
```

Add `clsx` to the imports at the top of the file:

```ts
import clsx from 'clsx'
```

- [ ] **Step 3: Update TableNameMenuButton focus handling in the table section**

In the table section of the LeftPane (around line 227-235), update the `TableNameMenuButton` to also pass focus-awareness. Find the `onFocus` prop and update it to handle Cmd+click. Since `TableNameMenuButton` is a separate component, we'll wrap the click at the LeftPane level.

Find the section that renders `TableNameMenuButton` and wrap the `<SidebarMenuItem>` to add Cmd+click handling. However, since `TableNameMenuButton` is a separate component with its own click handling, the simplest approach is to add focus state to the parent container. Update the rendering loop:

In the section mapping `tableNodes` (around line 227), add a class based on focus state:

```tsx
{tableNodes.map((node) => (
  <div
    key={node.id}
    className={clsx(
      focusedNodes.size > 0 && !focusedNodes.has(node.id) && styles.buttonUnfocused,
    )}
  >
    <TableNameMenuButton
      node={node}
      nodes={tableNodes}
      showSelectedTables={showSelectedTables}
      onFocus={onFocusNode}
    />
  </div>
))}
```

- [ ] **Step 4: Pass new props to WoodsNodeGroup in the render section**

Find where `WoodsNodeGroup` is rendered (around line 257-268) and update:

```tsx
{WOODS_SECTIONS.map(({ layer, label, nodeType }) => {
  const sectionNodes = woodsNodesByType[nodeType] ?? []
  if (!nodeLayers[layer] || sectionNodes.length === 0) return null
  return (
    <WoodsNodeGroup
      key={layer}
      label={label}
      nodeType={nodeType}
      nodes={sectionNodes}
      onFocusNode={onFocusNode}
      onToggleFocusNode={onToggleFocusNode}
      focusedNodes={focusedNodes}
    />
  )
})}
```

- [ ] **Step 5: Add unfocused style to CSS**

Append to `LeftPane.module.css`:

```css
.buttonUnfocused {
  opacity: 0.4;
  transition: opacity 0.15s;
}

.buttonUnfocused:hover {
  opacity: 0.7;
}
```

- [ ] **Step 6: Add sidebar interaction hint tooltip**

Per spec section 3.3, show a subtle hint on first hover of a sidebar item. Add a CSS tooltip to the `WoodsNodeGroup` button. In `LeftPane.module.css`, append:

```css
.button[title]::after {
  content: attr(title);
  position: absolute;
  left: 100%;
  top: 50%;
  transform: translateY(-50%);
  margin-left: var(--spacing-1);
  padding: 2px var(--spacing-2);
  border-radius: var(--border-radius-sm);
  background: var(--pane-background, #1e1e2e);
  border: 1px solid var(--global-border);
  color: var(--overlay-50);
  font-size: var(--font-size-1);
  white-space: nowrap;
  pointer-events: none;
  opacity: 0;
  transition: opacity 0.15s;
  z-index: 10;
}

.button[title]:hover::after {
  opacity: 1;
}
```

In the `WoodsNodeGroup` component, add a `title` attribute to the `SidebarMenuButton`:

```tsx
<SidebarMenuButton
  className={clsx(
    styles.button,
    hasFocus && !isFocused && styles.buttonUnfocused,
  )}
  title="Click to focus \u00b7 \u2318+Click to add"
  onClick={(e) => {
```

The native `title` attribute provides a built-in tooltip on hover. The CSS `::after` pseudo-element provides a styled version that appears faster.

- [ ] **Step 7: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/LeftPane/LeftPane.module.css
git commit -m "Add focus mode styling, Cmd+click multi-select, and interaction hints to sidebar"
```

---

## Task 10: Command Palette — Woods Node Search

Add a `WoodsNodeOptions` component to the command palette so users can search and focus on woods nodes (controllers, jobs, services, mailers).

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/WoodsNodeOptions.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/index.ts`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/types.ts`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/utils/suggestion.ts`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteContent/CommandPaletteContent.tsx`

- [ ] **Step 1: Extend the suggestion type system**

In `types.ts`, add `'woods'` as a suggestion type:

```ts
export type CommandPaletteInputMode = { type: 'default' } | { type: 'command' }

export type CommandPaletteSuggestion =
  | { type: 'table'; name: string }
  | { type: 'command'; name: string }
  | { type: 'woods'; name: string }
```

In `suggestion.ts`, update `textToSuggestion` to handle the new type:

```ts
export const textToSuggestion = (
  text: string,
): CommandPaletteSuggestion | null => {
  const words = text.split(SEPARATOR)

  const [suggestionType, name] = words
  if (!suggestionType || !name) return null

  if (
    suggestionType === 'table' ||
    suggestionType === 'command' ||
    suggestionType === 'woods'
  )
    return { type: suggestionType, name }

  return null
}
```

- [ ] **Step 2: Create WoodsNodeOptions component**

Create `WoodsNodeOptions.tsx`:

```tsx
import { Command } from 'cmdk'
import type { FC } from 'react'
import { woodsNodeColors } from '@/features/erd/components/ERDContent/components/WoodsNode'
import { useSchemaOrThrow } from '@/stores'
import { getSuggestionText } from '../utils'
import styles from './CommandPaletteOptions.module.css'

type Props = {
  onSelectNode: (nodeId: string) => void
}

const WOODS_GROUPS: {
  type: string
  label: string
}[] = [
  { type: 'controller', label: 'Controllers' },
  { type: 'job', label: 'Jobs' },
  { type: 'service', label: 'Services' },
  { type: 'mailer', label: 'Mailers' },
]

export const WoodsNodeOptions: FC<Props> = ({ onSelectNode }) => {
  const schema = useSchemaOrThrow()
  const nodes = schema.current.nodes

  if (!nodes) return null

  const nodeEntries = Object.entries(nodes)
  if (nodeEntries.length === 0) return null

  return (
    <>
      {WOODS_GROUPS.map(({ type, label }) => {
        const groupNodes = nodeEntries.filter(([, n]) => n.type === type)
        if (groupNodes.length === 0) return null

        const colors = woodsNodeColors[type as keyof typeof woodsNodeColors]

        return (
          <Command.Group key={type} heading={label}>
            {groupNodes.map(([id, node]) => (
              <Command.Item
                key={id}
                value={getSuggestionText({ type: 'woods', name: id })}
                onSelect={() => onSelectNode(`woods-${id}`)}
              >
                <a className={styles.item}>
                  <span
                    style={{
                      width: 8,
                      height: 8,
                      borderRadius: '50%',
                      backgroundColor: colors?.border ?? 'var(--overlay-40)',
                      flexShrink: 0,
                      marginRight: 'var(--spacing-2)',
                    }}
                  />
                  <span className={styles.itemText}>{node.name}</span>
                </a>
              </Command.Item>
            ))}
          </Command.Group>
        )
      })}
    </>
  )
}
```

- [ ] **Step 3: Export from index**

In `CommandPaletteOptions/index.ts`, add:

```ts
export * from './CommandOptions'
export * from './TableOptions'
export * from './WoodsNodeOptions'
```

- [ ] **Step 4: Wire into CommandPaletteContent**

In `CommandPaletteContent.tsx`, the challenge is that `WoodsNodeOptions` needs `onSelectNode` which triggers focus mode, but `CommandPaletteContent` doesn't currently have access to the focus state. We need to pass it through the CommandPalette context or via props.

The simplest approach: `WoodsNodeOptions` calls `onSelectNode` which is provided from `ErdRenderer` → `CommandPalette`. However, `CommandPalette` uses a Provider/Context pattern. Instead, let's use a callback through the existing `useCommandPaletteOrThrow()` context.

For now, the most pragmatic approach is to emit a custom event that `ErdRenderer` listens for. Add the `WoodsNodeOptions` to the content with a callback that dispatches a `CustomEvent`:

In `CommandPaletteContent.tsx`, add the import and render `WoodsNodeOptions`:

```tsx
import { TableOptions, WoodsNodeOptions } from '../CommandPaletteOptions'
```

Add a handler and render it alongside `TableOptions`:

```tsx
export const CommandPaletteContent: FC = () => {
  const { setOpen } = useCommandPaletteOrThrow()
  const [inputMode, setInputMode] = useState<CommandPaletteInputMode>({
    type: 'default',
  })

  const [suggestionText, setSuggestionText] = useState('')
  const suggestion = useMemo(
    () => textToSuggestion(suggestionText),
    [suggestionText],
  )

  const handleFocusNode = useCallback(
    (nodeId: string) => {
      window.dispatchEvent(
        new CustomEvent('erd:focus-node', { detail: { nodeId } }),
      )
      setOpen(false)
    },
    [setOpen],
  )

  return (
    <Command
      value={suggestionText}
      onValueChange={(v) => setSuggestionText(v)}
      filter={commandPaletteFilter}
    >
      <div className={styles.searchContainer}>
        <CommandPaletteSearchInput
          mode={inputMode}
          setMode={setInputMode}
          onBlur={(event) => event.target.focus()}
        />
        <DialogClose asChild>
          <Button
            size="xs"
            variant="outline-secondary"
            className={styles.escButton}
          >
            ESC
          </Button>
        </DialogClose>
      </div>
      <div className={styles.main}>
        <Command.List>
          <Command.Empty>No results found.</Command.Empty>
          {inputMode.type === 'default' && (
            <>
              <TableOptions suggestion={suggestion} />
              <WoodsNodeOptions onSelectNode={handleFocusNode} />
            </>
          )}
          {
            (inputMode.type === 'default' || inputMode.type === 'command') &&
              null
          }
        </Command.List>
        <div
          className={styles.previewContainer}
          data-testid="CommandPalettePreview"
        >
          {suggestion?.type === 'table' && (
            <TablePreview tableName={suggestion.name} />
          )}
          {
            suggestion?.type === 'command' && null
          }
        </div>
      </div>
    </Command>
  )
}
```

Add `useCallback` to the React import:

```ts
import { type FC, useCallback, useMemo, useState } from 'react'
```

- [ ] **Step 5: Listen for the custom events in ErdRenderer**

In `ErdRenderer.tsx`, add a `useEffect` to listen for both `erd:focus-node` (replace) and `erd:toggle-focus-node` (add/remove) events:

```ts
  useEffect(() => {
    const handleFocus = (e: Event) => {
      const detail = (e as CustomEvent<{ nodeId: string }>).detail
      setFocusedNodes(new Set([detail.nodeId]))
    }
    const handleToggle = (e: Event) => {
      const detail = (e as CustomEvent<{ nodeId: string }>).detail
      toggleFocusedNode(detail.nodeId)
    }
    window.addEventListener('erd:focus-node', handleFocus)
    window.addEventListener('erd:toggle-focus-node', handleToggle)
    return () => {
      window.removeEventListener('erd:focus-node', handleFocus)
      window.removeEventListener('erd:toggle-focus-node', handleToggle)
    }
  }, [setFocusedNodes, toggleFocusedNode])
```

- [ ] **Step 6: Add Cmd+Enter support for multi-select in command palette**

In `CommandPaletteContent.tsx`, update `handleFocusNode` to dispatch a different event based on modifier keys. But since `onSelect` from cmdk doesn't pass the keyboard event, we need to track the modifier key state. Add a keydown listener in `CommandPaletteContent`:

```tsx
  const handleFocusNode = useCallback(
    (nodeId: string) => {
      window.dispatchEvent(
        new CustomEvent('erd:focus-node', { detail: { nodeId } }),
      )
      setOpen(false)
    },
    [setOpen],
  )

  const handleToggleFocusNode = useCallback(
    (nodeId: string) => {
      window.dispatchEvent(
        new CustomEvent('erd:toggle-focus-node', { detail: { nodeId } }),
      )
      setOpen(false)
    },
    [setOpen],
  )
```

Pass both callbacks to `WoodsNodeOptions`:

```tsx
<WoodsNodeOptions
  onSelectNode={handleFocusNode}
  onToggleNode={handleToggleFocusNode}
/>
```

Update `WoodsNodeOptions` props and add keyboard handling for Cmd+Enter:

```tsx
type Props = {
  onSelectNode: (nodeId: string) => void
  onToggleNode: (nodeId: string) => void
}

export const WoodsNodeOptions: FC<Props> = ({ onSelectNode, onToggleNode }) => {
```

In the `Command.Item`, the `onSelect` callback fires on Enter. To detect Cmd+Enter, track a ref for the meta key state:

```tsx
// At the top of WoodsNodeOptions component:
const metaKeyRef = useRef(false)

useEffect(() => {
  const down = (e: KeyboardEvent) => { metaKeyRef.current = e.metaKey || e.ctrlKey }
  const up = (e: KeyboardEvent) => { metaKeyRef.current = e.metaKey || e.ctrlKey }
  document.addEventListener('keydown', down)
  document.addEventListener('keyup', up)
  return () => {
    document.removeEventListener('keydown', down)
    document.removeEventListener('keyup', up)
  }
}, [])
```

Then in `onSelect`:

```tsx
<Command.Item
  key={id}
  value={getSuggestionText({ type: 'woods', name: id })}
  onSelect={() => {
    const nodeId = `woods-${id}`
    if (metaKeyRef.current) {
      onToggleNode(nodeId)
    } else {
      onSelectNode(nodeId)
    }
  }}
>
```

Add `useRef, useEffect` to the React import.

- [ ] **Step 6: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/WoodsNodeOptions.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteOptions/index.ts frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/types.ts frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/utils/suggestion.ts frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteContent/CommandPaletteContent.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
git commit -m "Add woods node search to command palette with focus mode integration"
```

---

## Task 11: Command Palette Footer with Keyboard Hints

Add a footer bar to the command palette showing available keyboard shortcuts.

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.tsx`
- Create: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.module.css`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteContent/CommandPaletteContent.tsx`

- [ ] **Step 1: Create the footer component**

Create `CommandPaletteFooter.tsx`:

```tsx
import type { FC } from 'react'
import styles from './CommandPaletteFooter.module.css'

export const CommandPaletteFooter: FC = () => {
  return (
    <div className={styles.footer}>
      <span className={styles.hint}>
        <kbd className={styles.key}>Enter</kbd>
        <span>Focus</span>
      </span>
      <span className={styles.hint}>
        <kbd className={styles.key}>&#8984;Enter</kbd>
        <span>Add to focus</span>
      </span>
      <span className={styles.hint}>
        <kbd className={styles.key}>Esc</kbd>
        <span>Close</span>
      </span>
    </div>
  )
}
```

- [ ] **Step 2: Create footer styles**

Create `CommandPaletteFooter.module.css`:

```css
.footer {
  display: flex;
  align-items: center;
  gap: var(--spacing-4);
  padding: var(--spacing-2) var(--spacing-3);
  border-top: 1px solid var(--global-border);
  font-size: var(--font-size-1);
  color: var(--overlay-40);
}

.hint {
  display: inline-flex;
  align-items: center;
  gap: var(--spacing-1);
}

.key {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 20px;
  height: 18px;
  padding: 0 var(--spacing-1);
  border-radius: var(--border-radius-sm, 3px);
  background: var(--overlay-5);
  border: 1px solid var(--overlay-15);
  font-size: var(--font-size-1);
  font-family: var(--code-font);
  color: var(--overlay-50);
}
```

- [ ] **Step 3: Render footer in CommandPaletteContent**

In `CommandPaletteContent.tsx`, import and render the footer after the `<div className={styles.main}>` block:

```tsx
import { CommandPaletteFooter } from '../CommandPaletteFooter/CommandPaletteFooter'
```

Add just before the closing `</Command>` tag:

```tsx
      <CommandPaletteFooter />
    </Command>
```

- [ ] **Step 4: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.tsx frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteFooter/CommandPaletteFooter.module.css frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPaletteContent/CommandPaletteContent.tsx
git commit -m "Add keyboard hints footer to command palette"
```

---

## Task 12: URL Focus Shareability

Serialize focus state to `?focus=` URL param so focused views can be shared.

**Files:**
- Modify: `frontend/liam-erd/packages/cli/src/App.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx`
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/useLayerState.ts`

- [ ] **Step 1: Accept initial focus set in useLayerState**

In `useLayerState.ts`, add an optional parameter for initial state:

```ts
export function useLayerState(initialFocusedNodes?: Set<string>): LayerState {
  const [nodeLayers, setNodeLayers] =
    useState<Record<NodeLayer, boolean>>(DEFAULT_NODE_LAYERS)
  const [edgeCategories, setEdgeCategories] = useState<
    Record<EdgeCategory, boolean>
  >(DEFAULT_EDGE_CATEGORIES)
  const [focusedNodes, setFocusedNodes] = useState<Set<string>>(
    initialFocusedNodes ?? new Set(),
  )
```

- [ ] **Step 2: Sync focus state to URL in ErdRenderer**

In `ErdRenderer.tsx`, add a `useEffect` that updates the URL when `focusedNodes` changes:

```ts
  // Sync focus state to URL
  useEffect(() => {
    const url = new URL(window.location.href)
    if (focusedNodes.size > 0) {
      const names = Array.from(focusedNodes)
        .map((id) => id.replace(/^woods-/, ''))
        .join(',')
      url.searchParams.set('focus', names)
    } else {
      url.searchParams.delete('focus')
    }
    window.history.replaceState({}, '', url.toString())
  }, [focusedNodes])
```

- [ ] **Step 3: Parse `?focus` param on initial load in App.tsx**

In `App.tsx`, parse the URL param and pass it to `ERDRenderer`. Find the `loadSchemaContent` function area and add a focus parser:

```ts
function getInitialFocusFromURL(): Set<string> {
  const params = new URLSearchParams(window.location.search)
  const focusParam = params.get('focus')
  if (!focusParam) return new Set()

  return new Set(
    focusParam.split(',').map((name) => {
      // Table names don't have a prefix; woods nodes get 'woods-' prefix
      // We'll resolve this by trying both — the focus filter will simply
      // not match nodes that don't exist
      return name
    }),
  )
}
```

However, since `useLayerState` is called inside `ErdRenderer`, the simplest approach is to have `ErdRenderer` itself read the URL on mount. Move the URL parsing into `ErdRenderer`:

In `ErdRenderer.tsx`, before the `useLayerState` call, compute initial focus:

```ts
  const initialFocusedNodes = useMemo(() => {
    const params = new URLSearchParams(window.location.search)
    const focusParam = params.get('focus')
    if (!focusParam) return undefined

    return new Set(focusParam.split(','))
  }, [])
```

Pass to `useLayerState`:

```ts
  const {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNodes,
    setFocusedNodes,
    toggleFocusedNode,
  } = useLayerState(initialFocusedNodes)
```

- [ ] **Step 4: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/useLayerState.ts frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
git commit -m "Add URL focus shareability via ?focus= query parameter"
```

---

## Task 13: Build Vendor Assets and Final Verification

Rebuild the frontend bundle and copy to vendor for the Rails middleware to serve.

**Files:**
- Rebuild: `vendor/assets/liam-erd/`

- [ ] **Step 1: Build the frontend**

```bash
cd frontend/liam-erd && pnpm run build
```

Expected: Clean build with no errors.

- [ ] **Step 2: Copy build output to vendor**

```bash
rm -rf vendor/assets/liam-erd/*
cp -r frontend/liam-erd/packages/cli/dist/* vendor/assets/liam-erd/
```

- [ ] **Step 3: Verify in browser**

Start the Rails app with the ERD middleware, navigate to `/woods/erd/`. Verify:

1. **Member cap:** Enable Controllers layer → nodes with >5 members show "+N more" button, expand/collapse works
2. **Lazy layers:** Only table nodes on initial load. Enabling layers creates nodes (no redundant creation)
3. **Disconnected grouping:** Disconnected woods nodes cluster together in a group
4. **Sidebar collapse:** Woods sections show collapsed with count, expand on click
5. **Focus mode:** Click a sidebar item → only that node and neighbors visible. Cmd+click adds to focus set.
6. **FocusBanner:** Shows colored bar with removable chips. Exit button and Escape key work.
7. **Command palette:** `Cmd+K` → search shows Tables + Controllers/Jobs/Services/Mailers groups. Selecting a woods node enters focus mode.
8. **Footer hints:** Command palette shows keyboard shortcuts at bottom
9. **URL sharing:** Focus state reflected in `?focus=` param. Loading a URL with `?focus=accounts` enters focus mode.

- [ ] **Step 4: Commit vendor assets**

```bash
git add vendor/assets/liam-erd/
git commit -m "Rebuild vendor assets with Phase 3: performance improvements and focus mode"
```

---

## Dependency Order

Tasks 1-4 are independent performance improvements — they can be done in any order.

Tasks 5-6 must be done before Task 7 (state + filter before wiring).

Task 7 must be done before Tasks 8-9 (ErdRenderer wiring before banner/sidebar updates).

Task 10 depends on Task 7 (needs focus state wired).

Task 11 is independent of focus mode — can be done anytime after Task 10.

Task 12 depends on Task 7 (needs focus state).

Task 13 is always last.

```
Tasks 1, 2, 3, 4  (parallel — independent performance work)
  ↓
Tasks 5, 6  (sequential — state then filter)
  ↓
Task 7  (wiring)
  ↓
Tasks 8, 9, 10, 12  (parallel — all depend on Task 7)
  ↓
Task 11  (footer, depends on Task 10)
  ↓
Task 13  (build + verify)
```
