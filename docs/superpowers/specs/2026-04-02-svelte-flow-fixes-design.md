# Svelte Flow Visualization Fixes

**Date**: 2026-04-02 (updated 2026-04-03)
**Branch**: `claude/add-svelte-flow-visualization-GbLbD`
**Goal**: Fix integration bugs and replace the hand-rolled canvas renderer with actual Svelte Flow + dagre, making the visualization functional in a real Rails app (admin, 6,317 units).

## Context

The Svelte Flow feature has solid backend architecture (Transformer, Exporter, NodeBuilder, EdgeBuilder, RackMiddleware) with 80 passing specs. However:

1. Four bugs at integration boundaries prevent it from functioning when mounted in a Rails app.
2. The hand-rolled vanilla JS canvas renderer reimplements (poorly) what Svelte Flow provides out of the box: zoom, pan, node interaction, edge routing.
3. The Ruby `Layout` class produces unusable output at scale — layers become skyscrapers.

**Decision**: Replace the vanilla JS frontend with a pre-built Svelte Flow + dagre app. Svelte is a compiler (not a runtime), so the compiled output is ~120-140KB of vanilla JS with zero framework overhead. The gem continues to ship pre-built assets with no Node.js or build step required for end users. Layout computation moves to dagre (client-side), which handles hierarchical DAG layout with proper edge crossing minimization.

## Architecture Change

### What stays
- `rack_middleware.rb` — serves HTML, API endpoints, static assets (with base-path fix)
- `transformer.rb` — orchestrates graph/flow/cluster data into node+edge format
- `node_builder.rb` — converts dependency graph nodes to Svelte Flow node objects
- `edge_builder.rb` — converts dependency graph edges to Svelte Flow edge objects
- `exporter.rb` — reads extraction output, writes Svelte Flow JSON files
- All existing Ruby specs

### What changes
- `assets/index.html` — updated with `{{BASE_PATH}}` placeholders (hand-maintained, not Vite-generated — the middleware gsubs these at serve time)
- `assets/app.js` — **replaced** with pre-built Svelte Flow + dagre bundle (Vite output)
- `assets/app.css` — **replaced** with pre-built Svelte Flow styles (Vite output)

### What's added
- `frontend/` — Svelte project directory (source for pre-built assets)
  - `package.json` — @xyflow/svelte, @dagrejs/dagre, vite, svelte
  - `src/App.svelte` — main visualization component
  - `src/lib/` — layout helpers, node/edge components, API client
  - `vite.config.js` — builds to `lib/woods/svelte_flow/assets/`
- Build script: `cd frontend && npm run build` (gem development only)

### What's removed
- `layout.rb` — replaced by dagre client-side layout
- `spec/svelte_flow/layout_spec.rb` — no longer needed

### Gem impact
- **No new Ruby dependencies** — gemspec unchanged
- **No build step for gem users** — compiled assets ship with the gem
- **Asset size**: ~15KB (current) → ~120-140KB (Svelte Flow + dagre compiled). Acceptable for a visualization feature.
- `frontend/` directory is excluded from the gemspec's `files` list (development only)

## Fixes (Ruby side)

### Fix 1: Base-path injection in serve_html

**Problem**: `index.html` ships with hardcoded empty base path and relative asset URLs. The middleware serves the file as-is, so JS fetches `/api/graph` instead of `/woods/visualize/api/graph`.

**Solution**: Use `{{BASE_PATH}}` placeholders in `index.html`. `serve_html` performs `gsub('{{BASE_PATH}}', @path)` before returning.

**Files**: `rack_middleware.rb`, `assets/index.html`

### Fix 2: JS safeKey mismatch

**Problem**: JS only replaces `::` and `#` when building flow URL keys. Ruby replaces all non-alphanumeric chars except `_` and `-`.

**Solution**: Svelte app's safeKey function mirrors the Ruby regex exactly:
```js
identifier.replace(/::/g, '__').replace(/[^a-zA-Z0-9_-]/g, '_')
```

**Files**: `frontend/src/lib/api.js` (compiled into app.js)

### Fix 3: Layout drops sink-only nodes

**Problem**: Ruby `Layout` derived node IDs from edge keys only, missing target-only nodes.

**Solution**: This is now moot — dagre receives all nodes explicitly (the API sends the full node list). Dagre positions every node it's told about, regardless of edge connectivity. No Ruby change needed.

## Frontend (Svelte Flow app)

### Svelte project structure

```
frontend/
├── package.json
├── vite.config.js
├── src/
│   ├── App.svelte              # Root — tabs, data fetching, error states
│   ├── main.js                 # Entry point, mounts App
│   ├── lib/
│   │   ├── api.js              # fetchJSON, safeKey, basePath detection
│   │   ├── layout.js           # dagre layout wrapper (TB direction)
│   │   ├── nodeTypes.js        # Custom node type components registry
│   │   └── theme.js            # Color mapping by unit type
│   ├── components/
│   │   ├── GraphView.svelte    # SvelteFlow + dagre for dependency graph
│   │   ├── FlowView.svelte     # SvelteFlow for sequential execution flows
│   │   ├── ClusterView.svelte  # SvelteFlow + dagre for domain clusters
│   │   ├── NodeDetail.svelte   # Sidebar with node metadata
│   │   └── WoodsNode.svelte    # Custom node component (type badge, hub/bridge markers)
│   └── app.css                 # Dark theme styles
```

### Key implementation details

**Layout (layout.js)**: Thin wrapper around dagre:
```js
import dagre from '@dagrejs/dagre';

export function getLayoutedElements(nodes, edges, direction = 'TB') {
  const g = new dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 120 });

  nodes.forEach(node => {
    g.setNode(node.id, { width: 172, height: 44 });
  });

  edges.forEach(edge => {
    g.setEdge(edge.source, edge.target);
  });

  dagre.layout(g);

  return nodes.map(node => {
    const pos = g.node(node.id);
    return {
      ...node,
      position: { x: pos.x - 172 / 2, y: pos.y - 44 / 2 },
      targetPosition: 'top',
      sourcePosition: 'bottom',
    };
  });
}
```

**API client (api.js)**: Reads base path from meta tag, fetches from middleware endpoints:
```js
const basePath = document.querySelector('meta[name="woods-base-path"]')?.content || '';

export async function fetchJSON(endpoint) {
  const res = await fetch(`${basePath}/api/${endpoint}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

export function safeKey(identifier) {
  return identifier.replace(/::/g, '__').replace(/[^a-zA-Z0-9_-]/g, '_');
}
```

**Vite config**: Builds a single IIFE bundle targeting the gem's assets directory:
```js
export default {
  build: {
    outDir: '../lib/woods/svelte_flow/assets',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        assetFileNames: 'app.css',
      },
    },
  },
};
```

### Features carried forward from current app.js
- Three tabs: Dependencies, Flows, Clusters
- Node selection with sidebar detail panel
- Unit type color coding (model, controller, service, job, etc.)
- Hub/Bridge badges on nodes
- Cycle edges highlighted in red
- Stats bar (node count, edge count, cluster count)
- Flow selector dropdown
- Auto-fit view on data load

### Features gained from Svelte Flow
- Proper edge routing (smoothstep, bezier) with arrow markers
- Built-in minimap
- Built-in controls (zoom in/out, fit view, lock)
- Proper node drag-and-drop
- Edge labels
- Animated edges (for cycle/boundary markers)
- Proper handle positions (source bottom, target top for TB layout)

## Specs

### Updated Ruby specs
- `rack_middleware_spec.rb` — add test for base-path injection in served HTML
- Existing transformer, node_builder, edge_builder, exporter specs remain unchanged

### Removed
- `layout_spec.rb` — Layout class removed, dagre handles this client-side

### Not adding
- Frontend JS tests — the Svelte app is small (~200 lines of source) and verified by manual browser testing in admin. Adding a JS test framework to a Ruby gem is more complexity than it's worth at this stage.

## Build Workflow

For gem developers modifying the frontend:

```bash
cd frontend
npm install          # first time only
npm run dev          # dev server with hot reload (optional, for rapid iteration)
npm run build        # production build → lib/woods/svelte_flow/assets/
cd ..
bundle exec rake spec  # verify Ruby specs still pass
gem build woods.gemspec  # package gem with updated assets
```

The compiled assets (`app.js`, `app.css`, `index.html`) are committed to git. The `frontend/node_modules/` directory is gitignored.

## Test Plan

1. `cd frontend && npm run build` — verify clean build
2. `bundle exec rake spec` — all Ruby specs pass
3. `gem build woods.gemspec` — produces `.gem` file
4. Copy gem to host-woods worktree, `bundle update woods`
5. Enable `svelte_flow_enabled = true` in admin Woods initializer
6. Verify extraction output exists (`tmp/woods/manifest.json`)
7. Start Rails server, navigate to `/woods/visualize`
8. Verify:
   - [ ] Page loads — HTML, CSS, JS all resolve correctly
   - [ ] Dependencies tab renders graph with dagre layout (top-to-bottom)
   - [ ] Nodes are clickable — sidebar shows type, file path, PageRank, hub/bridge status
   - [ ] Zoom/pan/fit-view controls work
   - [ ] Minimap renders
   - [ ] Clusters tab loads domain clusters with grouped layout
   - [ ] Flows tab loads flow index (if `precompute_flows` enabled)
   - [ ] Flow selector switches between entry points
   - [ ] No console errors in browser devtools
   - [ ] Layout handles 6K+ nodes without skyscrapers

## Not Fixing (out of scope)

- **Cache headers on assets** — premature for dev-only tool
- **collision_safe_filename for flow exports** — flow index handles lookups correctly
- **MCP tools for svelte flow** — separate feature, can add later
- **Node filtering/collapsing for large graphs** — future enhancement if dagre layout proves insufficient at scale
- **Frontend test suite** — verified manually for now
