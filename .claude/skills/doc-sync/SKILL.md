---
name: doc-sync
description: Checks if documentation needs updating after implementation changes
disable-model-invocation: true
---
# Documentation Sync

After any implementation that changes extraction output, dependencies, configuration, or MCP tools, check whether documentation needs updating.

## What to Check

1. **`docs/README.md`** — Is the status table current? Mark completed features, update phase status.
2. **`docs/backlog.json`** — Is the resolved item's `status` flipped to `resolved`? (The build-phase design-doc backlog this superseded was removed for 2.0 — see `git log --follow -- docs/design/`.)
3. **`CLAUDE.md`** — Do the Architecture, Gotchas, or Commands sections reflect the change?
4. **`docs/design/`** — If the change implements something from a live design doc (`MCP_2026_STRATEGY.md`, `MCP_2026_NEXT_STEPS.md`), update it to reflect what was actually built vs. what was planned.

## Rules

- All configuration examples must show both MySQL and PostgreSQL variants.
- Code examples use realistic class/method names from the project.
- Keep tables for comparison data, prose for explanations.
- Don't update docs speculatively — only reflect changes that have been implemented and tested.
