# Liam ERD Integration — Decision Log

## D1: Data Source
**Decision:** Read from extracted JSON output (`tmp/woods/`), not live AR introspection.
**Why:** The full extraction produces 6,317 units across 34 types. Runtime introspection would duplicate extraction logic. The extracted output already has all the data needed.

## D2: Default View vs Full Graph
**Decision:** Default to schema-only view (212 models with columns, associations, constraints). Additional unit types togglable via UI controls.
**Why:** Rendering all 6,317 units simultaneously is unusable (proven by failed Svelte Flow attempt — 3,802 nodes, unreadable). Progressive disclosure keeps the default useful while exposing the full graph on demand.

## D3: Static Asset Packaging
**Decision:** Vendor pre-built JS/CSS/HTML assets in the gem (`vendor/assets/liam-erd/`). No Node.js required at runtime or install time.
**Why:** "No additional dependencies beyond the Gemfile" is a hard constraint. Consumers get assets via `bundle install`. Maintainer rebuilds and commits assets when frontend changes. Standard pattern (Turbo, Stimulus do this).

## D4: Fork Location
**Decision:** Liam frontend source lives in `frontend/liam-erd/` subdirectory within this repo. Build script compiles to `vendor/assets/liam-erd/`.
**Why:** Modifications to React components (new node types for controllers, jobs, etc.) need to be tracked alongside the Ruby code that generates data for them. `frontend/` directory won't bloat the gem — only `vendor/assets/` is included in `spec.files`.
**Future:** May extract to a separate tool/plugin later to keep the main gem light. Acceptable for now since ERD is development-only tooling.

## D9: Index & Foreign Key Metadata
**Decision:** Add `indexes` and `foreign_keys` as structured metadata keys to `extract_metadata` in ModelExtractor. Reuses existing `ActiveRecord::Base.connection.indexes` and `.foreign_keys` calls that are already in `build_schema_comment`.
**Why:** Currently only rendered as comment strings in source_code, not available as structured data. ERD needs them, and it enriches the extracted data for all consumers. Transform layer gracefully skips if keys are absent (pre-existing extractions still work).
**Impact:** ~10 lines added to model_extractor. Requires re-extraction to populate.

## D8: Phasing
**Decision:** Three phases. Current effort targets Phase 1 (MVP) only.
- **Phase 1 (MVP):** Rack middleware + vendored Liam assets + schema JSON from extracted models (tables, columns, FK constraints). Config: `erd_enabled`, `erd_path`. 212 models out of the box.
- **Phase 2:** Fork erd-core for non-table node types, toggle UI for controllers/services/jobs, dependency edges, type-aware rendering.
- **Phase 3:** Deep-linkable URLs, agent-friendly URL generation (`?focus=OrdersController&depth=2`), flow path highlighting.

## D7: Non-Model Unit Representation
**Decision:** Extend Liam's schema format (option A) — add a `nodes` concept alongside `tables` with type-aware rendering. Non-model units show their members (methods, actions, queue config) as fields, but rendered with appropriate styling rather than as database columns.
**Why:** Cramming everything into Liam's table format (option B) creates semantic mismatch — column metadata (type badges, null indicators) is meaningless for controller actions. Since we're already forking, proper node types are cleaner.
**Goal:** Visualize data/request flow paths (A -> B -> C) so users can understand how things connect. Future: agents could pass a URL pointing to a specific path through the graph for user inspection.
**Key insight:** Woods reduces need for deep codebase knowledge by deferring to agents, but visual flow inspection remains valuable context — especially when an agent can link directly to a rendered path.

## D6: Middleware Approach
**Decision:** Single Rack middleware that serves vendored static assets and generates `schema.json` dynamically from extracted units on first request, cached in memory.
**Why:** Follows existing console MCP middleware pattern (lazy init, configurable path via Railtie). Avoids "forgot to regenerate" problem. JSON transformation is lightweight — 212 models with columns/associations is small enough to transform and cache on first request.

## D5: Liam ERD License
**Fact:** Apache License 2.0. Allows modification, distribution, and embedding. Third-party package licenses documented in `docs/packages-license.md`.
