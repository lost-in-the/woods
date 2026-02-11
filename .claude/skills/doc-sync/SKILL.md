# Documentation Sync

After any implementation that changes extraction output, dependencies, configuration, or MCP tools, check whether documentation needs updating.

## What to Check

1. **`docs/README.md`** — Is the status table current? Mark completed features, update phase status.
2. **`docs/OPTIMIZATION_BACKLOG.md`** — Is the resolved item marked ✅ with commit ref?
3. **`CLAUDE.md`** — Do the Architecture, Gotchas, or Commands sections reflect the change?
4. **Design docs** — If the change implements something from a design doc, update the doc to reflect what was actually built vs. what was planned.

## Rules

- All configuration examples must show both MySQL and PostgreSQL variants.
- Code examples use realistic class/method names from the project.
- Keep tables for comparison data, prose for explanations.
- Don't update docs speculatively — only reflect changes that have been implemented and tested.
