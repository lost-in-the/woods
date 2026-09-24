---
name: backlog-workflow
description: Woods issue workflow — choosing work, implementing with TDD, recording evidence, and reconciling historical backlog IDs.
---

# Backlog Workflow

GitHub issues own active work and acceptance criteria. GitHub Projects organize
those issues; they do not create a second source of implementation status.
See [Contributing](../../../CONTRIBUTING.md#work-tracking).

## 1. Pick an issue

1. Read the issue, recent comments and linked PRs. Check current source before
   treating a historical report as an unfixed bug.
2. Prefer bounded, reproducible issues without unresolved dependencies. Announce
   the issue number and scope before implementation.
3. Treat `release-gate` as required for the next combined candidate,
   `post-release` as explicitly deferred, and `needs-decision` as awaiting a
   maintainer choice. A milestone can also contain recommended cleanup: milestone
   membership alone does not make an issue a blocker.
4. Search open and closed issues before filing another report. Preserve the
   distinction between a current reproduction, source inspection, an old
   observation and a proposed feature.

## 2. Implement and validate

New extractors and extractor features follow strict TDD per CLAUDE.md. Bug fixes
need a regression that fails without the fix. Keep refactors and unrelated
follow-ups separate.

Run focused checks, the default suite and lint as required by CONTRIBUTING.md.
Run booted Rails, installed-artifact or live-backend checks when the behavior
depends on them. Report exact candidate identity and validation limits; a green
validator alone does not prove full/incremental equivalence.

## 3. Close with evidence

1. Update the issue with the implemented scope, PR and test evidence. Use a
   closing reference only when the issue's actual remaining scope is complete.
2. Keep unresolved subitems explicit, or split independently actionable work
   into linked issues. Do not close a mixed ticket merely because one fix merged.
3. Update project status where available. Do not copy issue status into a local
   JSON backlog or claim completion while the relevant checks fail.
4. Keep confidential security findings in the private process described by
   SECURITY.md; public issues must not disclose pending private patch details.

## 4. Historical records and future decisions

- The old `docs/backlog.json` queue is retired. All its B-IDs are preserved in
  `.Codex/backlog-archive.json`, including completed records, approved decisions
  and migration links. `tracked-on-github` means the issue owns live status;
  `not-planned` records a declined proposal. Neither means a bug was fixed.
  Do not refresh archived prose as issues evolve.
- `.Codex/release-v2/backlog-archive.json` preserves the old v2 planning snapshot.
  Its old statuses are historical, not current release requirements.
- New decisions belong in GitHub issues with `needs-decision`. Record the
  maintainer's choice and the reason for closure or implementation there;
  do not label declined proposals as implemented fixes.
- New actionable work goes directly to GitHub. Do not allocate new B-IDs or
  recreate a parallel local work queue.

## Anti-patterns

- Do not leave fixed subitems presented as open defects.
- Do not turn every speculative improvement into a release gate.
- Do not close an intermittent failure as fixed just because retries pass.
- Do not discard historical evidence when archiving or migrating work.
