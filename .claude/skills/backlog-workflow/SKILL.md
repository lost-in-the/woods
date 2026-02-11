# Backlog Workflow

The primary task source is `docs/OPTIMIZATION_BACKLOG.md`.

## Picking Work

1. Read the backlog. Items are grouped into numbered batches at the bottom — follow the batch order.
2. Check resolved status (✅) before starting — another session may have completed it.
3. Skip items marked "Deferred" unless their stated blocker has been resolved.
4. If the item touches a design area (retrieval, chunking, MCP, etc.), read the corresponding `docs/` file before starting.

## Completing Work

1. Implement with TDD — see Testing Workflow in CLAUDE.md.
2. Mark the item resolved in `OPTIMIZATION_BACKLOG.md`: add ✅, resolution summary, and commit ref.
3. Commit the backlog update alongside the implementation.

## Adding New Work

When identifying new work during a session (bugs, optimizations, edge cases), add it to the backlog under the appropriate category rather than fixing it immediately — unless it blocks the current task. Include: item number, file paths, description of the problem, and a suggested fix.

## Verification

After completing a batch, run the verification checklist at the bottom of the backlog file.
