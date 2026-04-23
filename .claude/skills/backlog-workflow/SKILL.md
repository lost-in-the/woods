---
name: backlog-workflow
description: Woods backlog workflow — picking items, implementing with TDD, marking resolved, and adding new work. Use when the user asks "what's next?", references backlog items, opens a session without a clear task, or when closing out work to record what shipped.
---

# Backlog Workflow

Woods tracks work in `docs/backlog.json`. Each entry carries an id, title,
description, status, and optional effort estimate. The workflow below is
the canonical path from "what do I pick?" to "what did I ship?"

## 1. Pick an item

1. Read `docs/backlog.json` and `docs/COVERAGE_GAP_ANALYSIS.md` /
   `docs/USE_CASES_AND_FEATURE_GAPS.md` for context.
2. Prefer items that are:
   - `status: "ready"` (not `"blocked"` or `"in-progress"`)
   - Small enough to complete in a session (effort S or early-M)
   - Not dependent on an unfinished item
3. Announce the pick — quote the id and title verbatim so the user can
   redirect before any code changes.

## 2. Implement with TDD

New extractors and new features in existing extractors are **strict TDD**
per CLAUDE.md:

1. Write a failing spec in `spec/` that describes the desired behaviour.
2. Implement the smallest change to pass the spec.
3. Refactor under green.

Bug fixes: fix first, then add a regression test that would have caught
it. Refactors: lean on existing specs; add coverage *before* refactoring
if gaps exist.

Run the relevant spec file after every edit; run the full suite
(`bin/rspec`) before marking the item done. Lint via `bundle exec
rubocop -a`.

Host-app validation: if the change affects extraction output, re-run
against `woods-testbed` per `.claude/rules/integration-testing.md`.

## 3. Mark the item resolved

1. Update `docs/backlog.json`:
   - Flip `status` from `ready` (or `in-progress`) to `resolved`.
   - Add a `resolved_at` timestamp (ISO 8601 date).
   - Add a `resolved_by` PR ref or commit SHA if one exists.
2. Cross-check sibling docs — if the item is referenced in
   `COVERAGE_GAP_ANALYSIS.md` or `USE_CASES_AND_FEATURE_GAPS.md`, move
   its line to a "Resolved" section or strike it.
3. Update `.claude/context/session-state.md` with a one-line breadcrumb.

## 4. Add new work discovered along the way

When implementing reveals new bugs, gaps, or follow-ups:

1. Do **not** expand scope of the current item. Keep the PR focused.
2. Append a new backlog entry to `docs/backlog.json` with:
   - Unique id (next integer after the current max).
   - `status: "ready"` if actionable, `"needs-triage"` if unclear.
   - Brief rationale that references the item you discovered it from.
3. Mention the new id in the PR description so reviewers see the trail.

## Format reference

Backlog entries look like:

```json
{
  "id": 42,
  "title": "Short imperative title",
  "description": "One-paragraph rationale + acceptance criteria.",
  "status": "ready",
  "effort": "S",
  "owner": null,
  "resolved_at": null,
  "resolved_by": null
}
```

## Anti-patterns

- Don't silently add code that isn't tied to a backlog entry. Either
  open an item first or bundle it into an existing in-progress item.
- Don't mark `resolved` while specs are red or the full suite has
  failures the change caused.
- Don't delete a resolved item — keep it in the archive so reviewers
  can trace history.
