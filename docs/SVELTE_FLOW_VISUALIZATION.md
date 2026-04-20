# Svelte Flow Visualization

Visualize your Rails application's architecture as interactive node graphs — dependency relationships, domain clusters, and request execution flows — using Svelte Flow-compatible data.

## How It Works

1. **Extract** codebase data with `woods:extract` (the usual pipeline)
2. **Export** visualization data with `woods:svelte_flow_export` (or the alias `woods:map`)
3. JSON files are written to `{output_dir}/svelte_flow/` — ready for any Svelte Flow frontend
4. Optionally, **serve** an interactive visualization page directly from your Rails app

## Two Modes

### Export Mode

Generate Svelte Flow JSON files that can be consumed by any frontend:

```bash
bundle exec rake woods:svelte_flow_export
# Or with the alias:
bundle exec rake woods:map
```

Output structure:

```
tmp/woods/svelte_flow/
  dependency_graph.json     # Full dependency graph with positioned nodes and edges
  domain_clusters.json      # Units grouped by namespace with boundary edges
  flows/
    flow_index.json         # Maps entry points to flow file paths
    UsersController__create.json
    PostsController__index.json
    ...
  manifest.json             # Export metadata (node/edge/flow counts, timestamp)
```

Override output directories via environment variables:

```bash
WOODS_OUTPUT=/path/to/extraction SVELTE_FLOW_OUTPUT=/path/to/output bundle exec rake woods:map
```

### Server Mode

Mount an interactive visualization page in your Rails app:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.svelte_flow_enabled = true
  config.svelte_flow_path = '/woods/visualize'  # default
end
```

Visit `/woods/visualize` in your browser. The page provides three views:

- **Dependencies** — Full dependency graph with nodes colored by type and sized by PageRank
- **Flows** — Request execution flow diagrams (requires `precompute_flows = true`)
- **Clusters** — Domain clusters showing namespace groupings and boundary connections

The middleware lazy-loads data from your extraction output on first request and caches it. When you re-run extraction, the visualization automatically picks up the new data on the next request.

## What Gets Visualized

### Dependency Graph

Every extracted unit (model, controller, service, job, etc.) becomes a node. Dependencies between units become directed edges. Nodes are enriched with:

| Data | Source | Visual Effect |
|------|--------|---------------|
| Unit type | ExtractedUnit | Node color (blue=model, purple=controller, green=service, etc.) |
| PageRank score | DependencyGraph | Node importance weighting |
| Hub status | GraphAnalyzer | Red "HUB" badge on high-dependent-count nodes |
| Bridge status | GraphAnalyzer | Orange "BRG" badge on cross-domain connectors |
| Orphan status | GraphAnalyzer | Dimmed nodes with no dependents |
| Cycle membership | GraphAnalyzer | Red animated edges for circular dependencies |

### Domain Clusters

Units are grouped into semantic domains using namespace prefixes and graph connectivity (via `GraphAnalyzer#domain_clusters`). Each cluster shows:

- Member units with intra-cluster dependency edges
- Hub node (highest PageRank within cluster)
- Entry points (controllers/resolvers that reference the cluster)
- Boundary edges (animated connections crossing cluster boundaries)

### Request Flows

Per-action execution flow traces (from `FlowPrecomputer`) are rendered as sequential step diagrams. Each step shows the unit invoked, its operations (method calls, async jobs, transactions, responses), and the connection to the next step.

**Prerequisite:** Enable flow precomputation in your extraction config:

```ruby
Woods.configure do |config|
  config.precompute_flows = true
end
```

Then re-run extraction:

```bash
bundle exec rake woods:extract
```

## JSON Format

The exported JSON follows the [Svelte Flow](https://svelteflow.dev/) node/edge schema:

### Node

```json
{
  "id": "User",
  "type": "model",
  "position": { "x": 0, "y": 100 },
  "data": {
    "label": "User",
    "unitType": "model",
    "filePath": "app/models/user.rb",
    "namespace": null,
    "pagerank": 0.042,
    "isHub": true,
    "isBridge": false,
    "isOrphan": false
  }
}
```

### Edge

```json
{
  "id": "e-UserService-User",
  "source": "UserService",
  "target": "User",
  "type": "default",
  "data": {
    "relationship": "dependency",
    "isCycle": false
  }
}
```

Node types map to unit types: `model`, `controller`, `service`, `job`, `mailer`, `concern`, `component`, `graphql`, `route`, `middleware`, `decorator`, `rake_task`, `state_machine`, `event`, `factory`, `framework`, `default`.

## API Endpoints (Server Mode)

When `svelte_flow_enabled = true`, the middleware serves:

| Endpoint | Returns |
|----------|---------|
| `GET /woods/visualize` | HTML page with embedded visualization app |
| `GET /woods/visualize/api/graph` | Dependency graph as Svelte Flow JSON |
| `GET /woods/visualize/api/clusters` | Domain clusters as Svelte Flow JSON |
| `GET /woods/visualize/api/flows` | Flow index (entry point → filename mapping) |
| `GET /woods/visualize/api/flows/:key` | Individual flow as Svelte Flow JSON |
| `GET /woods/visualize/assets/*` | Static CSS/JS assets |

Returns `503` with a JSON error message if extraction data is not available.

## Configuration Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `svelte_flow_enabled` | Boolean | `false` | Mount the visualization middleware |
| `svelte_flow_path` | String | `'/woods/visualize'` | URL mount path |
| `precompute_flows` | Boolean | `false` | Generate per-action flow data during extraction (required for flow visualization) |

## Architecture

```
Extraction Output (tmp/woods/)
       │
       ├── dependency_graph.json ──→ Transformer ──→ Layout ──→ NodeBuilder + EdgeBuilder
       ├── graph_analysis ──────────→ GraphAnalyzer ──→ hubs, bridges, orphans, cycles, clusters
       └── flows/ ──────────────────→ FlowDocument ──→ flow nodes + sequential edges
                                              │
                                    ┌─────────┴──────────┐
                                    │                     │
                              Exporter                RackMiddleware
                           (writes JSON)           (serves HTML + API)
```

Key classes:

- `Woods::SvelteFlow::Transformer` — Orchestrates conversion of graph data to Svelte Flow format
- `Woods::SvelteFlow::Layout` — Server-side DAG layout (Kahn's algorithm with PageRank tiebreaking)
- `Woods::SvelteFlow::NodeBuilder` — Maps graph nodes to Svelte Flow node objects with enrichment
- `Woods::SvelteFlow::EdgeBuilder` — Maps graph edges with cycle marking and relationship types
- `Woods::SvelteFlow::Exporter` — Reads extraction output, transforms, writes JSON files
- `Woods::SvelteFlow::RackMiddleware` — Serves the visualization page and JSON API

## Troubleshooting

**"No extraction output found" error**
Run `bundle exec rake woods:extract` before exporting or enabling server mode.

**No flows in the Flows tab**
Enable `config.precompute_flows = true` and re-run extraction.

**Visualization data is stale**
The middleware detects staleness by checking the manifest file timestamp. Re-run extraction and refresh the page.

**Large graphs are slow to render**
The canvas renderer handles graphs with hundreds of nodes. For very large codebases (1000+ units), consider filtering by type before visualization, or use the exported JSON with a custom frontend that supports virtualization.
