# User Journey v2 — Mode Split Redesign

> **For agentic workers:** Use superpowers:subagent-driven-development to implement this spec.

> **Supersedes sections of** [2026-04-21-user-journey-design.md](./2026-04-21-user-journey-design.md). The original walker, entry-point index, command palette integration, and right-click menu remain valid. This document replaces the "Journey Mode as an overlay on the existing canvas" model with a **dedicated mode** model, and adds one bug fix + one lightweight feature.

## Why this exists

v1 shipped journey mode as a visual overlay that coexisted with the Layers panel and Focus mode. In real use, three problems surfaced:

1. **Palette data flow broken.** `schema.current.entryPoints` is undefined at runtime in the browser even though `/woods/erd/schema.json` returns 16 entries. The ⌘K palette's "Entry Points" group never renders. (Likely cause: `packages/schema` Valibot definition doesn't include `entryPoints`, so the transform drops it.)
2. **Mode collision.** Entering a journey while Focus mode is active leaves the canvas frozen on the focused node while the banner claims a different entry point. Two "what am I looking at?" sources of truth.
3. **Layers hide the journey.** The Layers panel defaults to tables-only. Journey mode's walked nodes are all controllers/jobs/services — so the canvas is empty, and the "dim non-journey nodes to 30%" design makes no difference because there are no non-journey nodes to dim.

Root cause: journey was built as a filter applied on top of existing canvas state. It should be a distinct mode.

## The new model

Two modes. One active at a time.

### Explore (default)

The existing ERD. Unchanged, except:

- **New: "Navigation edges" toggle.** A single checkbox in the canvas chrome overlays `link_to` / `redirect_to` / `form_action` edges on whatever the user is currently viewing. Lightweight — no walk, no depth, no entry point. Answers "what routes are near here?" without committing to journey mode.
- Layers panel and Focus mode behave as today.

### Journey (dedicated)

Entered from ⌘K (Entry Points group) or right-click "Start journey from here." Exited via the banner's Exit button, `Escape`, or the command palette's "Exit journey" entry.

On enter:

- **Snapshot** the current Explore state: `{ enabledLayers, focusedNodeId, viewport }`.
- **Exit Focus mode** if active.
- **Disable the Layers panel** — keep it visible but non-interactive, with a "Controlled by Journey mode" note. Keeping it visible preserves spatial continuity so exiting feels like returning to the same UI, not a different one.
- **Filter the canvas** to only nodes in the walk result. No dimmed context nodes.
- **Auto-frame** the viewport on the walked subgraph.

On exit:

- Restore `{ enabledLayers, focusedNodeId, viewport }` from the snapshot.
- Re-enable the Layers panel (remove the disabled state and the "Controlled by Journey mode" note).

### Mode boundary rules

| Rule | Explore | Journey |
| --- | --- | --- |
| Layers panel | Interactive | Visible but disabled, with "Controlled by Journey mode" note |
| Focus mode | Available | Unavailable (auto-exited on entry) |
| Navigation edges toggle | Available | N/A (journey edges always shown) |
| Entry point banner | Not shown | Shown; Exit button restores Explore |
| Non-walked nodes | All nodes visible | Not rendered |

No partial overlap. No "journey on top of layers." One mode.

## Bug fixes baked into this spec

### Bug 1: entryPoints missing at runtime (BLOCKING)

**Symptom:** ⌘K shows only Controllers group when typing a known entry-point match; Entry Points group never appears.

**Diagnosis:** `EntryPointOptions.tsx` is correctly registered in `CommandPaletteContent.tsx`. Backend emits 16 entries in `schema.json`. Valibot schema in `packages/schema` likely omits `entryPoints` from its object shape, which strips the field during parse/transform.

**Fix:**

1. Add `entryPoints: optional(array(entryPointSchema))` to the Valibot schema in `packages/schema`.
2. Define `entryPointSchema` with `{ identifier, verb, path, controller, action }` string fields.
3. Verify the transform layer (wherever `schema.json` becomes `schema.current`) passes the field through.
4. Add a Vitest test that parses a fixture schema with `entryPoints` and asserts the field survives.

This task comes first. Without it, Journey mode cannot be entered via the palette at all.

### Bug 2: Focus mode collision

Resolved by the mode split above. Entering a journey calls `clearFocus()` (or equivalent) in the ErdContent store. No UI needed — it's automatic.

### Bug 3: Empty canvas from layer filtering

Resolved by the mode split above. Journey mode does not consult the Layers panel.

## New: Navigation edges toggle (Explore mode)

A lightweight alternative for users who don't want the full walk. A single toggle **in the canvas toolbar** (beside zoom / fit controls) that, when on, renders all edges whose `via` is `link_to`, `redirect_to`, or `form_action` on the current canvas. Off by default.

Rationale: burying this in the Layers select menu makes it invisible when the user has non-controller layers hidden — the exact moment they'd want to discover it. Toolbar placement makes it always reachable.

This is not journey mode. No entry point, no walk, no highlighting. Just "show the route edges."

Implementation: a boolean in ErdContent state; when true, `displayEdges` includes edges where `edge.via` is in the navigation set (in addition to whatever's shown today). No new component needed beyond the toggle itself.

## Out of scope for v2

- Changing the walker, edge types, or BFS behaviour (already correct in v1).
- Changing the entry-point index builder (already correct after the 2026-04-21 fixes to `verb`/`http_method` and controller resolution).
- Action-level granularity, session replay, journey persistence — all still deferred.
- A Ruby MCP tool for journey queries.

## Testing

- **packages/schema**: Vitest — add entryPoints to a fixture, round-trip through the schema, assert field preserved.
- **packages/erd-core**: Vitest — `JourneyProvider` snapshot/restore behaviour on `enterJourney`/`exitJourney`. Mock the Layers and Focus stores.
- **packages/erd-core**: Vitest — Navigation edges toggle renders edges when on, omits them when off.
- **Manual smoke**: in the `woods-r8-smoke-app` testbed, pick an entry point from ⌘K, confirm canvas filters + auto-frames, exit, confirm prior layers/focus/viewport restored.

## Migration notes

- `JourneyBanner` stays but drops the edge-type checkboxes (journey always shows all nav edges). Depth dropdown stays.
- `journey.module.css` loses the `:global(.erd-node--outside-journey)` and "dimmed context" styles. Non-journey nodes aren't rendered at all.
- `ErdContent` gains a `navigationEdgesVisible` flag in Explore mode and a "journey mode active" check that supplants the layers filter.

## Self-review checklist

- [x] Addresses all three browser-observed bugs
- [x] No placeholders or TODOs
- [x] Consistent terminology (Explore vs Journey, no "overlay")
- [x] Scope: a single implementation plan
- [x] Backwards-compatible with v1's walker and backend (no schema changes beyond Valibot additions)
