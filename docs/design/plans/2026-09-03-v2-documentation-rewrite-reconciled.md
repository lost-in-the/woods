# Woods 2.0 documentation rewrite: reconciled plan

Reconciles `2026-08-27-v2-documentation-rewrite.md` against the branch as of 2026-09-03. Classifies all 49 original tasks, then lists the work that actually remains.

## Bottom line

**37 of 49 tasks are done. The original plan shipped in PR #245 on 2026-08-27 and nobody checked the boxes.** Four are stale: their acceptance criteria are now false or the target version moved. Eight are undone, and every one of them describes the same missing change in the paired `lost-in-the/plugins` repository.

| Classification | Rows | Meaning |
|---|---:|---|
| Done | 37 | Delivered and verifiable at HEAD |
| Stale | 4 | Overtaken by later work; the check can no longer pass as written |
| Still to do | 8 | Not delivered; verified missing 2026-09-03 |

**Those 8 undone rows are one piece of work, not eight.** Task 8's four steps, Task 10's three marketplace steps, and checklist items 518 and 520 all resolve to a single two-file edit plus a PR. It is item R1 below.

**The single most misleading thing about the original file is that it reads as 0% complete.** Retire it rather than continue it.

### The commits that delivered it

| SHA | Date | What it delivered |
|---|---|---|
| `1b2d281` | 2026-08-27 | The spec and plan themselves (Task 1) |
| `426dc25` | 2026-08-27 | The public rewrite: README, docs index, GETTING_STARTED, AGENT_SETUP (new), MCP_SERVERS, AGENT_GUIDE, UPGRADING_TO_2, FAQ (Tasks 2-5) |
| `8c6d30a` | 2026-08-27 | CONTRIBUTING and AGENTS separation (Task 6) |
| `ee61f5e` | 2026-08-27 | Three plugin skills rewritten, plugin.json bumped (Task 7) |
| `b21823d` | 2026-08-27 | Merge of PR #245 from `docs/v2-documentation-rewrite` (Task 10) |

## Classification: all 49 tasks

Line numbers refer to the original plan file.

### Task 1: Commit the design and plan

| L | Step | Class | Evidence |
|---:|---|---|---|
| 40 | Check design for incomplete markers | Done | One-time gate before `1b2d281`; both files committed with no markers |
| 52 | Confirm planned files exist, `AGENT_SETUP.md` does not | **Stale** | The check asserts `test ! -e docs/AGENT_SETUP.md`. That file was created by `426dc25` and is 205 lines. The check can never pass again |
| 68 | Commit the planning checkpoint | Done | `1b2d281` "docs: plan the v2 documentation rewrite", +790 lines across the spec and plan |

### Task 2: Replace the public entry points

| L | Step | Class | Evidence |
|---:|---|---|---|
| 88 | Rewrite `README.md` from scratch | Done | `426dc25` changed README.md by 667 lines, net large reduction. Section order differs from the plan's 7-item list; see remaining item R4 |
| 102 | Rewrite `docs/README.md` as a task router | Done | `426dc25` changed it by 152 lines. `docs/README.md:5` now opens "What are you trying to do?" with all eight required rows |
| 117 | Verify entry-point structure and size | **Stale** | Acceptance was "README 180-260 lines". README is 286 lines after `79bf994` (badges, branch notice) and `67a8759` (agent install). `docs/README.md` at 111 lines is in range. The size gate was overtaken by deliberate later additions |

### Task 3: Human and agent installation paths

| L | Step | Class | Evidence |
|---:|---|---|---|
| 143 | Rewrite `docs/GETTING_STARTED.md` | Done | `426dc25`, 425 lines changed. All eight required subsections present, including the first-run failure table at `docs/GETTING_STARTED.md:157` |
| 156 | Write `docs/AGENT_SETUP.md` | Done | `426dc25` created it. All eight runbook steps plus the copyable prompt at `docs/AGENT_SETUP.md:195` |
| 171 | Remove conflicting FAQ setup duplication | Done | `426dc25`, FAQ.md 81 lines changed. `docs/FAQ.md:47` is now three sentences and a link |
| 175 | Verify setup commands against source | Done | Re-verified 2026-09-03: `woods:extract`, `woods:validate`, `woods:stats`, `woods:watch` each defined once in `lib/tasks/woods.rake` and each cited in both guides |

### Task 4: MCP setup and agent usage

| L | Step | Class | Evidence |
|---:|---|---|---|
| 200 | Rewrite `docs/MCP_SERVERS.md` | Done | `426dc25`, 393 lines changed. All ten ordered items present; the 14-tool table is at `docs/MCP_SERVERS.md:106` |
| 217 | Rewrite `docs/AGENT_GUIDE.md` | Done | `426dc25`, 569 lines changed, now 196 lines. Opens with the status-search-lookup-traverse loop |
| 227 | Compare every named tool with the inventory | Done | Re-verified: 14/9/11/29/31 appear consistently across README, AGENTS, CLAUDE, 9 docs files, 3 plugin skills. No misspelled or removed names |
| 238 | Verify forbidden recommendations are gone | Done | Re-ran the plan's own grep against both files on 2026-09-03: no output |

### Task 5: Upgrade guide

| L | Step | Class | Evidence |
|---:|---|---|---|
| 260 | Build a required-action summary | Done | `docs/UPGRADING_TO_2.md:7` "Upgrade outcome" and `:18` "What changes" table, 20 rows |
| 269 | Rewrite the migration sequence | Done | `426dc25`, 381 lines changed. Sections at `:42`, `:75`, `:124`, `:167`, `:179`, `:197` cover all ten steps |
| 284 | Add rollback and agent handoff | Done | `docs/UPGRADING_TO_2.md:267` "Roll back", `:281` "Agent-operated upgrade prompt" |
| 288 | Verify environment variables | Done | Re-verified: all five documented vars (`WOODS_ALLOW_PURGE`, `WOODS_CONSOLE_MCP_TOKEN`, `WOODS_NOTION_FORCE`, `WOODS_OBSIDIAN_FORCE_PURGE`, `WOODS_OUTPUT`) resolve to a definition under `lib/` |

### Task 6: Contributor policy vs coding-agent instructions

| L | Step | Class | Evidence |
|---:|---|---|---|
| 311 | Rewrite `CONTRIBUTING.md` | Done | `8c6d30a`, 211 lines changed. Channels, setup, repository table, validation ladder, matrix, sync, PR evidence |
| 315 | Rewrite `AGENTS.md` | Done | `8c6d30a`, 168 lines changed. Repository map, read-before-edit, invariants, doc ownership, plugin pairing, completion checklist |
| 319 | Check command consistency | Done | Re-verified: `bin/rake`, `bin/rspec`, `bin/rubocop`, `BUNDLE_GEMFILE` present in all three files. `WOODS_RUN_*` differs by audience, which is correct and locally explained |

### Task 7: Plugin skills

| L | Step | Class | Evidence |
|---:|---|---|---|
| 343 | Rewrite `woods-setup` | Done | `ee61f5e`, 231 lines changed, now 97 lines |
| 347 | Rewrite `woods-mcp-config` | Done | `ee61f5e`, 281 lines changed, now 101 lines |
| 351 | Tighten `woods-diagnose` | Done | `ee61f5e`, 221 lines changed, now 73 lines |
| 355 | Bump `plugin.json` from 2.0.0 to 2.0.1 | **Stale** | Bumped by `ee61f5e`, then again by `bc7565d` and `fd70d49`. Current value is **2.2.0**. The named target version is obsolete; the intent is satisfied |
| 359 | Validate the plugin | Done | Re-runnable gate. Two more skills shipped since (`woods-investigate`, `woods-agent-enable`), so the plugin now has 5 skills, not 3 |

### Task 8: Paired marketplace metadata

| L | Step | Class | Evidence |
|---:|---|---|---|
| 381 | Create a paired branch in `../plugins` | **Still to do** | No such branch exists on `lost-in-the/plugins` |
| 387 | Change the Woods floor from `>= 1.5.0` to `>= 2.0.0` | **Still to do** | Verified live 2026-09-03: `.claude-plugin/marketplace.json` still reads "Requires woods >= 1.5.0"; `README.md:11` still reads "woods **≥ 1.5.0**" |
| 391 | Validate marketplace JSON and links | **Still to do** | Blocked on the above; the grep for stale 1.5 text currently returns two hits |
| 400 | Commit the paired metadata change | **Stale** | The commit message and scope assume Task 8's two-file diff. That diff has grown: both files also name three skills where five now ship |

### Task 9: Documentation and package verification

| L | Step | Class | Evidence |
|---:|---|---|---|
| 418 | Review repository diffs before testing | Done | One-time gate on the PR #245 branch |
| 429 | Verify the generated public surface contract | Done | Now permanently enforced: `.github/workflows/ci.yml:203` runs `rake release_v2:verify_surface_inventory` |
| 437 | Run documentation and package specs | Done | Now permanently enforced: `.github/workflows/ci.yml:363` runs `spec/integration/packaged_gem_spec.rb`. `spec/release_v2/surface_inventory_spec.rb` exists |
| 445 | Check changed markdown links | Done | Re-verified 2026-09-03 across all 76 tracked markdown files: **zero broken relative links** |
| 451 | Run formatting and syntax checks | Done | Re-runnable gate; `plugin/.claude-plugin/plugin.json` parses |

### Task 10: Pull requests

| L | Step | Class | Evidence |
|---:|---|---|---|
| 472 | Commit Woods docs in reviewable units | Done | Five commits on `docs/v2-documentation-rewrite`, split public / contributor / plugin as specified |
| 482 | Push both branches | **Still to do (half)** | The Woods branch shipped. The `../plugins` branch does not exist. Folded into R1 below |
| 489 | Open the paired marketplace PR first | **Still to do** | Folded into R1 |
| 493 | Open the primary Woods PR | Done | PR #245, merged as `b21823d` on 2026-08-27 |
| 506 | Cross-link the marketplace PR | **Still to do** | Folded into R1 |

Task 10 steps 2, 3, and 5 restate Task 8. They add no work beyond R1.

### Final review checklist (9 items)

These are outcomes, not tasks. Judged against the current tree.

| L | Item | Class | Evidence |
|---:|---|---|---|
| 512 | Every user identifies their starting page in 30 seconds | Done | `docs/README.md:7` routing table, `README.md:126` "Choose your path" |
| 513 | First-run path works without embeddings or Console | Done | `docs/GETTING_STARTED.md:3` states the structural-only default explicitly |
| 514 | Live data and destructive actions have safety gates | Done | `docs/AGENT_SETUP.md:180` stop-and-ask list; `docs/UPGRADING_TO_2.md` purge-guard rows |
| 515 | No normal-user page advertises uncallable tools | Done | Re-verified by the Task 4 greps |
| 516 | Agent setup and agent MCP usage are separate | Done | `docs/AGENT_SETUP.md` and `docs/AGENT_GUIDE.md` are distinct files with distinct audiences |
| 517 | Contributor policy and agent instructions do not conflict | Done | Re-verified by the Task 6 command check |
| 518 | Plugin skills and marketplace compatibility match 2.0 | **Still to do** | Skills match; the marketplace does not. Same defect as Task 8 |
| 519 | Surface inventory, specs, validation, links, diffs pass | Done | Two are CI-enforced; the link check re-ran clean |
| 520 | Both PRs pushed, open, cross-linked, ready | **Still to do** | One of two. Same defect as Task 8 |

Checklist items 518 and 520 restate Task 8, so they add no new work.

## Remaining work

> **Status: executed 2026-09-03 on the release branch (PR #277).** Every box below is
> checked; deviations are noted inline. R1 was already delivered on the paired
> marketplace PR (lost-in-the/plugins#6, commits `94f8866`/`b3d39af`/`903998f`) before this
> plan landed — this plan's "verified missing" checked `plugins@main`, where #6 had not
> yet merged. Post-execution verification: zero broken local or cross-file anchors across
> all markdown; packaged-gem link check, surface inventory, and release specs green.

Ordered by what most improves a cold reader's first five minutes. R2 through R6 come from the accompanying review at `docs/self-analysis/v2-docs-review.md` and are not in the original plan; they are listed here because this is the plan an implementer would pick up.

### R1: Close the marketplace compatibility gap

The only surviving work from the original plan. Repository: `lost-in-the/plugins`.

- [x] Branch from current `main` in `lost-in-the/plugins`.
- [x] In `.claude-plugin/marketplace.json`, change the `woods-plugin` description from "Requires woods >= 1.5.0" to "Requires woods >= 2.0.0".
- [x] In the same description, replace the three-skill list with the five that ship: `woods-setup`, `woods-mcp-config`, `woods-diagnose`, `woods-investigate`, `woods-agent-enable`.
- [x] In `README.md:11`, change "woods **≥ 1.5.0**" to "woods **≥ 2.0.0**" and update "Three guide skills" to "Five guide skills".
- [x] Verify: `jq empty .claude-plugin/marketplace.json` passes and `grep -rn 'woods.*1\.5' .` returns nothing.
- [x] Open the PR and link it from a Woods issue. *(Delivered as lost-in-the/plugins#6, cross-linked from the woods #277 PR body rather than an issue.)*

### R2: Remove the duplicated generated files

Highest-value change in the repo. Deletes 13,493 lines.

- [x] `git rm docs/self-analysis/call-graph.md docs/self-analysis/dataflow.md docs/self-analysis/dependency-map.md`. Each is byte-identical to a section of `docs/self-analysis/architecture.md`.
- [x] Create `docs/self-analysis/README.md`: name the generator, state that the output is not for reading, and note that `woods.gemspec:45` already excludes it from the packaged gem.
- [x] Update the generator so it stops emitting the three duplicates.
- [x] Update `docs/self-analysis/v2-audit-2/07-suggested-fixes.md:78`, which names `docs/self-analysis` as a regeneration target.

### R3: Fix the CHANGELOG 2.0.0 section

- [x] Merge `CHANGELOG.md:1514` `### Added` into `CHANGELOG.md:146` `### Added`.
- [x] Merge `CHANGELOG.md:1597` `### Changed` into `CHANGELOG.md:174` `### Changed`.
- [x] Verify: `sed -n '10,1673p' CHANGELOG.md | grep -c '^### Added'` returns 1, same for `### Changed`.
- [x] Correct the "fold the changelog" row in `docs/README.md:77`, whose instruction ("under their existing headings") was not followed by `b8eecb4`. *(The row now lives in CONTRIBUTING.md after the R5 move; it requires each heading to appear exactly once in the released section.)*

### R4: Re-order the README for a first-time reader

- [x] Add a link to `docs/WHY_WOODS.md` above "Five-minute setup" at `README.md:72`. It currently has no inbound link from any user-facing page except one docs-index row.
- [x] Replace `README.md:140-165` ("What's new in 2.0" table plus "Upgrading from 1.x" list) with a two-line pointer to `docs/UPGRADING_TO_2.md`, which already holds both in full.
- [x] Move `README.md:45-71` ("Let an agent install it") below "Five-minute setup". *(Also folded the duplicate plugin-install commands out of "Optional Claude Code workflows".)*
- [x] Verify: README returns to the plan's original 180-260 line target and the pitch reaches the reader before any migration content.

### R5: Move maintainer material out of reader paths

- [x] Move `docs/README.md:64-93` (the release-cutting runbook) into `CONTRIBUTING.md`. `CONTRIBUTING.md:28` already links to it by anchor, so update that link.
- [x] Move `docs/superpowers/` out of the user documentation tree. `docs/design/plans/` matches existing repo precedent.
- [x] Retire `docs/superpowers/plans/2026-08-27-v2-documentation-rewrite.md` in favor of this file.

### R6: Even out the reference docs

Lowest priority. Cosmetic, but it is what makes the set read as one document.

- [x] Move `docs/TROUBLESHOOTING.md`'s existing "Quick Reference" table from line 744 to just under the intro. It is already written; it is 744 lines below where it is needed.
- [x] Add a question index to `docs/FAQ.md` (36 questions), a scenario index to `docs/MCP_TOOL_COOKBOOK.md` (33 scenarios), and an options index to `docs/CONFIGURATION_REFERENCE.md`.
- [x] Fix `docs/FAQ.md:266`: it says two embedding providers ship. `lib/woods/builder.rb:192-200` accepts `:openai`, `:ollama`, and `:fake`.
- [x] Fix `CLAUDE.md:326`: it lists eight `WHOLE_APP_EXTRACTORS`. `lib/woods/extractor.rb:298-322` has nine; `rails_source` is missing.
- [x] Convert Title Case headings to sentence case, worst first: `ARCHITECTURE.md` (21), `CONFIGURATION_REFERENCE.md` (17), `EXTRACTOR_REFERENCE.md` (13), `CONSOLE_MCP_SETUP.md` (13), `BACKEND_MATRIX.md` (11).
- [x] Rename `docs/ARCHITECTURE.md` to `docs/INTERNALS.md` to end the collision with `docs/self-analysis/architecture.md`. *(All inbound links updated; heading-case changes do not alter GitHub anchors, verified by a repo-wide anchor check.)*
- [x] Label `docs/MCP_WORKTREE_SETUP.md` as Claude Code specific, or move it under `plugin/`. It names `/mcp` and `~/.claude/plugins/` throughout.
- [x] Move `docs/WATCH_DAEMON.md` and `docs/INCREMENTAL_EXTRACTION.md` out of the docs index's "Index lifecycle" user route into a maintainer-reference group. Both are contract records; neither needs rewriting.
- [x] Fix `.claude/rules/docs.md`: drop "Avoid bullet-point-heavy sections", and scope the MySQL-and-PostgreSQL rule to `BACKEND_MATRIX.md` and `CONFIGURATION_REFERENCE.md`.
- [x] Change `docs/GETTING_STARTED.md:111` from "29 tools" to "29 schemas" so the schema/tool distinction holds everywhere.
