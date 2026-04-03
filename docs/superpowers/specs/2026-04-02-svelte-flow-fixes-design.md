# Svelte Flow Visualization Fixes

**Date**: 2026-04-02
**Branch**: `claude/add-svelte-flow-visualization-GbLbD`
**Goal**: Fix integration bugs preventing the Svelte Flow visualization from working in a real Rails app (admin, 6,317 units).

## Context

The Svelte Flow feature has solid architecture (Transformer, Exporter, NodeBuilder, EdgeBuilder, Layout, RackMiddleware) with 80 passing specs. However, four bugs at integration boundaries prevent it from functioning when mounted in a Rails app, and the layout algorithm produces unusable output at scale.

## Fixes

### Fix 1: Base-path injection in serve_html

**Problem**: `index.html` ships with hardcoded empty values for the base path meta tag and relative asset URLs. The middleware serves the file as-is, so the JS fetches `/api/graph` instead of `/woods/visualize/api/graph`, and assets resolve to wrong paths.

**Solution**: Use `{{BASE_PATH}}` placeholders in `index.html` for the meta tag, CSS link, and JS script. `serve_html` performs a single `gsub('{{BASE_PATH}}', @path)` before returning the HTML.

**Files**:
- `lib/woods/svelte_flow/rack_middleware.rb` — update `serve_html` to gsub placeholders
- `lib/woods/svelte_flow/assets/index.html` — replace hardcoded paths with `{{BASE_PATH}}`

### Fix 2: JS safeKey mismatch

**Problem**: `app.js` only replaces `::` and `#` when building flow URL keys. Ruby's `safe_key` replaces all non-alphanumeric chars except `_` and `-`. Entry points with dots, spaces, or other special chars produce different keys, causing 404s on flow lookups.

**Solution**: Replace the JS safeKey logic with a regex that mirrors Ruby exactly:
```js
const safeKey = entryPoint.replace(/::/g, '__').replace(/[^a-zA-Z0-9_-]/g, '_');
```

**Files**:
- `lib/woods/svelte_flow/assets/app.js` — fix safeKey regex (1 line)

### Fix 3: Layout drops sink-only nodes

**Problem**: `Layout#initialize` derives `@node_ids` from `edges.keys`, missing nodes that only appear as targets. These nodes get no computed position and pile up at origin (0, 0).

**Solution**: Add optional `node_ids` parameter. Default behavior collects all IDs from both edge keys and edge values. Transformer passes `nodes.keys` explicitly.

**Files**:
- `lib/woods/svelte_flow/layout.rb` — add `node_ids` param, add `collect_all_node_ids`
- `lib/woods/svelte_flow/transformer.rb` — pass `nodes.keys` to Layout

### Fix 4: Layout orientation and large-graph handling

**Problem**: The current layout places topological layers left-to-right, with nodes within each layer stacked vertically. At 6,317 units, layers with hundreds of nodes produce columns tens of thousands of pixels tall — unusable skyscrapers.

**Solution**: Flip layout to top-to-bottom orientation. Layers become horizontal rows, nodes within each layer spread horizontally. Horizontal overflow is natural for scrolling.

Four sub-improvements:

1. **Axis swap**: Layer index maps to y (rows), position within layer maps to x (columns). Constants renamed: `LAYER_SPACING_Y` (vertical gap between rows) and `NODE_SPACING_X` (horizontal gap within rows).

2. **Barycenter ordering within layers**: Instead of alphabetical sort, order nodes by the average position of their connected neighbors in adjacent layers. Minimizes edge crossings (standard Sugiyama step 2).

3. **Dynamic spacing**: Compress horizontal spacing for large layers. Floor at 60px to remain clickable. Full spacing (NODE_SPACING_X) for layers with <= 20 nodes.

4. **Vertical centering**: Center each row around the midpoint of the widest row, keeping cross-layer edges more vertical and reducing visual spread.

**Not included** (out of scope for this fix pass):
- Type-based sub-grouping within layers (can add later if the barycenter ordering isn't sufficient)
- Force-directed layout (wrong tool for a DAG)
- Node filtering/collapsing (frontend feature)
- Canvas virtualization (6K rectangles is within canvas budget)

**Scope of axis swap**: Only affects `#compute` (the dependency graph layout) and `assign_positions`/`assign_layers`. The class methods `flow_positions` (vertical sequential — already uses y-axis correctly) and `cluster_positions` (grid-based with explicit offsets) are not changed.

**Frontend impact**: `app.js` draws edges from `src.position.x + srcW` to `tgt.position.x` (right side to left side of nodes). With top-to-bottom layout, edges should connect bottom of source to top of target instead. `drawEdges` needs to swap its anchor points:
- Source anchor: bottom-center of node (`x + w/2, y + h`)
- Target anchor: top-center of node (`x + w/2, y`)
- Bezier control points adjust accordingly for smoothstep edges

**Files**:
- `lib/woods/svelte_flow/layout.rb` — axis swap, barycenter, dynamic spacing, centering
- `lib/woods/svelte_flow/assets/app.js` — edge anchor points for top-to-bottom flow

### Specs

New and updated specs covering:
- Base-path injection in served HTML (middleware spec)
- Sink-only nodes get positions (layout spec)
- Barycenter ordering reduces naive crossings vs alphabetical (layout spec)
- Large layer dynamic spacing (layout spec)
- Row centering (layout spec)
- safeKey parity between JS regex and Ruby regex (can only be verified manually or via a shared test fixture)

## Test Plan

1. Run gem specs — all existing + new specs pass
2. `gem build woods.gemspec` — produces `.gem` file
3. Copy to host-woods worktree, `bundle update woods`
4. Enable `svelte_flow_enabled = true` in admin Woods initializer
5. Run extraction if needed (`rake woods:extract`)
6. Start Rails server, navigate to `/woods/visualize`
7. Verify:
   - [ ] Page loads (HTML, CSS, JS all resolve)
   - [ ] Dependencies tab shows graph with positioned nodes
   - [ ] Nodes are clickable, sidebar shows details
   - [ ] Zoom/pan works
   - [ ] Clusters tab loads domain clusters
   - [ ] Flows tab loads (if `precompute_flows` was enabled)
   - [ ] No console errors in browser devtools

## Not Fixing

- **Cache headers on assets** — premature for dev-only tool
- **collision_safe_filename for flow exports** — flow index handles lookups correctly
- **MCP tools for svelte flow** — separate feature, not needed for functionality
- **Canvas hitTest O(n)** — acceptable at this scale
