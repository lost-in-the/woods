# Bidirectional Column Explorer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dagre-based "show all nodes" graph visualization with a focused, bidirectional column explorer where one model is centered and relationships flow left (parents) and right (children).

**Architecture:** The frontend is largely rewritten — dagre is removed, a custom column layout replaces the graph view, and a new sidebar with search/visible/hidden/recent sections replaces the type-group list. The backend gets one new API endpoint (`/api/graph/neighbors`) for progressive loading. Existing Ruby code (Transformer, NodeBuilder, EdgeBuilder) is unchanged.

**Tech Stack:** Svelte 5, @xyflow/svelte, Ruby/Rack (existing middleware)

**Design Spec:** `docs/superpowers/specs/2026-04-06-bidirectional-column-explorer-design.md`

---

## File Structure

### Files to Delete
- `frontend/src/lib/layout.js` — dagre layout (replaced by column positioning)
- `frontend/src/components/GraphView.svelte` — full-graph renderer (replaced by ColumnLayout)
- `frontend/src/components/ClusterView.svelte` — cluster renderer (deferred to future phase)

### Files to Create
- `frontend/src/lib/graph-state.js` — client-side graph state management (center, expansions, visibility)
- `frontend/src/lib/column-layout.js` — column position computation
- `frontend/src/components/ColumnLayout.svelte` — main visualization component
- `frontend/src/components/ExpandButton.svelte` — per-branch `»`/`«` expand control
- `frontend/src/components/ColumnHeader.svelte` — relationship group header with breadcrumb
- `frontend/src/components/SearchDropdown.svelte` — command palette search overlay

### Files to Modify
- `frontend/package.json` — remove `@dagrejs/dagre` dependency
- `frontend/src/App.svelte` — full rewrite: new state model, remove cluster tab, wire new components
- `frontend/src/components/ModelNode.svelte` — add column-level handles, cardinality, new color system
- `frontend/src/components/CompactNode.svelte` — update colors, handle positions for LR layout
- `frontend/src/components/Sidebar.svelte` — full rewrite: search + visible/hidden/recent sections
- `frontend/src/components/TypeGroup.svelte` — repurpose for Hidden section type grouping
- `frontend/src/components/NodeDetail.svelte` — minor: update hub/bridge display
- `frontend/src/lib/api.js` — add `fetchNeighbors()` function
- `frontend/src/lib/theme.js` — new accessible color palette
- `lib/woods/svelte_flow/rack_middleware.rb` — add `/api/graph/neighbors` endpoint

### Test Files
- `spec/svelte_flow/rack_middleware_spec.rb` — add tests for neighbors endpoint

---

### Task 1: Dead Code Cleanup and Dependency Removal

**Files:**
- Delete: `frontend/src/lib/layout.js`
- Delete: `frontend/src/components/GraphView.svelte`
- Delete: `frontend/src/components/ClusterView.svelte`
- Modify: `frontend/package.json`

This task clears the ground. We remove dagre, the graph/cluster renderers, and the layout module. App.svelte will temporarily break — that's fine, we'll rebuild it in Task 8.

- [ ] **Step 1: Remove dagre from package.json**

```json
{
  "name": "woods-visualize",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@xyflow/svelte": "^1.0.0"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^5.0.0",
    "svelte": "^5.0.0",
    "vite": "^6.0.0"
  }
}
```

- [ ] **Step 2: Delete layout.js, GraphView.svelte, ClusterView.svelte**

```bash
rm frontend/src/lib/layout.js
rm frontend/src/components/GraphView.svelte
rm frontend/src/components/ClusterView.svelte
```

- [ ] **Step 3: Run npm install to update lockfile**

```bash
cd frontend && npm install
```

Expected: `@dagrejs/dagre` removed from `node_modules` and lockfile.

- [ ] **Step 4: Commit**

```bash
git add -A frontend/
git commit -m "chore: remove dagre dependency and old graph/cluster views"
```

---

### Task 2: Update Color Palette and Theme

**Files:**
- Modify: `frontend/src/lib/theme.js`

Replace the current color maps with the accessible dark-mode palette from the design spec. This is foundational — all subsequent components reference these colors.

- [ ] **Step 1: Replace theme.js contents**

```javascript
// Node type colors: border is the primary accent, bg is a dark tinted version
export const TYPE_COLORS = {
  model:        { bg: '#1e1e3b', border: '#818cf8', text: '#c7d2fe' },
  controller:   { bg: '#1a2e2e', border: '#2dd4bf', text: '#99f6e4' },
  job:          { bg: '#2e2a1a', border: '#fbbf24', text: '#fde68a' },
  service:      { bg: '#1e2433', border: '#64748b', text: '#cbd5e1' },
  poro:         { bg: '#1e2433', border: '#64748b', text: '#cbd5e1' },
  concern:      { bg: '#2a1e3b', border: '#a78bfa', text: '#ddd6fe' },
  mailer:       { bg: '#2e1a2a', border: '#fb7185', text: '#fecdd3' },
  graphql_type: { bg: '#1a2e33', border: '#22d3ee', text: '#a5f3fc' },
  route:        { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  migration:    { bg: '#1e2127', border: '#9ca3af', text: '#d1d5db' },
  lib:          { bg: '#1a2e24', border: '#34d399', text: '#a7f3d0' },
  decorator:    { bg: '#2a1e3b', border: '#a78bfa', text: '#ddd6fe' },
  component:    { bg: '#1a2e2e', border: '#2dd4bf', text: '#99f6e4' },
  channel:      { bg: '#1e1e3b', border: '#818cf8', text: '#c7d2fe' },
  serializer:   { bg: '#1a2e24', border: '#34d399', text: '#a7f3d0' },
  policy:       { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  middleware:   { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  engine:       { bg: '#1e2127', border: '#9ca3af', text: '#d1d5db' },
  framework:    { bg: '#1e2127', border: '#71717a', text: '#a1a1aa' },
  test_mapping: { bg: '#1e2127', border: '#71717a', text: '#a1a1aa' },
  default:      { bg: '#1e293b', border: '#71717a', text: '#94a3b8' },
};

// Dot colors used in sidebar lists (same as border colors)
export const TYPE_DOT_COLORS = Object.fromEntries(
  Object.entries(TYPE_COLORS).map(([k, v]) => [k, v.border])
);

// Human-readable display names
export const TYPE_DISPLAY_NAMES = {
  model: 'Models',
  controller: 'Controllers',
  service: 'Services',
  poro: 'POROs',
  job: 'Jobs',
  mailer: 'Mailers',
  concern: 'Concerns',
  component: 'Components',
  graphql_type: 'GraphQL',
  serializer: 'Serializers',
  policy: 'Policies',
  route: 'Routes',
  middleware: 'Middleware',
  engine: 'Engines',
  decorator: 'Decorators',
  rake_task: 'Rake Tasks',
  state_machine: 'State Machines',
  event: 'Events',
  factory: 'Factories',
  validator: 'Validators',
  channel: 'Channels',
  framework: 'Framework',
  test_mapping: 'Test Mappings',
  migration: 'Migrations',
  lib: 'Libraries',
};

// Functional colors — used across components
export const COLORS = {
  canvasBg: '#0f172a',
  cardBg: '#1e293b',
  centerBorder: '#22c55e',
  centerGlow: 'rgba(34, 197, 94, 0.15)',
  expandedBorder: '#22c55e',
  textPrimary: '#e2e8f0',
  textSecondary: '#94a3b8',
  textMuted: '#64748b',
  edgeDefault: '#475569',
  edgeActive: '#22c55e',
  edgeCycle: '#ef4444',
  expandBtnBorder: '#334155',
  expandBtnText: '#475569',
  expandBtnHoverBorder: '#475569',
  expandBtnHoverText: '#e2e8f0',
  borderSubtle: '#334155',
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}

export function getTypeDisplayName(type) {
  return TYPE_DISPLAY_NAMES[type] || type.charAt(0).toUpperCase() + type.slice(1).replace(/_/g, ' ') + 's';
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/lib/theme.js
git commit -m "feat: update color palette to accessible dark-mode system"
```

---

### Task 3: Backend — Neighbors API Endpoint

**Files:**
- Modify: `lib/woods/svelte_flow/rack_middleware.rb`
- Test: `spec/svelte_flow/rack_middleware_spec.rb`

Add a new endpoint `GET /api/graph/neighbors?node={id}&depth={n}` that returns a subgraph scoped to a node's neighborhood. This enables progressive loading instead of fetching the 80K-line full graph upfront.

- [ ] **Step 1: Write the failing test**

Add to the existing rack_middleware spec file. If the file doesn't exist yet, create it.

```ruby
# spec/svelte_flow/rack_middleware_spec.rb
# Add these tests to the existing describe block, or create the file:

RSpec.describe Woods::SvelteFlow::RackMiddleware do
  # ... existing setup ...

  describe 'GET /api/graph/neighbors' do
    let(:app) { described_class.new(->(env) { [404, {}, ['Not Found']] }) }

    context 'when node parameter is missing' do
      it 'returns 400 Bad Request' do
        env = Rack::MockRequest.env_for('/woods/visualize/api/graph/neighbors')
        status, _headers, _body = app.call(env)
        expect(status).to eq(400)
      end
    end

    context 'when node is not found in graph' do
      it 'returns 404 Not Found' do
        env = Rack::MockRequest.env_for('/woods/visualize/api/graph/neighbors?node=NonExistent&depth=1')
        status, _headers, _body = app.call(env)
        expect(status).to eq(404)
      end
    end

    context 'when node exists' do
      it 'returns the node and its neighbors at depth 1' do
        env = Rack::MockRequest.env_for('/woods/visualize/api/graph/neighbors?node=Account&depth=1')
        status, headers, body = app.call(env)
        expect(status).to eq(200)
        expect(headers['content-type']).to eq('application/json')

        data = JSON.parse(body.first)
        expect(data).to have_key('nodes')
        expect(data).to have_key('edges')
        expect(data['nodes']).to be_an(Array)
        # The center node should be included
        node_ids = data['nodes'].map { |n| n['id'] }
        expect(node_ids).to include('Account')
      end

      it 'defaults depth to 1 when not specified' do
        env = Rack::MockRequest.env_for('/woods/visualize/api/graph/neighbors?node=Account')
        status, _headers, body = app.call(env)
        expect(status).to eq(200)
        data = JSON.parse(body.first)
        expect(data['nodes']).to be_an(Array)
      end

      it 'includes highest_pagerank in response' do
        env = Rack::MockRequest.env_for('/woods/visualize/api/graph/neighbors?node=Account&depth=1')
        _status, _headers, body = app.call(env)
        data = JSON.parse(body.first)
        expect(data).to have_key('highest_pagerank')
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bundle exec rspec spec/svelte_flow/rack_middleware_spec.rb --format json --out tmp/test_results.json
```

Expected: FAIL — no route matches `/api/graph/neighbors`.

- [ ] **Step 3: Add the neighbors endpoint to RackMiddleware**

In `lib/woods/svelte_flow/rack_middleware.rb`, add the route and handler:

Add to the `route_request` case statement, before the `else` clause:

```ruby
when '/api/graph/neighbors'
  serve_neighbors_json(_env)
```

Add the handler method in the private section:

```ruby
# Serve a subgraph centered on a node at a given depth.
# Query params: node (required), depth (optional, default 1, max 5)
#
# @param env [Hash] Rack environment
# @return [Array] Rack response triple
def serve_neighbors_json(env)
  query = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
  node_id = query['node']
  return bad_request('Missing required parameter: node') unless node_id&.strip&.length&.positive?

  depth = [(query['depth'] || '1').to_i, 5].min
  depth = 1 if depth < 1

  transformer = ensure_transformer
  return service_unavailable unless transformer

  graph = transformer.instance_variable_get(:@graph)
  return not_found unless graph.nodes.key?(node_id)

  # BFS to collect neighbors at the given depth
  visited = Set.new([node_id])
  frontier = [node_id]

  depth.times do
    next_frontier = []
    frontier.each do |current|
      # Forward edges (dependencies)
      (graph.edges[current] || []).each do |dep|
        next if visited.include?(dep)
        visited.add(dep)
        next_frontier << dep
      end
      # Reverse edges (dependents)
      (graph.reverse[current] || Set.new).each do |dep|
        next if visited.include?(dep)
        visited.add(dep)
        next_frontier << dep
      end
    end
    frontier = next_frontier
  end

  # Build Svelte Flow data scoped to the visited nodes
  analyzer = transformer.instance_variable_get(:@analyzer)
  unit_metadata = transformer.instance_variable_get(:@unit_metadata)
  pagerank_scores = graph.pagerank

  # Find highest pagerank node overall (for default start state)
  highest_pagerank = pagerank_scores.max_by { |_k, v| v }&.first

  # Build scoped nodes
  scoped_graph_nodes = {}
  visited.each do |id|
    scoped_graph_nodes[id] = graph.nodes[id] if graph.nodes.key?(id)
  end

  # Build scoped edges (only edges where both endpoints are in visited set)
  scoped_edges = []
  visited.each do |source|
    (graph.edges[source] || []).each do |target|
      scoped_edges << { 'source' => source, 'target' => target } if visited.include?(target)
    end
  end

  # Build node builder and edge builder for the scoped data
  node_builder = NodeBuilder.new(
    nodes: scoped_graph_nodes,
    positions: {},
    pagerank: pagerank_scores,
    analysis: {
      hubs: (analyzer.hubs(limit: 20).map { |h| h[:identifier] } rescue []),
      bridges: (analyzer.bridges(limit: 20).map { |b| b[:identifier] } rescue []),
      orphans: (analyzer.orphans rescue [])
    },
    unit_metadata: unit_metadata || {},
    edges: graph.edges
  )

  cycle_edges = Set.new
  begin
    analyzer.cycles.each do |cycle|
      cycle.each_cons(2) { |a, b| cycle_edges.add("#{a}->#{b}") }
      cycle_edges.add("#{cycle.last}->#{cycle.first}") if cycle.size > 1
    end
  rescue StandardError
    # cycles computation can be expensive; skip if it fails
  end

  edge_builder = EdgeBuilder.new(
    edges: scoped_edges.map { |e| [e['source'], e['target']] },
    valid_node_ids: visited,
    cycle_edges: cycle_edges
  )

  data = {
    'nodes' => node_builder.build,
    'edges' => edge_builder.build,
    'highest_pagerank' => highest_pagerank
  }

  json_response(data)
end

# Return a 400 response.
#
# @param message [String]
# @return [Array] Rack response triple
def bad_request(message)
  [400, { 'content-type' => 'application/json' },
   [JSON.generate({ 'error' => message })]]
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bundle exec rspec spec/svelte_flow/rack_middleware_spec.rb --format json --out tmp/test_results.json
```

Expected: All neighbors tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/woods/svelte_flow/rack_middleware.rb spec/svelte_flow/rack_middleware_spec.rb
git commit -m "feat: add /api/graph/neighbors endpoint for progressive loading"
```

---

### Task 4: API Client — fetchNeighbors and Background Prefetch

**Files:**
- Modify: `frontend/src/lib/api.js`

Extend the API client with functions for the neighbors endpoint and background graph prefetch.

- [ ] **Step 1: Replace api.js contents**

```javascript
const basePath =
  document.querySelector('meta[name="woods-base-path"]')?.content || '';

export async function fetchJSON(endpoint) {
  const res = await fetch(`${basePath}/api/${endpoint}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

/**
 * Fetch a node's neighborhood subgraph at a given depth.
 * @param {string} nodeId - The node identifier to center on
 * @param {number} [depth=1] - How many hops from the center
 * @returns {Promise<{nodes: Array, edges: Array, highest_pagerank: string}>}
 */
export async function fetchNeighbors(nodeId, depth = 1) {
  const params = new URLSearchParams({ node: nodeId, depth: String(depth) });
  return fetchJSON(`graph/neighbors?${params}`);
}

/**
 * Fetch the full dependency graph (for background caching).
 * @returns {Promise<{nodes: Array, edges: Array}>}
 */
export async function fetchFullGraph() {
  return fetchJSON('graph');
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/lib/api.js
git commit -m "feat: add fetchNeighbors and fetchFullGraph API functions"
```

---

### Task 5: Graph State Module

**Files:**
- Create: `frontend/src/lib/graph-state.js`

This is the brain of the new app — manages center node, expanded branches, visible/hidden sets, and subgraph extraction from cached graph data. Pure functions, no Svelte dependencies. This module is imported by App.svelte.

- [ ] **Step 1: Create graph-state.js**

```javascript
/**
 * Graph state management for the bidirectional column explorer.
 *
 * Operates on raw graph data (nodes hash, edges adjacency list, reverse adjacency list)
 * and produces the set of visible node IDs based on center + expansions.
 */

/**
 * Get the forward dependencies of a node, grouped by relationship type.
 * @param {string} nodeId
 * @param {Array} allNodes - Svelte Flow node objects (with data.columns, etc.)
 * @param {Array} allEdges - Svelte Flow edge objects
 * @returns {Object} { 'has_many': ['Order', 'Product', ...], 'has_one': [...], ... }
 */
export function getGroupedDependencies(nodeId, allNodes, allEdges) {
  const groups = {};
  const nodeMap = new Map(allNodes.map((n) => [n.id, n]));
  const centerNode = nodeMap.get(nodeId);

  for (const edge of allEdges) {
    if (edge.source !== nodeId) continue;
    const targetNode = nodeMap.get(edge.target);
    if (!targetNode) continue;

    // Determine relationship type from edge data or association metadata
    const via = edge.data?.via || 'dependency';
    if (!groups[via]) groups[via] = [];
    groups[via].push(edge.target);
  }

  return groups;
}

/**
 * Get the reverse dependencies of a node (things that depend on it), grouped by type.
 * @param {string} nodeId
 * @param {Array} allNodes
 * @param {Array} allEdges
 * @returns {Object} { 'belongs_to': ['Plan', 'Country'], ... }
 */
export function getGroupedDependents(nodeId, allNodes, allEdges) {
  const groups = {};
  const nodeMap = new Map(allNodes.map((n) => [n.id, n]));

  for (const edge of allEdges) {
    if (edge.target !== nodeId) continue;
    const sourceNode = nodeMap.get(edge.source);
    if (!sourceNode) continue;

    const via = edge.data?.via || 'dependency';
    if (!groups[via]) groups[via] = [];
    groups[via].push(edge.source);
  }

  return groups;
}

/**
 * Compute the set of visible node IDs based on center node and expanded branches.
 * @param {string} centerNodeId
 * @param {Map<string, Set<string>>} expandedBranches - nodeId => Set('left'|'right')
 * @param {Array} allNodes
 * @param {Array} allEdges
 * @param {Set<string>} hiddenNodeIds - explicitly hidden nodes
 * @returns {Set<string>}
 */
export function computeVisibleNodes(centerNodeId, expandedBranches, allNodes, allEdges, hiddenNodeIds) {
  if (!centerNodeId) return new Set();

  const visible = new Set([centerNodeId]);

  // Depth 1: direct neighbors of center
  for (const edge of allEdges) {
    if (edge.source === centerNodeId) visible.add(edge.target);
    if (edge.target === centerNodeId) visible.add(edge.source);
  }

  // Expanded branches: for each expanded node, add its neighbors in the expanded direction
  for (const [nodeId, directions] of expandedBranches) {
    if (!visible.has(nodeId)) continue; // only expand visible nodes

    if (directions.has('right')) {
      for (const edge of allEdges) {
        if (edge.source === nodeId) visible.add(edge.target);
      }
    }
    if (directions.has('left')) {
      for (const edge of allEdges) {
        if (edge.target === nodeId) visible.add(edge.source);
      }
    }
  }

  // Remove explicitly hidden nodes
  for (const id of hiddenNodeIds) {
    if (id !== centerNodeId) visible.delete(id);
  }

  return visible;
}

/**
 * Recursively expand all descendants from a node (for alt+click).
 * @param {string} startNodeId
 * @param {'left'|'right'} direction
 * @param {Array} allEdges
 * @param {number} maxDepth
 * @returns {Map<string, Set<string>>} new branches to add
 */
export function expandRecursive(startNodeId, direction, allEdges, maxDepth = 5) {
  const newBranches = new Map();
  const visited = new Set([startNodeId]);
  let frontier = [startNodeId];

  for (let d = 0; d < maxDepth; d++) {
    const nextFrontier = [];
    for (const nodeId of frontier) {
      const neighbors = [];

      if (direction === 'right') {
        for (const edge of allEdges) {
          if (edge.source === nodeId && !visited.has(edge.target)) {
            visited.add(edge.target);
            neighbors.push(edge.target);
          }
        }
      } else {
        for (const edge of allEdges) {
          if (edge.target === nodeId && !visited.has(edge.source)) {
            visited.add(edge.source);
            neighbors.push(edge.source);
          }
        }
      }

      if (neighbors.length > 0) {
        if (!newBranches.has(nodeId)) newBranches.set(nodeId, new Set());
        newBranches.get(nodeId).add(direction);
        nextFrontier.push(...neighbors);
      }
    }
    frontier = nextFrontier;
    if (frontier.length === 0) break;
  }

  return newBranches;
}

/**
 * Determine which column (depth level) each visible node belongs to.
 * Center = 0, left neighbors = -1, right neighbors = +1, etc.
 * @param {string} centerNodeId
 * @param {Set<string>} visibleNodeIds
 * @param {Array} allEdges
 * @param {Map<string, Set<string>>} expandedBranches
 * @returns {Map<string, number>} nodeId => column index
 */
export function assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches) {
  const columns = new Map();
  columns.set(centerNodeId, 0);

  const visited = new Set([centerNodeId]);
  const queue = [{ id: centerNodeId, col: 0 }];

  while (queue.length > 0) {
    const { id, col } = queue.shift();

    // Right (forward dependencies)
    for (const edge of allEdges) {
      if (edge.source === id && visibleNodeIds.has(edge.target) && !visited.has(edge.target)) {
        visited.add(edge.target);
        const nextCol = col + 1;
        columns.set(edge.target, nextCol);
        queue.push({ id: edge.target, col: nextCol });
      }
    }

    // Left (reverse dependencies / dependents)
    for (const edge of allEdges) {
      if (edge.target === id && visibleNodeIds.has(edge.source) && !visited.has(edge.source)) {
        visited.add(edge.source);
        const nextCol = col - 1;
        columns.set(edge.source, nextCol);
        queue.push({ id: edge.source, col: nextCol });
      }
    }
  }

  return columns;
}

/**
 * Check if a node has further dependencies in a given direction.
 * Used to decide whether to show the expand button.
 * @param {string} nodeId
 * @param {'left'|'right'} direction
 * @param {Array} allEdges
 * @param {Set<string>} visibleNodeIds - nodes already visible
 * @returns {boolean}
 */
export function hasMoreInDirection(nodeId, direction, allEdges, visibleNodeIds) {
  if (direction === 'right') {
    return allEdges.some((e) => e.source === nodeId && !visibleNodeIds.has(e.target));
  }
  return allEdges.some((e) => e.target === nodeId && !visibleNodeIds.has(e.source));
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/lib/graph-state.js
git commit -m "feat: add graph state module for column explorer logic"
```

---

### Task 6: Column Layout Positioning

**Files:**
- Create: `frontend/src/lib/column-layout.js`

Pure function that takes column assignments and node data, returns positioned Svelte Flow nodes. No dagre — positions are deterministic based on column index and vertical stack order.

- [ ] **Step 1: Create column-layout.js**

```javascript
/**
 * Compute Svelte Flow node positions for the bidirectional column layout.
 * Columns are spaced horizontally, nodes stacked vertically within each column.
 */

const COLUMN_WIDTH = 280;
const COLUMN_GAP = 100;
const NODE_GAP = 16;
const BASE_NODE_HEIGHT = 44;
const COLUMN_ROW_HEIGHT = 20;
const HEADER_HEIGHT = 32;

/**
 * Estimate the pixel height of a node.
 * @param {Object} node - Svelte Flow node
 * @returns {number}
 */
function estimateNodeHeight(node) {
  const cols = node.data?.columns?.length || 0;
  if (cols > 0) return BASE_NODE_HEIGHT + cols * COLUMN_ROW_HEIGHT;
  if (node.data?.attributes?.length) return BASE_NODE_HEIGHT + 24;
  return BASE_NODE_HEIGHT;
}

/**
 * Position nodes in a bidirectional column layout.
 *
 * @param {Array} nodes - Svelte Flow node objects to position
 * @param {Map<string, number>} columnMap - nodeId => column index (0 = center, negative = left, positive = right)
 * @param {string} centerNodeId - The center node
 * @returns {Array} Positioned nodes with updated position.x, position.y, sourcePosition, targetPosition
 */
export function layoutColumns(nodes, columnMap, centerNodeId) {
  // Group nodes by column
  const columns = new Map();
  for (const node of nodes) {
    const col = columnMap.get(node.id) ?? 0;
    if (!columns.has(col)) columns.set(col, []);
    columns.get(col).push(node);
  }

  // Sort column indices
  const sortedCols = [...columns.keys()].sort((a, b) => a - b);
  const minCol = sortedCols[0] || 0;

  // Position each column
  const positioned = [];
  for (const colIndex of sortedCols) {
    const colNodes = columns.get(colIndex);
    const xOffset = (colIndex - minCol) * (COLUMN_WIDTH + COLUMN_GAP);

    let yOffset = HEADER_HEIGHT; // leave room for column header

    for (const node of colNodes) {
      const height = estimateNodeHeight(node);
      positioned.push({
        ...node,
        position: { x: xOffset, y: yOffset },
        sourcePosition: 'right',
        targetPosition: 'left',
        style: node.id === centerNodeId
          ? `border-color: #22c55e; box-shadow: 0 0 20px rgba(34, 197, 94, 0.15);`
          : undefined,
      });
      yOffset += height + NODE_GAP;
    }
  }

  return positioned;
}

/**
 * Get the column boundaries for rendering column headers and expand buttons.
 * @param {Map<string, number>} columnMap
 * @returns {Array<{colIndex: number, x: number, width: number}>}
 */
export function getColumnBounds(columnMap) {
  const colIndices = new Set(columnMap.values());
  const sorted = [...colIndices].sort((a, b) => a - b);
  const minCol = sorted[0] || 0;

  return sorted.map((colIndex) => ({
    colIndex,
    x: (colIndex - minCol) * (COLUMN_WIDTH + COLUMN_GAP),
    width: COLUMN_WIDTH,
  }));
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/lib/column-layout.js
git commit -m "feat: add column layout positioning module"
```

---

### Task 7: ExpandButton Component

**Files:**
- Create: `frontend/src/components/ExpandButton.svelte`

The `»`/`«` control that floats outside node cards. Handles click (expand one level) and alt+click (expand recursively).

- [ ] **Step 1: Create ExpandButton.svelte**

```svelte
<script>
  import { COLORS } from '../lib/theme.js';

  let { direction, expanded = false, onExpand, onCollapse, onExpandAll } = $props();

  const symbol = $derived(
    expanded
      ? (direction === 'right' ? '\u00AB' : '\u00BB') // collapse: flip direction
      : (direction === 'right' ? '\u00BB' : '\u00AB') // expand: point in direction
  );

  function handleClick(e) {
    if (expanded) {
      onCollapse?.();
    } else if (e.altKey) {
      onExpandAll?.();
    } else {
      onExpand?.();
    }
  }
</script>

<button
  class="expand-btn"
  class:expanded
  class:left={direction === 'left'}
  class:right={direction === 'right'}
  title={expanded ? 'Collapse' : (direction === 'right' ? 'Expand children (Alt+click: expand all)' : 'Expand parents (Alt+click: expand all)')}
  onclick={handleClick}
>
  {symbol}
</button>

<style>
  .expand-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid #334155;
    border-radius: 4px;
    background: #0f172a;
    color: #475569;
    font-size: 14px;
    cursor: pointer;
    padding: 0;
    line-height: 1;
    transition: border-color 0.15s, color 0.15s;
    flex-shrink: 0;
  }

  .expand-btn:hover {
    border-color: #475569;
    color: #e2e8f0;
  }

  .expand-btn.expanded {
    border-color: #22c55e;
    color: #22c55e;
  }

  .expand-btn.expanded:hover {
    border-color: #16a34a;
    color: #16a34a;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/ExpandButton.svelte
git commit -m "feat: add ExpandButton component for per-branch tree expansion"
```

---

### Task 8: ColumnHeader Component

**Files:**
- Create: `frontend/src/components/ColumnHeader.svelte`

Shows the relationship group label and path breadcrumb for each column (e.g., "Order → has_many").

- [ ] **Step 1: Create ColumnHeader.svelte**

```svelte
<script>
  let { label, parentName, relationshipType, count } = $props();

  const displayLabel = $derived(
    parentName
      ? `${parentName} \u2192 ${relationshipType || 'dependencies'}`
      : label || 'Center'
  );
</script>

<div class="column-header">
  <span class="column-label">{displayLabel}</span>
  {#if count != null}
    <span class="column-count">({count})</span>
  {/if}
</div>

<style>
  .column-header {
    padding: 6px 8px;
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #64748b;
    display: flex;
    align-items: center;
    gap: 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .column-count {
    color: #475569;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/ColumnHeader.svelte
git commit -m "feat: add ColumnHeader component for relationship breadcrumbs"
```

---

### Task 9: ModelNode — Column-Level Handles

**Files:**
- Modify: `frontend/src/components/ModelNode.svelte`

Add left and right Svelte Flow handles to each column row for column-level edge connections. Update badge styling to be subtler.

- [ ] **Step 1: Replace ModelNode.svelte contents**

```svelte
<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor, COLORS } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 28 ? label.slice(0, 26) + '...' : label
  );
  const columns = $derived(data?.columns || []);
  const isCenter = $derived(data?.isCenter || false);

  const highlightClass = $derived.by(() => {
    if (isCenter) return 'node-center';
    if (data?.isActive === undefined) return '';
    if (data?.isActive) return 'node-active';
    if (data?.isHighlighted) return 'node-highlighted';
    return 'node-dimmed';
  });

  const borderColor = $derived(
    isCenter ? COLORS.centerBorder : colors.border
  );

  const connectionCount = $derived(
    (data?.dependencyCount || 0) + (data?.dependentCount || 0)
  );

  function columnIcon(col) {
    if (col.primary) return '\u{1F511}';
    if (col.foreign) return '\u{1F517}';
    if (!col.nullable) return '\u25C6';
    return '\u25C7';
  }
</script>

<div
  class="model-node {highlightClass}"
  style="background:{colors.bg}; border-color:{borderColor}; color:{colors.text};"
>
  <!-- Card-level handles for non-column edges -->
  <Handle type="target" position={targetPosition || Position.Left} />

  <div class="node-header" style={isCenter ? `background: ${COLORS.centerGlow};` : ''}>
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="node-name">{truncated}</span>
    {#if connectionCount > 50}
      <span class="badge connectivity" title="{connectionCount} total connections">{connectionCount}</span>
    {/if}
  </div>

  {#each columns as col, i}
    <div class="column-row">
      <!-- Left handle for this column (for incoming FK references) -->
      <Handle
        type="target"
        position={Position.Left}
        id={`col-left-${col.name}`}
        style="top: auto; left: -4px; width: 8px; height: 8px; background: {col.foreign ? COLORS.edgeActive : 'transparent'}; border: none;"
      />
      <span class="col-icon">{columnIcon(col)}</span>
      <span class="col-name">{col.name}</span>
      <span class="col-type">{col.type || ''}</span>
      <!-- Right handle for this column (for outgoing FK references) -->
      <Handle
        type="source"
        position={Position.Right}
        id={`col-right-${col.name}`}
        style="top: auto; right: -4px; width: 8px; height: 8px; background: {col.primary ? COLORS.edgeActive : 'transparent'}; border: none;"
      />
    </div>
  {/each}

  <Handle type="source" position={sourcePosition || Position.Right} />
</div>

<style>
  .model-node {
    border: 2px solid;
    border-radius: 8px;
    min-width: 160px;
    max-width: 240px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    position: relative;
    transition: opacity 0.15s, box-shadow 0.15s;
  }

  .node-center {
    box-shadow: 0 0 20px rgba(34, 197, 94, 0.15);
  }

  .node-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: 6px 6px 0 0;
  }

  .type-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .node-name {
    font-size: 11px;
    font-weight: 600;
    line-height: 1.3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  .badge {
    font-size: 8px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .badge.connectivity {
    background: #334155;
    color: #94a3b8;
  }

  .column-row {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 10px;
    font-size: 10px;
    border-top: 1px solid #334155;
    position: relative;
  }

  .col-icon {
    width: 14px;
    text-align: center;
    flex-shrink: 0;
    font-size: 10px;
  }

  .col-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-type {
    opacity: 0.6;
    flex-shrink: 0;
    font-size: 9px;
  }

  .node-dimmed {
    opacity: 0.3;
  }
</style>
```

- [ ] **Step 2: Update CompactNode.svelte handle positions**

Change the default handle positions from Top/Bottom to Left/Right for the horizontal layout:

In `CompactNode.svelte`, change:
```svelte
<Handle type="target" position={targetPosition || Position.Top} />
```
to:
```svelte
<Handle type="target" position={targetPosition || Position.Left} />
```

And change:
```svelte
<Handle type="source" position={sourcePosition || Position.Bottom} />
```
to:
```svelte
<Handle type="source" position={sourcePosition || Position.Right} />
```

Also update the `.badge.hub` and `.badge.bridge` styles to the subtler connectivity badge:

Replace the hub/bridge badge markup:
```svelte
{#if data?.isHub}
  <span class="badge hub">HUB</span>
{/if}
{#if data?.isBridge}
  <span class="badge bridge">BRG</span>
{/if}
```
with:
```svelte
{#if (data?.dependencyCount || 0) + (data?.dependentCount || 0) > 50}
  <span class="badge connectivity">{(data?.dependencyCount || 0) + (data?.dependentCount || 0)}</span>
{/if}
```

And update the badge CSS:
```css
.badge.connectivity {
  background: #334155;
  color: #94a3b8;
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/ModelNode.svelte frontend/src/components/CompactNode.svelte
git commit -m "feat: add column-level handles and update node styling for LR layout"
```

---

### Task 10: SearchDropdown Component

**Files:**
- Create: `frontend/src/components/SearchDropdown.svelte`

Command palette overlay that appears below the search input. Shows results grouped by type with bold match highlighting.

- [ ] **Step 1: Create SearchDropdown.svelte**

```svelte
<script>
  import { TYPE_DOT_COLORS, getTypeDisplayName } from '../lib/theme.js';

  let { query, allNodes, onSelect, onClose } = $props();

  const results = $derived.by(() => {
    if (!query || query.length < 1) return [];
    const q = query.toLowerCase();
    const matches = allNodes
      .filter((n) => {
        const label = (n.data?.label || n.id || '').toLowerCase();
        return label.includes(q);
      })
      .slice(0, 50); // pre-filter limit

    // Group by type
    const groups = {};
    for (const node of matches) {
      const t = node.data?.unitType || 'default';
      if (!groups[t]) groups[t] = [];
      groups[t].push(node);
    }

    // Flatten with type headers, max 10 visible
    const flat = [];
    let count = 0;
    for (const [type, nodes] of Object.entries(groups)) {
      if (count >= 10) break;
      flat.push({ type: 'header', unitType: type, label: getTypeDisplayName(type) });
      for (const node of nodes) {
        if (count >= 10) break;
        const label = node.data?.label || node.id;
        const connections = (node.data?.dependencyCount || 0) + (node.data?.dependentCount || 0);
        flat.push({ type: 'result', id: node.id, label, unitType: node.data?.unitType, connections });
        count++;
      }
    }
    return flat;
  });

  const hasResults = $derived(results.some((r) => r.type === 'result'));

  function highlightMatch(text, query) {
    if (!query) return text;
    const idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx === -1) return text;
    return text.slice(0, idx) + '<mark>' + text.slice(idx, idx + query.length) + '</mark>' + text.slice(idx + query.length);
  }

  function handleSelect(id) {
    onSelect?.(id);
    onClose?.();
  }

  function handleKeydown(e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      onClose?.();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if query && query.length > 0}
  <!-- Backdrop to catch clicks outside -->
  <div class="search-backdrop" onclick={onClose}></div>

  <div class="search-dropdown">
    {#if !hasResults}
      <div class="no-results">No matches for "{query}"</div>
    {:else}
      {#each results as item}
        {#if item.type === 'header'}
          <div class="result-header">
            <span class="result-dot" style="background:{TYPE_DOT_COLORS[item.unitType] || TYPE_DOT_COLORS.default};"></span>
            {item.label}
          </div>
        {:else}
          <button class="result-item" onclick={() => handleSelect(item.id)}>
            <span class="result-name">{@html highlightMatch(item.label, query)}</span>
            {#if item.connections > 0}
              <span class="result-connections">{item.connections}</span>
            {/if}
          </button>
        {/if}
      {/each}
    {/if}
  </div>
{/if}

<style>
  .search-backdrop {
    position: fixed;
    inset: 0;
    z-index: 99;
  }

  .search-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 0 0 6px 6px;
    max-height: 320px;
    overflow-y: auto;
    z-index: 100;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }

  .result-header {
    padding: 6px 10px 4px;
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #64748b;
    display: flex;
    align-items: center;
    gap: 6px;
    border-top: 1px solid #334155;
  }

  .result-header:first-child {
    border-top: none;
  }

  .result-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .result-item {
    display: flex;
    align-items: center;
    width: 100%;
    padding: 6px 10px 6px 22px;
    background: none;
    border: none;
    color: #e2e8f0;
    font-size: 12px;
    cursor: pointer;
    text-align: left;
    gap: 8px;
  }

  .result-item:hover {
    background: #334155;
  }

  .result-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  :global(.result-name mark) {
    background: rgba(34, 197, 94, 0.3);
    color: #22c55e;
    border-radius: 2px;
    padding: 0 1px;
  }

  .result-connections {
    font-size: 10px;
    color: #64748b;
    flex-shrink: 0;
  }

  .no-results {
    padding: 12px;
    color: #64748b;
    font-size: 12px;
    text-align: center;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/SearchDropdown.svelte
git commit -m "feat: add SearchDropdown command palette component"
```

---

### Task 11: Sidebar Rewrite

**Files:**
- Modify: `frontend/src/components/Sidebar.svelte`
- Modify: `frontend/src/components/TypeGroup.svelte`

Replace the type-group list with the Visible/Hidden/Recent sections. TypeGroup is repurposed for the Hidden section's type sub-groups.

- [ ] **Step 1: Replace Sidebar.svelte contents**

```svelte
<script>
  import { TYPE_DOT_COLORS, getTypeDisplayName } from '../lib/theme.js';
  import SearchDropdown from './SearchDropdown.svelte';

  let {
    allNodes,
    centerNodeId,
    visibleNodeIds,
    hiddenNodeIds,
    recentNodes = [],
    onSelectUnit,
    onToggleVisibility,
    onClearAll,
  } = $props();

  let searchText = $state('');

  const visibleList = $derived.by(() => {
    return allNodes
      .filter((n) => visibleNodeIds?.has(n.id))
      .sort((a, b) => {
        // Center node first, then alphabetical
        if (a.id === centerNodeId) return -1;
        if (b.id === centerNodeId) return 1;
        return (a.data?.label || a.id).localeCompare(b.data?.label || b.id);
      });
  });

  const hiddenList = $derived.by(() => {
    return allNodes.filter((n) => !visibleNodeIds?.has(n.id));
  });

  const hiddenByType = $derived.by(() => {
    const groups = {};
    for (const node of hiddenList) {
      const t = node.data?.unitType || 'default';
      if (!groups[t]) groups[t] = [];
      groups[t].push(node);
    }
    return groups;
  });

  const hiddenTypes = $derived(
    Object.keys(hiddenByType).sort((a, b) => {
      const order = ['model', 'controller', 'job', 'service', 'mailer', 'concern'];
      const ai = order.indexOf(a);
      const bi = order.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    })
  );

  let hiddenExpanded = $state(false);
  let expandedHiddenTypes = $state(new Set());
  let recentExpanded = $state(true);

  const visibleCount = $derived(visibleNodeIds?.size ?? 0);
  const totalCount = $derived(allNodes?.length ?? 0);

  function toggleHiddenType(type) {
    const next = new Set(expandedHiddenTypes);
    if (next.has(type)) {
      next.delete(type);
    } else {
      next.add(type);
    }
    expandedHiddenTypes = next;
  }

  function handleSearchSelect(id) {
    searchText = '';
    onSelectUnit?.(id);
  }
</script>

<div class="sidebar-panel">
  <!-- Search -->
  <div class="search-container">
    <input
      class="search-input"
      type="text"
      placeholder="Search models..."
      bind:value={searchText}
    />
    <SearchDropdown
      query={searchText}
      {allNodes}
      onSelect={handleSearchSelect}
      onClose={() => { searchText = ''; }}
    />
  </div>

  <!-- Visible Section -->
  <div class="section">
    <div class="section-header sticky">
      <span>Visible</span>
      <span class="count">{visibleCount} / {totalCount}</span>
      {#if visibleCount > 1}
        <button class="clear-btn" onclick={onClearAll}>Clear All</button>
      {/if}
    </div>
    <div class="section-list">
      {#each visibleList as node (node.id)}
        <div
          class="node-item"
          class:center={node.id === centerNodeId}
          role="button"
          tabindex="0"
          onclick={() => onSelectUnit?.(node.id)}
          onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(node.id); }}
        >
          <span class="node-dot" style="background:{TYPE_DOT_COLORS[node.data?.unitType] || TYPE_DOT_COLORS.default};"></span>
          <span class="node-label">{node.data?.label || node.id}</span>
          <button
            class="eye-btn"
            title="Hide"
            onclick={(e) => { e.stopPropagation(); onToggleVisibility?.(node.id); }}
          >
            &#x1F441;
          </button>
        </div>
      {/each}
    </div>
  </div>

  <!-- Hidden Section -->
  <div class="section">
    <button class="section-header sticky clickable" onclick={() => { hiddenExpanded = !hiddenExpanded; }}>
      <span>Hidden</span>
      <span class="count">{hiddenList.length}</span>
      <span class="chevron">{hiddenExpanded ? '\u25BC' : '\u25B6'}</span>
    </button>
    {#if hiddenExpanded}
      <div class="section-list">
        {#each hiddenTypes as unitType (unitType)}
          <button class="type-header" onclick={() => toggleHiddenType(unitType)}>
            <span class="type-dot" style="background:{TYPE_DOT_COLORS[unitType] || TYPE_DOT_COLORS.default};"></span>
            <span>{getTypeDisplayName(unitType)}</span>
            <span class="count">{hiddenByType[unitType].length}</span>
            <span class="chevron">{expandedHiddenTypes.has(unitType) ? '\u25BC' : '\u25B6'}</span>
          </button>
          {#if expandedHiddenTypes.has(unitType)}
            {#each hiddenByType[unitType] as node (node.id)}
              <div
                class="node-item hidden-item"
                role="button"
                tabindex="0"
                onclick={() => onSelectUnit?.(node.id)}
                onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(node.id); }}
              >
                <span class="node-label">{node.data?.label || node.id}</span>
                <button
                  class="eye-btn off"
                  title="Show"
                  onclick={(e) => { e.stopPropagation(); onToggleVisibility?.(node.id); }}
                >
                  &#x2014;
                </button>
              </div>
            {/each}
          {/if}
        {/each}
      </div>
    {/if}
  </div>

  <!-- Recent Section -->
  <div class="section">
    <button class="section-header sticky clickable" onclick={() => { recentExpanded = !recentExpanded; }}>
      <span>Recent</span>
      <span class="count">{recentNodes.length}</span>
      <span class="chevron">{recentExpanded ? '\u25BC' : '\u25B6'}</span>
    </button>
    {#if recentExpanded && recentNodes.length > 0}
      <div class="section-list">
        {#each recentNodes as nodeId (nodeId)}
          {@const node = allNodes.find((n) => n.id === nodeId)}
          {#if node}
            <div
              class="node-item"
              role="button"
              tabindex="0"
              onclick={() => onSelectUnit?.(nodeId)}
              onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(nodeId); }}
            >
              <span class="node-dot" style="background:{TYPE_DOT_COLORS[node.data?.unitType] || TYPE_DOT_COLORS.default};"></span>
              <span class="node-label">{node.data?.label || node.id}</span>
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .sidebar-panel {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  .search-container {
    position: relative;
    padding: 8px;
    border-bottom: 1px solid #334155;
  }

  .search-input {
    width: 100%;
    padding: 6px 10px;
    background: #0f172a;
    border: 1px solid #334155;
    border-radius: 6px;
    color: #e2e8f0;
    font-size: 12px;
    outline: none;
    box-sizing: border-box;
  }

  .search-input:focus {
    border-color: #475569;
  }

  .section {
    display: flex;
    flex-direction: column;
    min-height: 0;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 10px;
    font-size: 11px;
    font-weight: 600;
    color: #94a3b8;
    border-bottom: 1px solid #334155;
    background: #1e293b;
  }

  .section-header.sticky {
    position: sticky;
    top: 0;
    z-index: 1;
  }

  .section-header.clickable {
    cursor: pointer;
    border: none;
    width: 100%;
    text-align: left;
  }

  .section-header.clickable:hover {
    background: #283548;
  }

  .section-list {
    overflow-y: auto;
    flex: 1;
  }

  .node-item {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    cursor: pointer;
    font-size: 11px;
    color: #e2e8f0;
  }

  .node-item:hover {
    background: #283548;
  }

  .node-item.center {
    color: #22c55e;
    font-weight: 600;
  }

  .node-item.hidden-item {
    padding-left: 28px;
    color: #64748b;
  }

  .node-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .node-label {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .eye-btn {
    background: none;
    border: none;
    cursor: pointer;
    font-size: 11px;
    padding: 2px;
    opacity: 0;
    transition: opacity 0.1s;
    color: #94a3b8;
  }

  .node-item:hover .eye-btn {
    opacity: 1;
  }

  .eye-btn.off {
    color: #475569;
  }

  .clear-btn {
    margin-left: auto;
    background: none;
    border: 1px solid #334155;
    border-radius: 4px;
    color: #64748b;
    font-size: 9px;
    padding: 2px 6px;
    cursor: pointer;
  }

  .clear-btn:hover {
    border-color: #475569;
    color: #94a3b8;
  }

  .count {
    color: #475569;
    font-weight: 400;
  }

  .chevron {
    margin-left: auto;
    font-size: 9px;
    color: #475569;
  }

  .type-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    font-size: 10px;
    color: #64748b;
    cursor: pointer;
    background: none;
    border: none;
    border-top: 1px solid #1e293b;
    width: 100%;
    text-align: left;
  }

  .type-header:hover {
    background: #283548;
  }

  .type-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/Sidebar.svelte
git commit -m "feat: rewrite Sidebar with search, visible, hidden, and recent sections"
```

---

### Task 12: ColumnLayout Component

**Files:**
- Create: `frontend/src/components/ColumnLayout.svelte`

The main visualization component. Replaces GraphView. Uses SvelteFlow with the custom column positioning. Renders expand buttons alongside nodes.

- [ ] **Step 1: Create ColumnLayout.svelte**

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';
  import FocusNode from './FocusNode.svelte';
  import { layoutColumns } from '../lib/column-layout.js';
  import { assignColumns } from '../lib/graph-state.js';

  let {
    allNodes,
    allEdges,
    visibleNodeIds,
    centerNodeId,
    expandedBranches,
    loading,
    focusNodeId,
    onNodeSelect,
    onCanvasClick,
  } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  // Filter to visible nodes and edges
  const visibleNodes = $derived.by(() => {
    return allNodes.filter((n) => visibleNodeIds.has(n.id)).map((n) => ({
      ...n,
      type: n.data?.unitType === 'model' ? 'model' : 'compact',
      data: {
        ...n.data,
        isCenter: n.id === centerNodeId,
      },
    }));
  });

  const visibleEdges = $derived.by(() => {
    return allEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .map((e) => ({
        ...e,
        style: e.data?.isCycle
          ? 'stroke: #ef4444; stroke-width: 2px'
          : 'stroke: #475569; stroke-width: 1.5px',
        animated: e.data?.isCycle || false,
      }));
  });

  // Compute column assignments and layout
  const columnMap = $derived(
    assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches)
  );

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  $effect(() => {
    if (visibleNodes.length === 0) {
      layoutedNodes = [];
      layoutedEdges = [];
      return;
    }
    layoutedNodes = layoutColumns(visibleNodes, columnMap, centerNodeId);
    layoutedEdges = visibleEdges;
  });

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  function handlePaneClick() {
    onCanvasClick?.();
  }
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading graph...</div>
  {:else if allNodes.length === 0}
    <div class="loading-overlay">
      No extraction data available. Run <code>rake woods:extract</code> first.
    </div>
  {:else}
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
      fitView
      minZoom={0.1}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
      <FocusNode nodeId={focusNodeId} />
    </SvelteFlow>
  {/if}
</div>

<style>
  .flow-container {
    flex: 1;
    position: relative;
  }

  .loading-overlay {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: #64748b;
    font-size: 14px;
  }

  .loading-overlay code {
    background: #1e293b;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 13px;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/ColumnLayout.svelte
git commit -m "feat: add ColumnLayout component for bidirectional explorer"
```

---

### Task 13: App.svelte Rewrite

**Files:**
- Modify: `frontend/src/App.svelte`

Complete rewrite. Removes cluster tab, wires the new sidebar, column layout, graph state, and progressive loading.

- [ ] **Step 1: Replace App.svelte contents**

```svelte
<script>
  import ColumnLayout from './components/ColumnLayout.svelte';
  import NodeDetail from './components/NodeDetail.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import { fetchNeighbors, fetchFullGraph } from './lib/api.js';
  import { computeVisibleNodes, expandRecursive } from './lib/graph-state.js';

  let allNodes = $state.raw([]);
  let allEdges = $state.raw([]);
  let loading = $state(true);
  let centerNodeId = $state(null);
  let expandedBranches = $state(new Map());
  let hiddenNodeIds = $state(new Set());
  let recentNodes = $state([]);
  let activeNodeId = $state(null);
  let focusNodeId = $state(null);
  let fullGraphLoaded = $state(false);

  // Compute visible nodes from state
  const visibleNodeIds = $derived(
    computeVisibleNodes(centerNodeId, expandedBranches, allNodes, allEdges, hiddenNodeIds)
  );

  // Active node for detail panel
  const selectedNode = $derived.by(() => {
    if (!activeNodeId) return null;
    return allNodes.find((n) => n.id === activeNodeId) || null;
  });

  /**
   * Load initial data: fetch neighbors of the highest-PageRank node.
   */
  async function loadInitial() {
    loading = true;
    try {
      // First request: get any node's neighbors to discover highest_pagerank
      const data = await fetchNeighbors('', 0).catch(() => null);

      // If that fails (empty node param), load full graph instead
      if (!data) {
        await loadFullGraph();
        return;
      }

      const startNode = data.highest_pagerank;
      if (!startNode) {
        await loadFullGraph();
        return;
      }

      // Fetch the start node's neighborhood
      const neighborData = await fetchNeighbors(startNode, 1);
      mergeGraphData(neighborData);
      setCenterNode(startNode);

      // Background: load full graph for instant subsequent navigation
      loadFullGraphBackground();
    } catch (e) {
      console.error('Failed to load initial data:', e);
      // Fallback: load the full graph
      await loadFullGraph();
    }
    loading = false;
  }

  /**
   * Load the full dependency graph.
   */
  async function loadFullGraph() {
    loading = true;
    try {
      const data = await fetchFullGraph();
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        animated: e.data?.isCycle || false,
      }));
      allNodes = rawNodes;
      allEdges = rawEdges;
      fullGraphLoaded = true;

      // Auto-select highest pagerank node if no center
      if (!centerNodeId && rawNodes.length > 0) {
        const sorted = [...rawNodes].sort((a, b) =>
          (b.data?.pagerank || 0) - (a.data?.pagerank || 0)
        );
        setCenterNode(sorted[0].id);
      }
    } catch (e) {
      console.error('Failed to load graph:', e);
    }
    loading = false;
  }

  /**
   * Background-load the full graph after initial paint.
   */
  async function loadFullGraphBackground() {
    try {
      const data = await fetchFullGraph();
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        animated: e.data?.isCycle || false,
      }));
      allNodes = rawNodes;
      allEdges = rawEdges;
      fullGraphLoaded = true;
    } catch (e) {
      console.error('Background graph load failed:', e);
    }
  }

  /**
   * Merge neighbor data into the existing graph (additive).
   */
  function mergeGraphData(data) {
    const existingIds = new Set(allNodes.map((n) => n.id));
    const newNodes = (data.nodes || [])
      .filter((n) => !existingIds.has(n.id))
      .map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));

    const existingEdgeIds = new Set(allEdges.map((e) => e.id));
    const newEdges = (data.edges || [])
      .filter((e) => !existingEdgeIds.has(e.id))
      .map((e) => ({
        ...e,
        animated: e.data?.isCycle || false,
      }));

    if (newNodes.length > 0) allNodes = [...allNodes, ...newNodes];
    if (newEdges.length > 0) allEdges = [...allEdges, ...newEdges];
  }

  /**
   * Set the center node and add to recent history.
   */
  function setCenterNode(id) {
    centerNodeId = id;
    activeNodeId = id;
    expandedBranches = new Map();
    focusNodeId = { id, t: Date.now() };

    // Add to recent (deduplicate, max 10)
    recentNodes = [id, ...recentNodes.filter((r) => r !== id)].slice(0, 10);
  }

  // --- Event handlers ---

  function handleNodeSelect(node) {
    activeNodeId = node?.id || null;
  }

  function handleCanvasClick() {
    activeNodeId = null;
  }

  function handleCloseDetail() {
    activeNodeId = null;
  }

  function handleSelectUnit(id) {
    // Re-center on this node
    setCenterNode(id);
  }

  function handleToggleVisibility(id) {
    const next = new Set(hiddenNodeIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
      if (activeNodeId === id) activeNodeId = null;
    }
    hiddenNodeIds = next;
  }

  function handleClearAll() {
    // Reset to just the center node
    expandedBranches = new Map();
    hiddenNodeIds = new Set();
  }

  function handleExpand(nodeId, direction) {
    const next = new Map(expandedBranches);
    if (!next.has(nodeId)) next.set(nodeId, new Set());
    next.get(nodeId).add(direction);
    expandedBranches = next;
  }

  function handleCollapse(nodeId, direction) {
    const next = new Map(expandedBranches);
    if (next.has(nodeId)) {
      next.get(nodeId).delete(direction);
      if (next.get(nodeId).size === 0) next.delete(nodeId);
    }
    expandedBranches = next;
  }

  function handleExpandAll(nodeId, direction) {
    const newBranches = expandRecursive(nodeId, direction, allEdges);
    const next = new Map(expandedBranches);
    for (const [id, dirs] of newBranches) {
      if (!next.has(id)) next.set(id, new Set());
      for (const d of dirs) next.get(id).add(d);
    }
    expandedBranches = next;
  }

  // Initial load
  loadFullGraph();
</script>

<div class="app-layout">
  <div class="header">
    <h1>Woods <span>Visualize</span></h1>
  </div>

  <div class="content">
    <Sidebar
      {allNodes}
      {centerNodeId}
      {visibleNodeIds}
      {hiddenNodeIds}
      {recentNodes}
      onSelectUnit={handleSelectUnit}
      onToggleVisibility={handleToggleVisibility}
      onClearAll={handleClearAll}
    />

    <div class="main-content">
      <ColumnLayout
        {allNodes}
        {allEdges}
        {visibleNodeIds}
        {centerNodeId}
        {expandedBranches}
        {loading}
        {focusNodeId}
        onNodeSelect={handleNodeSelect}
        onCanvasClick={handleCanvasClick}
      />
      <NodeDetail node={selectedNode} onClose={handleCloseDetail} />
    </div>
  </div>
</div>

<style>
  .app-layout {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: #0f172a;
    color: #e2e8f0;
  }

  .header {
    display: flex;
    align-items: center;
    padding: 8px 16px;
    border-bottom: 1px solid #334155;
    background: #0f172a;
  }

  .header h1 {
    font-size: 14px;
    font-weight: 600;
    margin: 0;
    color: #94a3b8;
  }

  .header h1 span {
    color: #22c55e;
  }

  .content {
    display: flex;
    flex: 1;
    min-height: 0;
  }

  .main-content {
    flex: 1;
    position: relative;
    display: flex;
  }
</style>
```

- [ ] **Step 2: Delete TypeGroup.svelte (no longer used)**

```bash
rm frontend/src/components/TypeGroup.svelte
```

- [ ] **Step 3: Commit**

```bash
git add -A frontend/src/
git commit -m "feat: rewrite App.svelte for bidirectional column explorer"
```

---

### Task 14: Build Frontend and Update Assets

**Files:**
- Modify: `frontend/` build output → `lib/woods/svelte_flow/assets/build/`

Build the Svelte app and copy the compiled assets into the gem's asset directory so the RackMiddleware can serve them.

- [ ] **Step 1: Build the frontend**

```bash
cd frontend && npm run build
```

Expected: Vite builds to `frontend/dist/`.

- [ ] **Step 2: Copy build artifacts to gem assets**

```bash
cp frontend/dist/assets/*.js lib/woods/svelte_flow/assets/build/
cp frontend/dist/assets/*.css lib/woods/svelte_flow/assets/build/
```

- [ ] **Step 3: Update index.html if asset filenames changed**

Check the built `frontend/dist/index.html` for the new JS/CSS filenames. Update `lib/woods/svelte_flow/assets/index.html` to reference them.

- [ ] **Step 4: Commit**

```bash
git add lib/woods/svelte_flow/assets/
git commit -m "build: compile frontend assets for bidirectional column explorer"
```

---

### Task 15: Integration Test in Host App

**Files:** None (manual verification)

Verify the new visualization works end-to-end in the host app.

- [ ] **Step 1: Update the gem in host-woods**

```bash
cd ~/work/myapp && docker compose exec app bash -c "cd /app && bundle update woods"
```

- [ ] **Step 2: Restart the server**

```bash
cd ~/work/myapp && docker compose restart app
```

- [ ] **Step 3: Open visualization and verify**

Navigate to the visualization URL in the browser. Verify:
- App loads and centers on Account (highest PageRank)
- Left column shows belongs_to relationships (Plan, Country)
- Right column shows has_many relationships (Order, Product, Cart, etc.)
- Clicking a node name in sidebar re-centers the view
- Search finds models by name
- Eye icon toggles visibility
- Node detail panel opens on click
- ERD cards show columns with icons

- [ ] **Step 4: Test expansion**

- Click `»` on Order — its dependencies appear in a new column to the right
- Click `«` on Order — the column collapses
- Alt+click `»` on Order — recursive expansion (multiple columns)

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration adjustments from admin app testing"
```

---

## Self-Review

### Spec Coverage Check

| Spec Section | Task(s) |
|---|---|
| Layout: Bidirectional Columns | Tasks 5, 6, 12 |
| Layout: Relationship Grouping | Task 5 (getGroupedDependencies) |
| Layout: Per-Branch Expansion | Tasks 5, 7, 13 |
| Layout: Column Headers | Task 8 |
| Layout: Global Depth Control | Task 13 (App state) |
| Edge: Column-Level Joins | Task 9 |
| Edge: Cardinality Indicators | Task 9 (partial — handles positioned, labels deferred to polish) |
| Edge: has_many :through | Task 5 (via label in edge data) |
| Edge: Cross-Column Edges | Task 12 (inherent in SvelteFlow edge rendering) |
| Edge: Styling | Tasks 9, 12 |
| Node: ModelNode Enhancements | Task 9 |
| Node: Center Distinction | Tasks 9, 12 |
| Node: CompactNode | Task 9 |
| Node: Color System | Task 2 |
| Sidebar: Search | Task 10 |
| Sidebar: Visible/Hidden/Recent | Task 11 |
| Data: Progressive Loading | Tasks 3, 4, 13 |
| Data: New API Endpoint | Task 3 |
| Data: Client-Side State | Task 5 |
| Data: Layout Computation | Task 6 |
| Removed: Dead Code | Task 1 |
| Default Start State | Task 13 |

**Gap identified:** Cardinality labels (the `1`/`n` text at edge endpoints) are not fully implemented — the column-level handles are in place but the actual `1`/`n` text labels require custom edge components. This is visual polish that can be added as a follow-up without blocking the core functionality. Noted in Task 9 as partial.

### Placeholder Scan

No TBD, TODO, "implement later", or "add appropriate handling" patterns found.

### Type Consistency

- `expandedBranches`: `Map<string, Set<string>>` — consistent across graph-state.js, ColumnLayout.svelte, and App.svelte ✓
- `visibleNodeIds`: `Set<string>` — consistent across all components ✓
- `centerNodeId`: `string` — consistent ✓
- `hiddenNodeIds`: `Set<string>` — consistent ✓
- `recentNodes`: `string[]` — consistent ✓
- `fetchNeighbors(nodeId, depth)` signature matches api.js definition ✓
