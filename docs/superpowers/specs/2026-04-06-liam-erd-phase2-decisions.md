# Liam ERD Phase 2 — Decision Log

## PD1: Progressive Disclosure Strategy
**Decision:** Hybrid approach — layer toggles in toolbar (off by default) + sidebar focus mode for drill-down. Models-only is the default view.
**Why:** Rendering all 6,317 units is unusable (proven by failed Svelte Flow attempt). Layer toggles serve small apps that can show everything; focus mode serves large apps where drilling down is easier than building up. Both coexist without a mode switcher.

## PD2: Node Visual Style
**Decision:** Color-coded card nodes (Option A) — same rectangular shape as table nodes with colored header bar per type, simplified member rows (name only, no type/null badges).
**Why:** Minimal fork work — reuse table node component structure with conditional rendering. Visually distinct via color, not shape. WCAG-compliant palette against dark theme.

## PD3: Unit Type Tiering
**Decision:** Tier 1 (Phase 2): controllers, jobs, services, mailers. Tier 2 (future): concerns, policies, serializers, decorators. Tier 3 (Phase 3+): routes, middleware, engines, migrations, configs.
**Why:** Tier 1 types have well-defined members (actions, methods, params), connect directly to models via dependencies, and represent the most common "what touches this model?" question. Tier 2 is useful but niche. Tier 3 is structural/meta.

## PD4: Edge Visual Encoding
**Decision:** Two edge categories: Data (solid, existing green) and Dependency (dashed, source-type colored). Not 35 distinct styles.
**Why:** Encoding all 35 `:via` relationship types is unreadable. Two categories cover the essential distinction: "database relationship" vs. "code dependency." Hover tooltip reveals the specific `:via` type for detail.

## PD5: Edge Toggle Independence
**Decision:** Data edges can be hidden independently of model node visibility. Toggling off data edges while keeping models visible enables an "impact analysis" view.
**Why:** User need: "show me everything this model touches beyond the database." Hiding FK spaghetti while keeping model context produces a clean dependency-only view. No dedicated mode needed — falls out of toggle combinations naturally.

## PD6: Hover vs. Selection Colors
**Decision:** Selected node uses its type's own color (green for tables, blue for controllers, etc.). Hovered node uses a neutral accent distinct from all type colors.
**Why:** Current Liam behavior uses the same green for both selected and hovered nodes, making it impossible to distinguish "what I clicked" from "what I'm exploring" in a dense graph.

## PD7: Fork Strategy
**Decision:** Shallow fork — copy only erd-core, db-structure, and cli packages into `frontend/liam-erd/`. Strip monorepo tooling.
**Why:** We're making fundamental changes (new node types, new schema fields) that upstream won't accept. We only need 2-3 packages. Full monorepo carries ~50+ unused packages. If shallow fork hits coupling issues, fall back to full monorepo.

## PD8: Configuration
**Decision:** New `erd_layers` config (array of symbols, default `[:models]`). Controls which types SchemaGenerator includes in output.
**Why:** Backward compatible — default matches Phase 1 behavior. Users opt in to non-model layers. Prevents bloating schema.json for users who only want the database view. `:models` is always included (can't have a graph without the data layer).

## PD9: Focus Mode Behavior
**Decision:** Focus narrows to the focused unit + connected units, filtered by active layer toggles. "Exit Focus" button returns to full view.
**Why:** Focus on a model with only controllers toggled on shows just that model's controllers — not every possible connection. Respecting active layers gives users fine-grained control without a separate filter UI.
