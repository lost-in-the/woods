# Liam ERD Integration — Phase 2 Design Spec

**Date:** 2026-04-06
**Branch:** `erd`
**Base:** Phase 1 (complete, merged)
**Scope:** Phase 2 — Non-model node types, layer toggles, focus mode, dependency edges

## Overview

Extend the Woods ERD visualization beyond the database layer. Fork `@liam-hq/erd-core` to add non-model unit types (controllers, jobs, services, mailers) as color-coded card nodes with type-aware rendering, a toolbar toggle UI for unit type layers, sidebar focus mode, and cross-type dependency edges.

## Goals

- Render non-model extracted units as distinct, color-coded nodes alongside existing table nodes
- Provide toolbar toggles for showing/hiding unit type layers and edge categories
- Implement sidebar focus mode to narrow the view to one unit and its connections
- Display cross-type dependency edges with visual distinction from FK edges
- Maintain progressive disclosure: models-only by default, layers opt-in
- WCAG-compliant color palette for dark theme

## Non-Goals (Phase 2)

- Tier 2 unit types (concerns, policies, serializers, decorators) — schema supports them, no frontend nodes yet
- Deep-linkable URLs (`?focus=OrdersController&depth=2`)
- Agent-friendly URL generation
- Flow path highlighting (animated A → B → C traces)
- Search across non-model nodes
- Mobile/responsive layout
- Upstream Liam sync mechanism

## Architecture

### Data Flow

```
Extracted JSON (tmp/woods/)
  → SchemaGenerator reads model + Tier 1 units
  → Transforms to extended schema format (tables + nodes)
  → Cached in memory by RackMiddleware
  → Served as schema.json
  → Forked Liam SPA parses tables + nodes
  → React Flow renders table nodes + WoodsNode custom nodes
  → ELK layouts mixed-type graph
  → Toolbar toggles control visibility
  → Sidebar focus mode filters to subgraph
```

### File Layout

```
frontend/
└── liam-erd/                          # Shallow fork of Liam packages
    ├── packages/
    │   ├── erd-core/                  # Main React Flow visualization (primary changes)
    │   ├── db-structure/              # Schema types + parsing (extend for nodes)
    │   └── cli/                       # SPA shell (minimal changes)
    ├── package.json                   # Standalone workspace config
    └── vite.config.*
lib/
├── woods/
│   ├── erd/
│   │   └── schema_generator.rb       # Extended: reads Tier 1 units, outputs nodes
│   └── ...
vendor/
└── assets/
    └── liam-erd/                      # Rebuilt from frontend/liam-erd/
scripts/
└── build-liam-erd.sh                  # Updated: builds from local fork
```

## Schema Extension

### Current Format (Phase 1)

```json
{
  "tables": { "<table_name>": { "name", "columns", "indexes", "constraints" } },
  "enums": {},
  "extensions": {}
}
```

### Extended Format (Phase 2)

Add a `nodes` top-level key alongside `tables`:

```json
{
  "tables": { ... },
  "nodes": {
    "OrdersController": {
      "name": "OrdersController",
      "type": "controller",
      "members": [
        { "name": "index" },
        { "name": "create" },
        { "name": "show" }
      ],
      "meta": { "action_count": 3 },
      "dependencies": [
        { "target": "orders", "target_type": "table", "via": "code_reference" },
        { "target": "OrderCreator", "target_type": "service", "via": "call" }
      ]
    }
  },
  "enums": {},
  "extensions": {}
}
```

| Field | Description |
|-------|-------------|
| `name` | Display name (class name) |
| `type` | Unit type string — drives rendering (color, layout) |
| `members` | Simplified row list: `{ name }` only, no type badges or null indicators |
| `meta` | Type-specific header metadata (queue name, callable badge, etc.) |
| `dependencies` | Edges to other nodes/tables with `target`, `target_type`, and `via` |

The `tables` structure is unchanged. Table-to-table FK edges still come from constraints. Cross-type edges come from `nodes[].dependencies`.

## Unit Type Tiers

### Tier 1 (Phase 2 — implemented)

| Type | Header | Members | Header Meta |
|------|--------|---------|-------------|
| **Controller** | Class name | Actions: `index`, `create`, `show`, etc. | Action count badge |
| **Job** | Class name | `perform` params | Queue name |
| **Service** | Class name | Public methods | `callable` badge if responds to `.call` |
| **Mailer** | Class name | Mail actions | Delivery method if non-default |

### Tier 2 (future — schema supports, no frontend nodes)

| Type | Header | Members | Header Meta |
|------|--------|---------|-------------|
| **Concern** | Module name | Methods defined | Scope badge (model/controller) |
| **Policy** | Class name | Auth rules (`index?`, `create?`) | — |
| **Serializer** | Class name | Attributes | Format |
| **Decorator** | Class name | Decorated methods | — |

## Frontend Architecture

### Fork Strategy: Shallow Fork

Copy only the packages we modify into `frontend/liam-erd/`:

- `packages/erd-core/` — custom node types, edge styles, toolbar, focus mode
- `packages/db-structure/` — schema type definitions, extended parser
- `packages/cli/` — SPA shell, minimal changes (pass `nodes` through)

Strip Liam's monorepo tooling (turbo, unrelated packages). Maintain standalone `package.json` and Vite config. Rationale: we're making fundamental changes (new node types, new schema fields) that diverge from upstream. Keeping only what we need makes the fork comprehensible and maintainable.

If the shallow fork proves insufficient (deep coupling to uncopied packages), fall back to a full monorepo fork.

### Component Changes

#### 1. WoodsNode — Custom React Flow Node

Color-coded card component for non-model units. Same rectangular shape as table nodes with:

- Colored header bar per type
- Simplified member rows (name only — no type badges, null indicators, key icons)
- Type icon in header
- Meta info in header area (queue name for jobs, action count for controllers)

#### 2. Toolbar Extension

Add a dropdown/popover next to the existing "Key Only" control:

**Node layer toggles:**
- Controllers (off by default)
- Jobs (off by default)
- Services (off by default)
- Mailers (off by default)

**Edge layer toggles:**
- Data edges (on by default) — FK constraint lines
- Dependency edges (on when any non-model layer is active) — cross-type connections

Toggling a node layer on adds all nodes of that type to the canvas with their dependency edges. Toggling data edges off hides FK spaghetti while keeping model nodes visible for context — enables the "impact analysis" view.

#### 3. Sidebar Extension

Existing table list stays. Below or in a tabbed view, non-model units grouped by type. Each item has a **Focus** button.

#### 4. Focus Mode

Clicking Focus on any sidebar item (model or non-model):

- Hides all unrelated nodes
- Shows the focused node + nodes connected to it (filtered by active layer toggles)
- "Exit Focus" button or breadcrumb to return to full view
- Focus on a table shows connected non-model nodes
- Focus on a controller shows connected models + services
- Focus respects active layers: if jobs toggle is off, connected jobs stay hidden even in focus mode

#### 5. Edge Rendering

Two visual categories:

| Edge Style | Relationship Types | Visual |
|------------|-------------------|--------|
| **Data** | FK constraints, belongs_to/has_many | Solid line, existing green |
| **Dependency** | code_reference, call, job_enqueue, render, include, extend, inherit, route_dispatch, etc. | Dashed line, colored by source node type |

Hover tooltip shows the specific `:via` relationship type (e.g., "job_enqueue", "code_reference").

Data and dependency edges can be toggled independently via the toolbar.

#### 6. Hover vs. Selection Distinction

Fork existing highlight behavior:

- **Selected node**: Node type's own color for border + connected edges (green for tables, blue for controllers, etc.)
- **Hovered node**: Neutral accent color distinct from all type colors (warm white or gold) for border + connected edges

Ensures "what I clicked" is always visually distinct from "what I'm exploring."

## Color Palette

Dark theme, WCAG compliant. All colors target **4.5:1 contrast ratio** for text against the dark background, **3:1** for UI elements (borders, edges).

| Node Type | Header Color | Rationale |
|-----------|-------------|-----------|
| Model/Table | Existing green (~`#4ade80`) | No change |
| Controller | Blue (`#60a5fa`) | HTTP/request layer |
| Job | Amber (`#fbbf24`) | Async/background |
| Service | Purple (`#c084fc`) | Business logic |
| Mailer | Rose (`#f472b6`) | Communication |
| Concern (Tier 2) | Teal (`#2dd4bf`) | Mixin/shared |
| Policy (Tier 2) | Red (`#f87171`) | Authorization/guard |
| Serializer (Tier 2) | Slate (`#94a3b8`) | Data formatting |
| Decorator (Tier 2) | Indigo (`#818cf8`) | Presentation |

**Hover accent:** Neutral color distinct from all type colors — warm white (`#e2e8f0`) or gold (`#facc15`). Final choice validated during implementation against actual background.

Palette validated against actual background during implementation — these are starting points.

## SchemaGenerator Extension (Ruby)

### New Behavior

- Reads Tier 1 unit directories: `controllers/`, `jobs/`, `services/`, `mailers/`
- Transforms each unit into the `nodes` schema format:
  - Controllers → `metadata.actions` as members, `metadata.action_count` as meta
  - Jobs → `metadata.perform_params` as members, `metadata.queue` as meta
  - Services → `metadata.public_methods` as members, `metadata.is_callable` as meta
  - Mailers → `metadata.actions` as members, `metadata.delivery_method` as meta
- Maps `dependencies` from each unit's existing dependency data, resolving targets to `table` (if matching a known table name) or the appropriate node type
- Gated by `erd_layers` configuration

### No Extractor Changes

All metadata needed is already extracted by existing extractors. Phase 2 is purely a read + transform layer in `SchemaGenerator`.

## Configuration

New attribute on `Woods::Configuration`:

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `erd_layers` | Array<Symbol> | `[:models]` | Unit types included in schema.json |

Usage:

```ruby
Woods.configure do |config|
  config.erd_enabled = true
  config.erd_layers = [:models, :controllers, :jobs, :services, :mailers]
end
```

- `:models` is always included (cannot be removed — the data layer is the foundation)
- Setting additional layers triggers `SchemaGenerator` to populate the `nodes` key
- Default `[:models]` is backward compatible with Phase 1

## Build & Integration

### Build Script

`scripts/build-liam-erd.sh` updated:

- Builds from `frontend/liam-erd/` instead of cloning upstream
- `cd frontend/liam-erd && pnpm install && pnpm build`
- Output still goes to `vendor/assets/liam-erd/`
- No upstream version pinning — fork has its own versioning

### Rack Middleware

No changes. Middleware serves `schema.json` dynamically — doesn't inspect the JSON shape. Frontend consumes the new `nodes` key.

### Schema Caching

Existing cache-on-first-request approach unchanged. Layer config changes require middleware restart (same as Phase 1 — extraction output is static between runs).

## Testing

### Ruby Side (Gem Unit Specs)

**`spec/erd/schema_generator_spec.rb`** — extend existing tests:

- Generating `nodes` from controller/job/service/mailer mock units
- Member extraction per type (actions → members, params → members, methods → members)
- Dependency mapping (target resolution to table vs. node type)
- `erd_layers` config filtering (only requested types included in output)
- Graceful degradation: missing directories produce no nodes for that type, no error
- Edge case: unit with no dependencies produces node with empty dependencies array

**`spec/configuration_spec.rb`:**

- `erd_layers` default value
- Custom `erd_layers` values

### Frontend (in `frontend/liam-erd/`)

- Unit tests for `WoodsNode` component rendering per type
- Unit tests for extended schema parser (handles `nodes` key)
- Unit tests for toolbar toggle state management
- Unit tests for focus mode filtering logic

No E2E browser tests in Phase 2. Manual validation against real extraction data (212 models + Tier 1 units) in the host app.

### Integration Validation

Run extraction in host app → rebuild frontend assets → verify ERD renders at `/woods/erd` with layer toggles, focus mode, and dependency edges functioning.

## Changes to Existing Files

| File | Change |
|------|--------|
| `lib/woods.rb` | Add `erd_layers` to Configuration |
| `lib/woods/erd/schema_generator.rb` | Extend to read Tier 1 units, output `nodes` |
| `scripts/build-liam-erd.sh` | Build from local fork instead of upstream clone |
| `vendor/assets/liam-erd/*` | Rebuilt from forked frontend |
| `spec/erd/schema_generator_spec.rb` | Tests for node generation, layer filtering |
| `spec/configuration_spec.rb` | Test for `erd_layers` |

## New Files

| File | Purpose |
|------|---------|
| `frontend/liam-erd/` | Shallow fork of Liam packages (erd-core, db-structure, cli) |
| `docs/superpowers/specs/2026-04-06-liam-erd-phase2-decisions.md` | Phase 2 decision log |

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Shallow fork viability | erd-core may have deep coupling to uncopied packages | Validate fork builds before writing features; fall back to full monorepo fork |
| ELK layout with mixed node types | Poor auto-layout when non-table nodes are added | Test with real data early; tune ELK spacing/layer options |
| Schema.json payload size | 6,317 units could produce large payload | `erd_layers` defaults to models-only; measure with all Tier 1 enabled |
| React Flow performance | Many cross-type edges may degrade interaction | Layer toggles limit visible nodes; focus mode caps subgraph size |

## Future Phases (Out of Scope)

- **Phase 3:** Deep-linkable URLs, agent-friendly URL generation, flow path highlighting, Tier 2 node types

## Decision Log

See `docs/superpowers/specs/2026-04-06-liam-erd-decisions.md` for Phase 1 decisions (D1-D9). Phase 2 decisions to be recorded in `docs/superpowers/specs/2026-04-06-liam-erd-phase2-decisions.md`.
