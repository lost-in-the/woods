# Svelte Flow Visualization Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled canvas frontend with actual Svelte Flow + dagre layout, fix middleware base-path bugs, and produce a working visualization for a 6K-unit Rails app.

**Architecture:** The Ruby backend (Transformer, NodeBuilder, EdgeBuilder, Exporter, RackMiddleware) stays. The vanilla JS canvas frontend is replaced with a pre-built Svelte Flow + dagre app compiled via Vite. Layout computation moves from a Ruby `Layout` class to dagre client-side. The middleware gets base-path injection so assets and API calls resolve correctly at any mount point.

**Tech Stack:** Ruby (gem backend), Svelte 5 + @xyflow/svelte (frontend), @dagrejs/dagre (layout), Vite (build)

**Spec:** `docs/superpowers/specs/2026-04-02-svelte-flow-fixes-design.md`

---

## File Map

### Ruby changes
| File | Action | Purpose |
|------|--------|---------|
| `lib/woods/svelte_flow/rack_middleware.rb` | Modify | Base-path injection in `serve_html` |
| `lib/woods/svelte_flow/layout.rb` | Delete | Replaced by dagre client-side |
| `lib/woods/svelte_flow/transformer.rb` | Modify | Remove Layout dependency, pass raw positions |
| `spec/svelte_flow/layout_spec.rb` | Delete | No longer needed |
| `spec/svelte_flow/rack_middleware_spec.rb` | Modify | Add base-path injection test |
| `spec/svelte_flow/transformer_spec.rb` | Modify | Update for position-less output |
| `.gitignore` | Modify | Add `frontend/node_modules/` |

### Frontend (new)
| File | Action | Purpose |
|------|--------|---------|
| `frontend/package.json` | Create | Dependencies and build scripts |
| `frontend/vite.config.js` | Create | Build config targeting gem assets dir |
| `frontend/index.html` | Create | Vite entry HTML (dev server only) |
| `frontend/src/main.js` | Create | Mount point for Svelte app |
| `frontend/src/App.svelte` | Create | Root component — tabs, loading, error states |
| `frontend/src/lib/api.js` | Create | API client with basePath and safeKey |
| `frontend/src/lib/layout.js` | Create | Dagre layout wrapper |
| `frontend/src/lib/theme.js` | Create | Unit type color mapping |
| `frontend/src/components/GraphView.svelte` | Create | Dependency graph with dagre layout |
| `frontend/src/components/FlowView.svelte` | Create | Sequential execution flow view |
| `frontend/src/components/ClusterView.svelte` | Create | Domain cluster view |
| `frontend/src/components/NodeDetail.svelte` | Create | Sidebar detail panel |
| `frontend/src/components/WoodsNode.svelte` | Create | Custom node component |
| `frontend/src/app.css` | Create | Dark theme styles |

### Assets (replaced by build output)
| File | Action | Purpose |
|------|--------|---------|
| `lib/woods/svelte_flow/assets/index.html` | Replace | Add `{{BASE_PATH}}` placeholders |
| `lib/woods/svelte_flow/assets/app.js` | Replace | Vite build output |
| `lib/woods/svelte_flow/assets/app.css` | Replace | Vite build output |

---

## Task 1: Fix base-path injection in RackMiddleware

This is independent of the frontend rewrite and fixes the core routing bug.

**Files:**
- Modify: `lib/woods/svelte_flow/rack_middleware.rb:93-98`
- Modify: `lib/woods/svelte_flow/assets/index.html`
- Modify: `spec/svelte_flow/rack_middleware_spec.rb`

- [ ] **Step 1: Write the failing test for base-path injection**

Add to `spec/svelte_flow/rack_middleware_spec.rb` inside the `#call` describe block:

```ruby
it 'injects the mount path into served HTML' do
  status, _headers, body = middleware.call(mock_env('/woods/visualize/'))
  next unless status == 200

  html = body.first
  expect(html).to include('content="/woods/visualize"')
  expect(html).not_to include('{{BASE_PATH}}')
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/svelte_flow/rack_middleware_spec.rb -e 'injects the mount path' --format documentation`

Expected: FAIL — the current HTML doesn't contain the mount path.

- [ ] **Step 3: Update index.html with placeholders**

Replace `lib/woods/svelte_flow/assets/index.html` with:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="woods-base-path" content="{{BASE_PATH}}">
  <title>Woods Visualize</title>
  <link rel="stylesheet" href="{{BASE_PATH}}/assets/app.css">
</head>
<body>
  <div id="app">
    <div class="loading">
      <div class="spinner"></div>
      Loading Woods visualization...
    </div>
  </div>
  <script src="{{BASE_PATH}}/assets/app.js"></script>
</body>
</html>
```

- [ ] **Step 4: Update serve_html to gsub placeholders**

In `lib/woods/svelte_flow/rack_middleware.rb`, replace the `serve_html` method:

```ruby
def serve_html
  html_path = File.join(ASSETS_DIR, 'index.html')
  return not_found unless File.exist?(html_path)

  html = File.read(html_path)
  html = html.gsub('{{BASE_PATH}}', @path)

  [200, { 'content-type' => 'text/html' }, [html]]
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/svelte_flow/rack_middleware_spec.rb --format documentation`

Expected: All tests PASS including the new one.

- [ ] **Step 6: Commit**

```bash
git add lib/woods/svelte_flow/rack_middleware.rb lib/woods/svelte_flow/assets/index.html spec/svelte_flow/rack_middleware_spec.rb
git commit -m "Fix base-path injection in Svelte Flow middleware

serve_html now gsubs {{BASE_PATH}} placeholders with the mount path,
fixing API calls and asset resolution when mounted at /woods/visualize."
```

---

## Task 2: Remove Ruby Layout class

Layout moves to dagre client-side. The Transformer must stop depending on Layout.

**Files:**
- Delete: `lib/woods/svelte_flow/layout.rb`
- Delete: `spec/svelte_flow/layout_spec.rb`
- Modify: `lib/woods/svelte_flow/transformer.rb:1-6,31-61,109-160`
- Modify: `spec/svelte_flow/transformer_spec.rb:42-47`

- [ ] **Step 1: Update Transformer to remove Layout dependency**

In `lib/woods/svelte_flow/transformer.rb`:

Remove the `require_relative 'layout'` line (line 3).

Replace the `dependency_graph_data` method with a version that outputs nodes without pre-computed positions (dagre will handle this client-side):

```ruby
def dependency_graph_data
  graph_data = @graph.to_h
  nodes = graph_data[:nodes] || graph_data['nodes'] || {}
  edges = graph_data[:edges] || graph_data['edges'] || {}
  pagerank_scores = @graph.pagerank

  analysis = build_analysis
  cycle_edges = build_cycle_edge_set(analysis[:cycles] || [])

  node_builder = NodeBuilder.new(
    nodes: nodes,
    positions: {},
    pagerank: pagerank_scores,
    analysis: analysis
  )

  valid_ids = Set.new(nodes.keys)
  edge_builder = EdgeBuilder.new(
    edges: edges,
    valid_node_ids: valid_ids,
    cycle_edges: cycle_edges
  )

  {
    'nodes' => node_builder.build,
    'edges' => edge_builder.build
  }
end
```

Replace the `domain_cluster_data` method — remove the `Layout.cluster_positions` call, pass empty positions:

```ruby
def domain_cluster_data # rubocop:disable Metrics
  clusters = @analyzer.domain_clusters
  return { 'nodes' => [], 'edges' => [], 'clusters' => [] } if clusters.empty?

  graph_data = @graph.to_h
  edges = graph_data[:edges] || graph_data['edges'] || {}
  nodes = graph_data[:nodes] || graph_data['nodes'] || {}
  pagerank_scores = @graph.pagerank

  analysis = build_analysis

  # Build nodes only for members that appear in clusters
  cluster_member_ids = clusters.flat_map { |c| c[:members] || c['members'] || [] }
  cluster_nodes = nodes.slice(*cluster_member_ids)

  node_builder = NodeBuilder.new(
    nodes: cluster_nodes,
    positions: {},
    pagerank: pagerank_scores,
    analysis: analysis
  )

  # Collect all boundary edges across clusters
  all_boundary_edges = clusters.flat_map { |c| c[:boundary_edges] || c['boundary_edges'] || [] }
  valid_ids = Set.new(cluster_member_ids)

  boundary = EdgeBuilder.boundary_edges(all_boundary_edges, valid_node_ids: valid_ids)

  # Also include intra-cluster dependency edges
  intra_edges = cluster_member_ids.each_with_object({}) do |id, h|
    targets = (edges[id] || []) & cluster_member_ids
    h[id] = targets unless targets.empty?
  end
  intra_edge_builder = EdgeBuilder.new(edges: intra_edges, valid_node_ids: valid_ids)

  cluster_summaries = clusters.map do |c|
    {
      'name' => c[:name] || c['name'],
      'hub' => c[:hub] || c['hub'],
      'memberCount' => c[:member_count] || c['member_count'],
      'entryPoints' => c[:entry_points] || c['entry_points'] || [],
      'types' => c[:types] || c['types'] || {}
    }
  end

  {
    'nodes' => node_builder.build,
    'edges' => intra_edge_builder.build + boundary,
    'clusters' => cluster_summaries
  }
end
```

Remove the `flow_data` method's `Layout.flow_positions` call — flows are sequential, so assign simple vertical positions inline:

```ruby
def flow_data(flow_data) # rubocop:disable Metrics
  steps = flow_data[:steps] || flow_data['steps'] || []

  flow_nodes = []
  seen = Set.new
  step_index = 0

  steps.each do |step|
    unit = step[:unit] || step['unit']
    next unless unit
    next if seen.include?(unit)

    seen.add(unit)
    step_type = step[:type] || step['type']
    operations = step[:operations] || step['operations'] || []

    flow_nodes << {
      'id' => unit,
      'type' => 'flow_step',
      'position' => { 'x' => 0, 'y' => step_index * 150 },
      'data' => {
        'label' => unit,
        'stepType' => step_type.to_s,
        'filePath' => step[:file_path] || step['file_path'],
        'operationCount' => operations.size,
        'operations' => summarize_operations(operations)
      }
    }
    step_index += 1
  end

  flow_edges = EdgeBuilder.flow_edges(steps)

  {
    'nodes' => flow_nodes,
    'edges' => flow_edges,
    'metadata' => {
      'entryPoint' => flow_data[:entry_point] || flow_data['entry_point'],
      'route' => flow_data[:route] || flow_data['route'],
      'maxDepth' => flow_data[:max_depth] || flow_data['max_depth']
    }
  }
end
```

- [ ] **Step 2: Update transformer spec — position assertions**

In `spec/svelte_flow/transformer_spec.rb`, update the position test (around line 42) since nodes now get `{ 'x' => 0, 'y' => 0 }` default from NodeBuilder:

```ruby
it 'includes node position data' do
  node = result['nodes'].first
  expect(node['position']).to have_key('x')
  expect(node['position']).to have_key('y')
end
```

This test actually still passes as-is since NodeBuilder defaults to `{ 'x' => 0, 'y' => 0 }`. No change needed.

- [ ] **Step 3: Delete layout.rb and layout_spec.rb**

```bash
git rm lib/woods/svelte_flow/layout.rb spec/svelte_flow/layout_spec.rb
```

- [ ] **Step 4: Run full spec suite**

Run: `bundle exec rspec spec/svelte_flow/ --format documentation`

Expected: All remaining specs pass (layout specs removed, transformer specs pass with updated methods).

- [ ] **Step 5: Commit**

```bash
git add lib/woods/svelte_flow/transformer.rb spec/svelte_flow/transformer_spec.rb
git commit -m "Remove Ruby Layout class, defer positioning to dagre client-side

Transformer now outputs nodes without pre-computed positions. The frontend
dagre integration (next task) handles hierarchical DAG layout. Flow views
keep simple sequential y-positioning inline."
```

---

## Task 3: Scaffold the Svelte frontend project

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/vite.config.js`
- Create: `frontend/index.html`
- Create: `frontend/src/main.js`
- Create: `frontend/src/app.css`
- Modify: `.gitignore`

- [ ] **Step 1: Add frontend/node_modules to .gitignore**

Append to `.gitignore`:

```
# Frontend build dependencies (dev only)
frontend/node_modules/
```

- [ ] **Step 2: Create package.json**

Create `frontend/package.json`:

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
    "@dagrejs/dagre": "^1.1.4",
    "@xyflow/svelte": "^1.0.0"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^5.0.0",
    "svelte": "^5.0.0",
    "vite": "^6.0.0"
  }
}
```

- [ ] **Step 3: Create vite.config.js**

Create `frontend/vite.config.js`:

```js
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: '../lib/woods/svelte_flow/assets/build',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'app-[hash].js',
        assetFileNames: (assetInfo) => {
          if (assetInfo.name?.endsWith('.css')) return 'app.css';
          return 'assets/[name]-[hash][extname]';
        },
      },
    },
  },
});
```

Note: build output goes to `assets/build/` — the `index.html` with `{{BASE_PATH}}` placeholders lives alongside it in `assets/` and is hand-maintained (not Vite-generated).

- [ ] **Step 4: Create index.html (Vite dev entry)**

Create `frontend/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="woods-base-path" content="">
  <title>Woods Visualize (Dev)</title>
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.js"></script>
</body>
</html>
```

- [ ] **Step 5: Create main.js entry point**

Create `frontend/src/main.js`:

```js
import { mount } from 'svelte';
import App from './App.svelte';
import './app.css';
import '@xyflow/svelte/dist/style.css';

mount(App, { target: document.getElementById('app') });
```

- [ ] **Step 6: Create app.css (dark theme)**

Create `frontend/src/app.css`:

```css
:root {
  --bg-primary: #0f172a;
  --bg-secondary: #1e293b;
  --bg-tertiary: #334155;
  --text-primary: #e2e8f0;
  --text-secondary: #94a3b8;
  --border: #475569;
  --accent: #3b82f6;
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: var(--bg-primary);
  color: var(--text-primary);
  height: 100vh;
  overflow: hidden;
}

#app {
  display: grid;
  grid-template-rows: 48px 1fr 32px;
  height: 100vh;
}

.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 16px;
  background: var(--bg-secondary);
  border-bottom: 1px solid var(--border);
}

.header h1 {
  font-size: 14px;
  font-weight: 600;
}

.header h1 span {
  color: var(--text-secondary);
  font-weight: 400;
}

.tabs {
  display: flex;
  gap: 4px;
}

.tab {
  padding: 6px 12px;
  border: none;
  background: none;
  color: var(--text-secondary);
  font-size: 12px;
  cursor: pointer;
  border-radius: 4px;
}

.tab:hover {
  background: var(--bg-tertiary);
}

.tab.active {
  background: var(--accent);
  color: #fff;
}

.flow-container {
  position: relative;
  overflow: hidden;
}

.stats-bar {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0 16px;
  background: var(--bg-secondary);
  border-top: 1px solid var(--border);
  font-size: 11px;
  color: var(--text-secondary);
}

.stat-value {
  color: var(--text-primary);
  font-weight: 600;
}

.sidebar {
  position: absolute;
  right: 0;
  top: 48px;
  bottom: 32px;
  width: 320px;
  background: var(--bg-secondary);
  border-left: 1px solid var(--border);
  padding: 16px;
  transform: translateX(100%);
  transition: transform 0.2s;
  overflow-y: auto;
  z-index: 10;
}

.sidebar.open {
  transform: translateX(0);
}

.sidebar h3 {
  font-size: 14px;
  margin-bottom: 12px;
  word-break: break-all;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  padding: 6px 0;
  border-bottom: 1px solid var(--bg-tertiary);
  font-size: 12px;
}

.detail-label {
  color: var(--text-secondary);
}

.close-btn {
  position: absolute;
  top: 8px;
  right: 8px;
  background: none;
  border: none;
  color: var(--text-secondary);
  font-size: 18px;
  cursor: pointer;
}

.loading-overlay {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: var(--text-secondary);
  font-size: 14px;
  gap: 8px;
}

.error-overlay {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: #ef4444;
  font-size: 14px;
  gap: 8px;
}

.flow-selector {
  padding: 8px 16px;
  background: var(--bg-secondary);
  border-bottom: 1px solid var(--border);
}

.flow-selector select {
  background: var(--bg-tertiary);
  color: var(--text-primary);
  border: 1px solid var(--border);
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
}

/* Svelte Flow overrides for dark theme */
.svelte-flow {
  background: var(--bg-primary) !important;
}

.svelte-flow__minimap {
  background: var(--bg-secondary) !important;
  border: 1px solid var(--border) !important;
}

.svelte-flow__controls {
  border: 1px solid var(--border) !important;
}

.svelte-flow__controls button {
  background: var(--bg-secondary) !important;
  border-color: var(--border) !important;
  color: var(--text-primary) !important;
}

.svelte-flow__controls button:hover {
  background: var(--bg-tertiary) !important;
}
```

- [ ] **Step 7: Install dependencies**

```bash
cd frontend && npm install
```

- [ ] **Step 8: Commit scaffold**

```bash
cd ..
git add .gitignore frontend/package.json frontend/vite.config.js frontend/index.html frontend/src/main.js frontend/src/app.css
git commit -m "Scaffold Svelte frontend project for Woods visualization"
```

---

## Task 4: Create shared utilities (API client, layout, theme)

**Files:**
- Create: `frontend/src/lib/api.js`
- Create: `frontend/src/lib/layout.js`
- Create: `frontend/src/lib/theme.js`

- [ ] **Step 1: Create API client**

Create `frontend/src/lib/api.js`:

```js
const basePath =
  document.querySelector('meta[name="woods-base-path"]')?.content || '';

export async function fetchJSON(endpoint) {
  const res = await fetch(`${basePath}/api/${endpoint}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

export function safeKey(identifier) {
  return identifier.replace(/::/g, '__').replace(/[^a-zA-Z0-9_-]/g, '_');
}
```

- [ ] **Step 2: Create dagre layout wrapper**

Create `frontend/src/lib/layout.js`:

```js
import dagre from '@dagrejs/dagre';

const NODE_WIDTH = 172;
const NODE_HEIGHT = 44;

export function getLayoutedElements(nodes, edges, direction = 'TB') {
  const g = new dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 120 });

  nodes.forEach((node) => {
    g.setNode(node.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
  });

  edges.forEach((edge) => {
    g.setEdge(edge.source, edge.target);
  });

  dagre.layout(g);

  const isHorizontal = direction === 'LR';

  const layoutedNodes = nodes.map((node) => {
    const pos = g.node(node.id);
    return {
      ...node,
      targetPosition: isHorizontal ? 'left' : 'top',
      sourcePosition: isHorizontal ? 'right' : 'bottom',
      position: {
        x: pos.x - NODE_WIDTH / 2,
        y: pos.y - NODE_HEIGHT / 2,
      },
    };
  });

  return { nodes: layoutedNodes, edges };
}
```

- [ ] **Step 3: Create theme / color mapping**

Create `frontend/src/lib/theme.js`:

```js
export const TYPE_COLORS = {
  model: { bg: '#1e3a5f', border: '#3b82f6', text: '#93c5fd' },
  controller: { bg: '#3b1f3b', border: '#a855f7', text: '#d8b4fe' },
  service: { bg: '#1a3b2a', border: '#22c55e', text: '#86efac' },
  job: { bg: '#3b2e1a', border: '#f59e0b', text: '#fcd34d' },
  mailer: { bg: '#3b1a2e', border: '#ec4899', text: '#f9a8d4' },
  concern: { bg: '#2a2a3b', border: '#6366f1', text: '#a5b4fc' },
  component: { bg: '#1a3b3b', border: '#14b8a6', text: '#5eead4' },
  graphql: { bg: '#3b1a3b', border: '#e11d48', text: '#fda4af' },
  serializer: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  policy: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  route: { bg: '#1a2a3b', border: '#0ea5e9', text: '#7dd3fc' },
  middleware: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  framework: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  flow_step: { bg: '#1e293b', border: '#0ea5e9', text: '#7dd3fc' },
  default: { bg: '#1e293b', border: '#475569', text: '#94a3b8' },
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}
```

- [ ] **Step 4: Commit utilities**

```bash
git add frontend/src/lib/api.js frontend/src/lib/layout.js frontend/src/lib/theme.js
git commit -m "Add shared utilities: API client, dagre layout, theme colors"
```

---

## Task 5: Create the custom WoodsNode component

**Files:**
- Create: `frontend/src/components/WoodsNode.svelte`

- [ ] **Step 1: Create custom node component**

Create `frontend/src/components/WoodsNode.svelte`:

```svelte
<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, type, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType || type));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 28 ? label.slice(0, 26) + '...' : label
  );
</script>

<div
  class="woods-node"
  style="background:{colors.bg}; border-color:{colors.border}; color:{colors.text};"
>
  <Handle type="target" position={targetPosition || Position.Top} />

  <div class="node-label">{truncated}</div>
  <div class="node-type">{(data?.unitType || type || '').toUpperCase()}</div>

  <div class="badges">
    {#if data?.isHub}
      <span class="badge hub">HUB</span>
    {/if}
    {#if data?.isBridge}
      <span class="badge bridge">BRG</span>
    {/if}
  </div>

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .woods-node {
    padding: 8px 12px;
    border: 2px solid;
    border-radius: 8px;
    min-width: 120px;
    max-width: 200px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    position: relative;
  }

  .node-label {
    font-size: 11px;
    font-weight: 600;
    line-height: 1.3;
    word-break: break-all;
  }

  .node-type {
    font-size: 10px;
    opacity: 0.6;
    margin-top: 2px;
  }

  .badges {
    position: absolute;
    top: 4px;
    right: 4px;
    display: flex;
    gap: 2px;
  }

  .badge {
    font-size: 8px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  .badge.hub {
    background: #dc2626;
    color: #fff;
  }

  .badge.bridge {
    background: #f59e0b;
    color: #000;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/WoodsNode.svelte
git commit -m "Add custom WoodsNode component with type colors and badges"
```

---

## Task 6: Create NodeDetail sidebar component

**Files:**
- Create: `frontend/src/components/NodeDetail.svelte`

- [ ] **Step 1: Create sidebar component**

Create `frontend/src/components/NodeDetail.svelte`:

```svelte
<script>
  let { node, onClose } = $props();

  const d = $derived(node?.data || {});
  const rows = $derived.by(() => {
    const r = [
      ['Type', d.unitType || node?.type || '-'],
      ['File', d.filePath || '-'],
      ['Namespace', d.namespace || '-'],
      ['PageRank', d.pagerank ? d.pagerank.toFixed(6) : '-'],
    ];
    if (d.isHub) r.push(['Role', 'Hub']);
    if (d.isBridge) r.push(['Role', 'Bridge']);
    if (d.isOrphan) r.push(['Role', 'Orphan']);
    if (d.operations) r.push(['Operations', d.operationCount || d.operations.length]);
    if (d.stepType) r.push(['Step Type', d.stepType]);
    return r;
  });
</script>

{#if node}
  <div class="sidebar open">
    <button class="close-btn" onclick={onClose}>&times;</button>
    <h3>{node.id}</h3>
    {#each rows as [label, value]}
      <div class="detail-row">
        <span class="detail-label">{label}</span>
        <span class="detail-value">{value}</span>
      </div>
    {/each}
  </div>
{/if}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/NodeDetail.svelte
git commit -m "Add NodeDetail sidebar component"
```

---

## Task 7: Create GraphView component (dependency graph + dagre)

**Files:**
- Create: `frontend/src/components/GraphView.svelte`

- [ ] **Step 1: Create GraphView**

Create `frontend/src/components/GraphView.svelte`:

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { fetchJSON } from '../lib/api.js';
  import { getLayoutedElements } from '../lib/layout.js';
  import WoodsNode from './WoodsNode.svelte';

  let { onNodeSelect } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode };

  async function load() {
    loading = true;
    error = null;
    try {
      const data = await fetchJSON('graph');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        style: e.data?.isCycle
          ? 'stroke: #ef4444; stroke-width: 2px'
          : undefined,
        animated: e.data?.isCycle || e.animated || false,
      }));

      const laid = getLayoutedElements(rawNodes, rawEdges, 'TB');
      nodes = laid.nodes;
      edges = laid.edges;
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleNodeClick(_event, node) {
    onNodeSelect?.(node);
  }

  load();
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading graph...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading graph</div>
      <div style="font-size:12px;color:#94a3b8">{error}</div>
    </div>
  {:else}
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodeclick={handleNodeClick}
      fitView
      minZoom={0.05}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
    </SvelteFlow>
  {/if}
</div>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/GraphView.svelte
git commit -m "Add GraphView component with dagre layout"
```

---

## Task 8: Create FlowView and ClusterView components

**Files:**
- Create: `frontend/src/components/FlowView.svelte`
- Create: `frontend/src/components/ClusterView.svelte`

- [ ] **Step 1: Create FlowView**

Create `frontend/src/components/FlowView.svelte`:

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { fetchJSON, safeKey } from '../lib/api.js';
  import WoodsNode from './WoodsNode.svelte';

  let { onNodeSelect } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let flowIndex = $state({});
  let selectedFlow = $state(null);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode, flow_step: WoodsNode };

  async function loadIndex() {
    loading = true;
    error = null;
    try {
      flowIndex = await fetchJSON('flows');
      const keys = Object.keys(flowIndex);
      if (keys.length > 0) {
        await loadFlow(keys[0]);
      } else {
        nodes = [];
        edges = [];
        loading = false;
      }
    } catch (e) {
      error = e.message;
      loading = false;
    }
  }

  async function loadFlow(entryPoint) {
    selectedFlow = entryPoint;
    loading = true;
    error = null;
    try {
      const data = await fetchJSON(`flows/${safeKey(entryPoint)}`);
      nodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
        position: n.position || { x: 0, y: 0 },
        sourcePosition: 'bottom',
        targetPosition: 'top',
      }));
      edges = (data.edges || []).map((e) => ({
        ...e,
        type: e.type || 'smoothstep',
      }));
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleFlowChange(event) {
    loadFlow(event.target.value);
  }

  function handleNodeClick(_event, node) {
    onNodeSelect?.(node);
  }

  loadIndex();
</script>

{#if Object.keys(flowIndex).length > 0}
  <div class="flow-selector">
    <select onchange={handleFlowChange}>
      {#each Object.keys(flowIndex) as ep}
        <option value={ep} selected={ep === selectedFlow}>{ep}</option>
      {/each}
    </select>
  </div>
{/if}

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading flow...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading flow</div>
      <div style="font-size:12px;color:#94a3b8">{error}</div>
    </div>
  {:else if nodes.length === 0}
    <div class="loading-overlay">No flows available. Enable precompute_flows in Woods config.</div>
  {:else}
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodeclick={handleNodeClick}
      fitView
      minZoom={0.1}
      maxZoom={2}
    >
      <Controls />
      <Background />
    </SvelteFlow>
  {/if}
</div>
```

- [ ] **Step 2: Create ClusterView**

Create `frontend/src/components/ClusterView.svelte`:

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { fetchJSON } from '../lib/api.js';
  import { getLayoutedElements } from '../lib/layout.js';
  import WoodsNode from './WoodsNode.svelte';

  let { onNodeSelect, onClusterData } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode };

  async function load() {
    loading = true;
    error = null;
    try {
      const data = await fetchJSON('clusters');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        animated: e.data?.relationship === 'boundary' || e.animated || false,
        style:
          e.data?.relationship === 'boundary'
            ? 'stroke: #22d3ee; stroke-dasharray: 5 5'
            : undefined,
      }));

      const laid = getLayoutedElements(rawNodes, rawEdges, 'TB');
      nodes = laid.nodes;
      edges = laid.edges;
      onClusterData?.(data.clusters || []);
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleNodeClick(_event, node) {
    onNodeSelect?.(node);
  }

  load();
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading clusters...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading clusters</div>
      <div style="font-size:12px;color:#94a3b8">{error}</div>
    </div>
  {:else}
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodeclick={handleNodeClick}
      fitView
      minZoom={0.05}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
    </SvelteFlow>
  {/if}
</div>
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/FlowView.svelte frontend/src/components/ClusterView.svelte
git commit -m "Add FlowView and ClusterView components"
```

---

## Task 9: Create root App.svelte and wire everything together

**Files:**
- Create: `frontend/src/App.svelte`

- [ ] **Step 1: Create App.svelte**

Create `frontend/src/App.svelte`:

```svelte
<script>
  import GraphView from './components/GraphView.svelte';
  import FlowView from './components/FlowView.svelte';
  import ClusterView from './components/ClusterView.svelte';
  import NodeDetail from './components/NodeDetail.svelte';

  let activeTab = $state('graph');
  let selectedNode = $state(null);
  let clusters = $state([]);

  function switchTab(tab) {
    if (activeTab === tab) return;
    activeTab = tab;
    selectedNode = null;
    clusters = [];
  }

  function handleNodeSelect(node) {
    selectedNode = node;
  }

  function handleCloseDetail() {
    selectedNode = null;
  }

  function handleClusterData(data) {
    clusters = data;
  }
</script>

<div class="header">
  <h1>Woods <span>Visualize</span></h1>
  <div class="tabs">
    <button
      class="tab"
      class:active={activeTab === 'graph'}
      onclick={() => switchTab('graph')}
    >
      Dependencies
    </button>
    <button
      class="tab"
      class:active={activeTab === 'flows'}
      onclick={() => switchTab('flows')}
    >
      Flows
    </button>
    <button
      class="tab"
      class:active={activeTab === 'clusters'}
      onclick={() => switchTab('clusters')}
    >
      Clusters
    </button>
  </div>
</div>

<div class="main-content">
  {#if activeTab === 'graph'}
    <GraphView onNodeSelect={handleNodeSelect} />
  {:else if activeTab === 'flows'}
    <FlowView onNodeSelect={handleNodeSelect} />
  {:else if activeTab === 'clusters'}
    <ClusterView
      onNodeSelect={handleNodeSelect}
      onClusterData={handleClusterData}
    />
  {/if}
</div>

<NodeDetail node={selectedNode} onClose={handleCloseDetail} />

<div class="stats-bar">
  {#if clusters.length > 0}
    <div class="stat">
      Clusters: <span class="stat-value">{clusters.length}</span>
    </div>
  {/if}
</div>

<style>
  .main-content {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/App.svelte
git commit -m "Add root App component with tab navigation"
```

---

## Task 10: Update middleware to serve build output, build, and verify

**Files:**
- Modify: `lib/woods/svelte_flow/rack_middleware.rb:30`
- Modify: `lib/woods/svelte_flow/assets/index.html`

- [ ] **Step 1: Update ASSETS_DIR to include build subdirectory**

The Vite build outputs to `assets/build/`. The middleware needs to serve files from both `assets/` (for `index.html`) and `assets/build/` (for `app.js`, `app.css`).

In `lib/woods/svelte_flow/rack_middleware.rb`, update the `serve_asset` method to look in the build subdirectory:

```ruby
ASSETS_DIR = File.expand_path('assets', __dir__)
BUILD_DIR = File.join(ASSETS_DIR, 'build')
```

Replace the `serve_asset` method:

```ruby
def serve_asset(filename)
  # Prevent directory traversal
  safe_name = File.basename(filename)

  # Check build directory first, then assets root
  asset_path = File.join(BUILD_DIR, safe_name)
  asset_path = File.join(ASSETS_DIR, safe_name) unless File.exist?(asset_path)
  return not_found unless File.exist?(asset_path)

  ext = File.extname(safe_name)
  content_type = CONTENT_TYPES.fetch(ext, 'application/octet-stream')

  [200, { 'content-type' => content_type }, [File.read(asset_path)]]
end
```

- [ ] **Step 2: Update index.html asset references to point at assets/ path**

The `index.html` with `{{BASE_PATH}}` placeholders stays in `lib/woods/svelte_flow/assets/index.html` (from Task 1). The JS and CSS paths already point to `{{BASE_PATH}}/assets/app.js` which the middleware routes to `serve_asset('app.js')`, which now checks `build/app.js`. No changes needed to index.html.

- [ ] **Step 3: Build the frontend**

```bash
cd frontend && npm run build
```

Expected: Build completes, outputs to `lib/woods/svelte_flow/assets/build/`:
- `app.js` (~120-140KB)
- `app.css` (~15-20KB)

- [ ] **Step 4: Run the full Ruby spec suite**

```bash
cd ..
bundle exec rspec spec/svelte_flow/ --format documentation
```

Expected: All specs pass. The middleware spec's HTML test verifies base-path injection. The build output files exist in the assets directory.

- [ ] **Step 5: Commit build output and middleware changes**

```bash
git add lib/woods/svelte_flow/rack_middleware.rb lib/woods/svelte_flow/assets/
git commit -m "Build Svelte Flow frontend, update middleware to serve build output

Compiled Svelte Flow + dagre app replaces the hand-rolled canvas renderer.
Middleware now checks assets/build/ for JS/CSS output from Vite."
```

---

## Task 11: Build the gem and test in admin app

This task is manual — it validates the full pipeline in the admin worktree.

**Files:**
- No gem source changes — this is integration testing

- [ ] **Step 1: Build the gem**

```bash
gem build woods.gemspec
```

Expected: Produces `woods-<version>.gem`.

- [ ] **Step 2: Copy to admin worktree and install**

```bash
cp woods-*.gem ~/work/myapp/host-woods/
cd ~/work/myapp/host-woods
```

Update `Gemfile` temporarily if needed to point at the local gem file, then:

```bash
# Inside Docker container:
bundle update woods
```

- [ ] **Step 3: Enable svelte_flow in admin config**

Add to the Woods initializer (e.g., `config/initializers/woods.rb`):

```ruby
Woods.configure do |config|
  config.svelte_flow_enabled = true
  # config.svelte_flow_path = '/woods/visualize'  # default
end
```

- [ ] **Step 4: Verify extraction output exists**

```bash
# Inside Docker:
ls /app/tmp/woods/manifest.json
```

If missing, run extraction:

```bash
bin/rails woods:extract
```

- [ ] **Step 5: Start Rails and test in browser**

Navigate to `http://localhost:3000/woods/visualize` (or whatever the admin dev URL is).

Verify checklist:
- [ ] Page loads — HTML, CSS, JS all resolve correctly
- [ ] Dependencies tab renders graph with dagre layout (top-to-bottom)
- [ ] Nodes are clickable — sidebar shows type, file path, PageRank, hub/bridge status
- [ ] Zoom/pan/fit-view controls work
- [ ] Minimap renders
- [ ] Clusters tab loads domain clusters
- [ ] Flows tab loads flow index (if `precompute_flows` enabled)
- [ ] No console errors in browser devtools
- [ ] Layout handles 6K+ nodes without skyscrapers
