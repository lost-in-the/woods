<a id="generated-self-analysis-output"></a>

# Self-analysis and historical audits

This directory holds generation instructions and handwritten historical receipts.
For current user guidance and documentation ownership, start at the
[documentation index](../README.md#canonical-owners).

## Generate a local diagram

From the Woods source checkout, with its development bundle available:

```bash
bin/rake woods:self_analyze
```

The task runs Woods' static analyzer over `lib/woods/`, writes JSON and a checksum
manifest under ignored `tmp/woods_self/`, and renders
`docs/self-analysis/architecture.md`. That single artifact embeds the call graph,
dependency map, data flow, and analysis summary; the standalone duplicates were
removed for 2.0.0. Generated output belongs in ignored local files. Regenerate it
rather than editing or committing it. It is static diagnostic evidence, not proof
of Rails runtime behavior.

The task skips work when the manifest's checksum of `lib/**/*.rb` is unchanged.
If the diagram is missing while a matching manifest remains, move
`tmp/woods_self/manifest.json` aside and rerun the command. The helper
[`scripts/regenerate-self-analysis.sh`](../../scripts/regenerate-self-analysis.sh)
runs the same task only when `lib/` has staged changes. It analyzes the working
tree, not the staged versions, and never stages files. Run the task directly for
an explicit refresh; inspect its output before using it as evidence.

## Preserved diagram receipt

Recorded 2026-10-27 at checkout baseline
[`3e36cd22`](https://github.com/lost-in-the/woods/tree/3e36cd22de5b1e484bacb913c4ad827d9f726d80):
the retained diagram is 1,062,529 bytes (13,512 lines), last changed on
2026-09-02 in
[`6c87ed35`](https://github.com/lost-in-the/woods/commit/6c87ed357346a2ad0a0dd0b4393e41b2234184a8).
Read the [pinned historical diagram](https://github.com/lost-in-the/woods/blob/6c87ed357346a2ad0a0dd0b4393e41b2234184a8/docs/self-analysis/architecture.md)
without generating a local copy. Its SHA-256 is:

```text
350a2cbb8f8ef72141e532fafe201a390e4ed9cb73be6dc91ad945fe41d18e18
```

This identifies the preserved bytes and their Git history; it does not establish
their generation time or that they describe today's source. No diagram was
regenerated for the 2026-10-27 housekeeping pass.

## Historical handwritten records

- [Round 2 audit](v2-audit-2/README.md): findings, security and regression evidence,
  and validation limits recorded on 2026-09-01 against `79c156d`.
- [Documentation review](v2-docs-review.md): the 2026-09-03 review, with its
  original measurements and recommendations retained.
- [Reconciled documentation plan](../design/plans/2026-09-03-v2-documentation-rewrite-reconciled.md):
  the rewrite reconciliation and its recorded 2026-09-03 execution.

The 2026-09-24 disposition of [#498](https://github.com/lost-in-the/woods/issues/498)
records the accuracy repairs in [#612](https://github.com/lost-in-the/woods/issues/612)
and [#616](https://github.com/lost-in-the/woods/pull/616), plus README and setup
passes, as complete. Active backlog migration shipped in
[#629](https://github.com/lost-in-the/woods/pull/629). The remaining follow-up is
generated-diagram tracking and classification of these historical receipts.

These receipts retain their paths and original evidence. They do not define a
current release gate or imply that every finding is still open or resolved.
[GitHub issues](https://github.com/lost-in-the/woods/issues) own active work;
[work tracking](../../CONTRIBUTING.md#work-tracking) explains the archived B-ID
records and issue migration.

None of this directory ships in the packaged gem — `woods.gemspec` includes only top-level `docs/*.md`.
