# Woods v2.0.0 documentation review

Reviewed 2026-09-03 against `claude/woods-gem-review-pfbbfk` at a clean working tree. Covers all 76 tracked markdown files.

## Headline verdict

**The prose is finished; the shelving is not.** The nine files rewritten for v2 are accurate, consistent, and well routed. The problems left are structural: 13,493 lines of duplicated generated output sit in the documentation directory, the CHANGELOG's 2.0.0 section has duplicate headings, and the README spends its middle third on a migration a new reader will never perform.

Six findings account for most of the remaining damage.

| # | Finding | Evidence | Cost to a cold reader |
|---|---|---|---|
| F1 | Three generated files are byte-identical copies of sections inside a fourth | `docs/self-analysis/` md5 comparison, below | High: `docs/` looks like 2 MB of unreadable graph |
| F2 | CHANGELOG's 2.0.0 section has two `### Added` and two `### Changed` blocks | `CHANGELOG.md:146,174,1514,1597` | High: the release notes cannot be scanned |
| F3 | 26 README lines (9%) serve 1.x upgraders, placed above the product explanation | `README.md:140-165` | Medium: the pitch stalls at line 140 |
| F4 | `docs/WHY_WOODS.md` is the pitch and has no inbound link from the README | `grep -rn WHY_WOODS` returns one user-facing hit | Medium: the "why" is unreachable from the front door |
| F5 | Three docs over 450 lines open with no way to find anything in them | measured below | Medium: the reader scrolls or gives up |
| F6 | Two contract/design records are routed to users as guides | `docs/README.md:43-44` | Medium: "keep the index current" lands in a spike write-up |

Two factual defects surfaced while reading, both outside the four above.

- **`CLAUDE.md:326` lists eight `WHOLE_APP_EXTRACTORS`; the code has nine.** `lib/woods/extractor.rb:298-322` includes `rails_source`. `docs/ARCHITECTURE.md:137` and `docs/INCREMENTAL_EXTRACTION.md:173` both get it right.
- **`docs/FAQ.md:266` says "Two embedding providers are supported"; there are three.** `lib/woods/builder.rb:192-200` accepts `:openai`, `:ollama`, and `:fake`, plus an injected provider object. `CONFIGURATION_REFERENCE.md:125` and `BACKEND_MATRIX.md:248` both document `:fake`.

### How deeply each file was read

Stated so the verdicts below can be weighted.

- **Read in full**: `README.md`, `AGENTS.md`, `docs/README.md`, and 12 of the `docs/` pages, including every page carrying a quality verdict stronger than "fine": `WATCH_DAEMON`, `INCREMENTAL_EXTRACTION`, `ARCHITECTURE`, `CONFIGURATION_REFERENCE`, `BACKEND_MATRIX`, `RETRIEVAL_GUIDE`, `CONSOLE_MCP_SETUP`, `GETTING_STARTED`, `AGENT_SETUP`, `MCP_SERVERS`, `AGENT_GUIDE`, `WHY_WOODS`, `MCP_WORKTREE_SETUP`, `TOKEN_BENCHMARK`, `design/README`.
- **Read substantially** (opening, structure, and multiple sampled sections): `TROUBLESHOOTING`, `EXTRACTOR_REFERENCE`, `MCP_TOOL_COOKBOOK`, `FAQ`, `DOCKER_SETUP`, `UPGRADING_TO_2`, `CHANGELOG`, `CONTRIBUTING`, `SECURITY`.
- **Read by structure and sample**: the three integration guides, `EMBEDDING_MODELS`, `MCP_HTTP_TRANSPORT`, `design/MCP_2026_STRATEGY`, and the four families below. Verdicts on these are about sectioning and placement, not prose quality.

## What is already right

Stating this first, because the fix list below is not a verdict on the whole set.

- **Zero broken relative links across all 76 files.** Verified by resolving every non-HTTP markdown target against the filesystem.
- **Every public count agrees everywhere.** 14 Index tools, 9/11 Console tools, 29 Index schemas, 31 Console schemas, 34 extractors, 38 unit types. Checked across `README.md`, `AGENTS.md`, `CLAUDE.md`, 9 docs files, and 3 plugin skills.
- **The docs index links all 25 sibling documents.** No orphan pages under `docs/`.
- **The canonical-owner table in `docs/README.md:94` has no equivalent in any of the four reference repos.** Keep it.
- **README length is not a problem.** 286 lines and 2,517 words sits between sidekiq (145 lines, ~950 words) and rubocop (~450 lines, ~2,200 words).

## Reference-repo comparison

Measured 2026-09-03 from the repos' own files and the GitHub contents API.

| Axis | pagy | sidekiq | rubocop | scientist | Woods |
|---|---|---|---|---|---|
| README lines | ~1,450 | 145 | ~450 | ~650 | 286 |
| README sections | 26 | 11 | 13 | 20 | 16 |
| Install in README | absent | 1 command | yes, section 1 | absent | yes, section 3 |
| Docs live | `docs/` site (8 guides) | GitHub wiki | `docs/` Antora site (28 pages) | one README | `docs/` (26 pages) |
| Root CHANGELOG | 1 line, a link | 2,521 lines / 226 releases | 5,177 lines | `doc/changelog.md` | 2,233 lines / 13 releases |
| Largest release entry | n/a | 108 lines (6.0.1) | 91 lines (1.88.0) | n/a | **1,664 lines (2.0.0)** |
| Upgrade guides | `guides/upgrade-guide.md` | 16 files in `docs/` | `v1_upgrade_notes.adoc`, last in nav | none | `UPGRADING_TO_2.md` + 26 README lines |
| Generated reference | published to site | n/a | 9 `cops_*.adoc`, published | n/a | **4 files, 26,004 lines, in repo** |

Seven observations from those repos, each tied to a Woods recommendation below.

- **sidekiq keeps 16 per-major upgrade guides in `docs/` and none in the README.** `docs/` holds `3.0-Upgrade.md` through `8.0-Upgrade.md` plus Pro and Ent variants. The README's "Want to Upgrade?" section is a pointer. Woods puts a 7-row × 4-column v1-to-v2 diff table at `README.md:140`.
- **sidekiq also ships `docs/menu.md`, a hand-written nav page for its public API.** rubocop ships `docs/modules/ROOT/nav.adoc`, 48 lines of ordered links. Both projects treat "how do I find the right page" as a file someone maintains. Woods has that at the directory level in `docs/README.md` and nothing at the page level, which is where F5 bites.
- **sidekiq averages 11 changelog lines per release across 226 releases; its worst is 108.** rubocop's worst is 91, and it moved 737 lines of v0 history out to `relnotes/CHANGELOG_v0.md` behind a single linked heading. Woods' 2.0.0 entry is 1,664 lines, 75% of the file.
- **rubocop accumulates unreleased changes as one file per change in `changelog/`.** Filenames encode type and timestamp, for example `fix_an_error_for_layout_else_alignment_when_rescue_else_is_in_a_class_body_20260901154507.md`. They are assembled at release. Woods folds by hand, and the last fold produced duplicate headings.
- **rubocop's repo contains no rendered cop documentation.** `docs/` holds `antora.yml`, one `nav.adoc`, and 28 source pages; the 9 `cops_*.adoc` files are generated and published to docs.rubocop.org. Woods commits 26,004 lines of rendered mermaid under `docs/self-analysis/`.
- **rubocop's `nav.adoc` is 48 lines of ordered links, two levels deep, and nothing else.** No release process, no maintainer instructions. Woods' `docs/README.md` carries a 30-line "At release: cutting the 2.0.0 tag" runbook at lines 64-93.
- **scientist opens with the pitch before anything else, and has no install section at all.** "Let's pretend you're changing the way you handle permissions" is the first content after the title. Woods' equivalent pitch, `docs/WHY_WOODS.md`, is listed under "Reference" in the docs index and linked from no user-facing page except that one row.

## Fix first

Ordered by what most improves a cold reader's first five minutes.

1. **Delete `call-graph.md`, `dataflow.md`, and `dependency-map.md`.** They are byte-identical to sections of `architecture.md`. Precedent: rubocop publishes generated reference rather than committing it.
2. **Merge the duplicate CHANGELOG headings.** One `### Added`, one `### Changed` per release section. Precedent: rubocop's per-change `changelog/` files make this mechanical.
3. **Cut the README's "What's new in 2.0" table and "Upgrading from 1.x" list to a two-line pointer.** Both already exist in full at `docs/UPGRADING_TO_2.md`. Precedent: sidekiq's README upgrade section.
4. **Link `docs/WHY_WOODS.md` from the README, above "Five-minute setup".** Precedent: scientist leads with the pitch.
5. **Give the four longest docs a top-of-page index.** Measured in the next section. Precedent: sidekiq's `docs/menu.md` and rubocop's `nav.adoc`.
6. **Move the release runbook out of `docs/README.md` into `CONTRIBUTING.md`.** Precedent: rubocop's `nav.adoc` is nav only.
7. **Split the maintainer-reference tier out of the user routes.** Precedent: rubocop's nav puts `development.adoc` and `contributing.adoc` after every user page.
8. **Normalize heading case in the nine reference docs.** Measured below.
9. **Update the marketplace's `woods >= 1.5.0` floor.** Two files in `lost-in-the/plugins` still claim it, and both describe three plugin skills where five now ship.

## F5: the long docs have no way in

Measured by looking for an orienting table, list, or "at a glance" section in the first 40 lines.

| File | Lines | Opens with | Verdict |
|---|---:|---|---|
| `MCP_TOOL_COOKBOOK.md` | 884 | A tool-wiring caveat table | Its 33 scenarios are unlisted |
| `CONSOLE_MCP_SETUP.md` | 816 | "Transport Options at a Glance" | Fine. This is the model to copy |
| `TROUBLESHOOTING.md` | 783 | The first symptom, immediately | **Its symptom index is at line 744 of 783** |
| `EXTRACTOR_REFERENCE.md` | 683 | A counts note | Acceptable; the doc is browsed by extractor name |
| `WATCH_DAEMON.md` | 577 | An env-var table | Acceptable |
| `CONFIGURATION_REFERENCE.md` | 523 | A three-line code sample | Nothing orienting |
| `FAQ.md` | 492 | The first question | Nothing orienting, and 36 questions follow |
| `BACKEND_MATRIX.md` | 470 | The Persistence Story table | Fine |

**The cheapest fix is moving `TROUBLESHOOTING.md`'s existing "Quick Reference" table to the top.** It is already written and already good; it is just 744 lines below where a reader needs it.

## F6: two contract records are routed to users as guides

`docs/README.md:43-44` files these under "Index lifecycle", beside `RETRIEVAL_GUIDE.md` at line 45, which really is a user guide.

- **`INCREMENTAL_EXTRACTION.md` says what it is in its own first paragraph**: "This page states the correctness contract it is held to". It then covers a seven-step ordering argument, a Zeitwerk constant-identity rule, and how to run the differential harness.
- **`WATCH_DAEMON.md` is the best-written file in the repo and is a spike write-up.** It contains a three-option placement comparison with a chosen verdict, benchmark tables separating fixture-app from 1,940-unit numbers, an explicit "Still not measured" gap, and a section titled "MCP `resources/updated`: evaluated, not implemented".

Neither should be rewritten. Both should be labeled and moved below the user guides, the way rubocop's nav puts `development.adoc` last. A user who clicks "Keep the index current automatically" wants the Procfile line, which is at `WATCH_DAEMON.md:39`, not the 462-line freshness contract that follows it.

## Navigation problems a cold reader hits

Walking the path a prospective user actually takes.

- **The README's first content is a version banner and a branch-model notice, not the pitch.** Lines 13-15 explain that `main` runs ahead of the published gem. That is maintainer context above the product.
- **The agent install section precedes the human one.** `README.md:45` offers a 25-line copyable prompt; `README.md:72` offers the commands. A reader installing by hand scrolls past the prompt to reach them.
- **The reader hits the v1-to-v2 diff table at line 140, before learning what the two servers are.** "Two servers, two trust boundaries" is at line 180, after 26 lines of migration content.
- **Browsing `docs/` on GitHub shows 26 files and 3 directories with no ordering signal.** `self-analysis/` is 2 MB of generated graph; `superpowers/` is implementation plans; neither is linked from the docs index as a reading path.
- **`docs/ARCHITECTURE.md` and `docs/self-analysis/architecture.md` share a name and do not share a purpose.** One is a 388-line human explanation; the other is a 13,511-line mermaid block.
- **`docs/MCP_WORKTREE_SETUP.md` is Claude Code specific inside a client-neutral set.** It names `/mcp`, `~/.claude/plugins/`, and subagents, while `docs/MCP_SERVERS.md:60` insists Woods is client-independent.

### Assumptions recorded

- I treated a "cold reader" as someone who has never run Woods 1.x. That drives the F3 ranking; a reader who has run 1.x wants that table where it is.
- I judged `docs/self-analysis/v2-audit-2/` as correctly placed even though it is unlinked, because it is dated audit evidence rather than a guide.
- I did not run `bundle exec` commands. Rake task existence was checked against `lib/tasks/woods.rake` directly.
- A better framing exists and I did not pursue it: the real unit of work here is a docs site, not a docs directory. Three of the four reference repos publish one. That is a larger decision than this review's scope, so it is noted and left.

## Per-file verdicts: root

| File | Lines | Verdict | Action |
|---|---:|---|---|
| `README.md` | 286 | Accurate, mis-ordered | Fix 3, Fix 4 |
| `CHANGELOG.md` | 2,233 | Structurally broken | Fix 2 |
| `AGENTS.md` | 143 | Good. Repository map, invariants, and completion checklist are all present | None |
| `CLAUDE.md` | 375 | Good, and dense by design. Gotchas are grouped by layer with one claim per bullet | None |
| `CONTRIBUTING.md` | 168 | Good. Cleanly separated from `AGENTS.md`; commands agree across both plus `CLAUDE.md` | Receive the release runbook from Fix 6 |
| `SECURITY.md` | 92 | Good. Supported-version table carries an end date for 1.6.x | None |
| `CODE_OF_CONDUCT.md` | 83 | Standard Contributor Covenant | None |

## Per-file verdicts: `docs/` top level

Rewritten for v2 in `426dc25` and `8c6d30a`. These share one voice and one heading style.

| File | Lines | Verdict |
|---|---:|---|
| `README.md` | 111 | Strong router, wrong contents at lines 64-93. Fix 6 |
| `GETTING_STARTED.md` | 181 | Good. Numbered path, first-run failure table at line 163, explicit next steps. One term slip: line 111 calls schemas "tools" |
| `AGENT_SETUP.md` | 205 | Good. Default-decision table, stop-and-ask list at line 151, handoff template, copyable prompt at line 198 |
| `AGENT_GUIDE.md` | 196 | Good. Opens with the query loop, closes with a mistakes table |
| `MCP_SERVERS.md` | 231 | Good. The chooser table is the best single artifact in the set |
| `UPGRADING_TO_2.md` | 285 | Good. The "What changes" table is the canonical version of the README's duplicate |
| `FAQ.md` | 492 | Trimmed, not rewritten. 36 questions, no index. Says two embedding providers ship; three do. Fix 5 |

Not touched by the v2 rewrite. All are accurate; all carry the older voice.

| File | Lines | Verdict |
|---|---:|---|
| `MCP_TOOL_COOKBOOK.md` | 884 | Largest human doc. 33 scenarios, each a question then tool, params, and expected output. The pattern is applied consistently. Unlisted at the top. Fix 5 |
| `CONSOLE_MCP_SETUP.md` | 816 | Thorough and correctly scary. Names what `SafeContext` does **not** cover (jobs, mail, HTTP, threads, other shards). Best long-doc opening in the set |
| `TROUBLESHOOTING.md` | 783 | Good symptom-cause-fix shape, consistently applied. Has a symptom index, at line 744. Fix 5 |
| `EXTRACTOR_REFERENCE.md` | 683 | Reference-grade. The counts note at line 5 and the "How Do I Enable or Disable Extractors? You can't, today" section are both exemplary |
| `WATCH_DAEMON.md` | 577 | Best-written doc in the repo, and a design record. Measured numbers with methodology and stated gaps. Fix 7 |
| `CONFIGURATION_REFERENCE.md` | 523 | Complete and accurate. The user-settable / preset-derived / computed column is a good idea. 17 Title Case headings, heaviest offender for Fix 8 |
| `BACKEND_MATRIX.md` | 470 | Good. Its three "Not implemented" sections name the exact `ArgumentError` an aspirational config raises. Rare and worth keeping |
| `DOCKER_SETUP.md` | 454 | Good. Path translation is the hard part and it is handled well |
| `INCREMENTAL_EXTRACTION.md` | 408 | Excellent, and a contract record, not a guide. Fix 7 |
| `ARCHITECTURE.md` | 388 | Good, and correct where `CLAUDE.md` is not (nine wholesale extractors, line 137). Name collides with the generated file |
| `NOTION_INTEGRATION.md` | 283 | Fine. Numbered setup, CI examples |
| `UNBLOCKED_INTEGRATION.md` | 279 | Fine. Same shape as Notion; good consistency between the two |
| `RETRIEVAL_GUIDE.md` | 267 | Good. Pipeline diagram first, tuning last |
| `WHY_WOODS.md` | 202 | Content is the strongest pitch in the repo. Placement is the problem. Fix 4 |
| `OBSIDIAN_INTEGRATION.md` | 170 | Fine. Shorter than its two siblings and no worse for it |
| `MCP_HTTP_TRANSPORT.md` | 144 | Good. Opens with "What's shipped", which sets scope immediately |
| `EMBEDDING_MODELS.md` | 136 | Good. TL;DR section first |
| `MCP_WORKTREE_SETUP.md` | 125 | Accurate, and Claude Code specific throughout: `/mcp`, `~/.claude/plugins/`, subagents. Label it or move it to `plugin/` |
| `TOKEN_BENCHMARK.md` | 68 | Good. Names its single source of truth in the first block |

### Heading-case measurement

Title Case headings per file, counting level-2 and level-3 headings of two or more capitalized words.

| File | Headings | Title Case |
|---|---:|---:|
| `ARCHITECTURE.md` | 45 | 21 |
| `CONFIGURATION_REFERENCE.md` | 48 | 17 |
| `EXTRACTOR_REFERENCE.md` | 52 | 13 |
| `CONSOLE_MCP_SETUP.md` | 61 | 13 |
| `BACKEND_MATRIX.md` | 65 | 11 |
| Every v2-rewritten file | 11 to 21 | 0 |

## Per-family verdicts

Four families are judged as groups. Each is stated explicitly with its rationale.

### `docs/self-analysis/*.md` (4 files, 26,004 lines)

**Generated mermaid output, and 52% of it is duplicated.** Judged as a family because no per-file reading is possible or useful: each file is one mermaid block.

- `architecture.md` (13,511 lines) contains four sections: Call Graph, Dependency Map, Data Flow, Analysis Summary.
- `call-graph.md` lines 3-6071 are md5-identical to `architecture.md` lines 5-6073.
- `dependency-map.md` lines 3-3356 are md5-identical to `architecture.md` lines 6077-9430.
- `dataflow.md` lines 3-4066 are md5-identical to `architecture.md` lines 9434-13497.
- `dependency-map.md` also renders 123 edges across roughly 2,400 nodes, so the map is nearly edgeless. `docs/self-analysis/v2-audit-2/04-medium.md:113` logged this and it is only partly fixed.

**Verdict: delete the three duplicates, keep `architecture.md`, and add a `docs/self-analysis/README.md` saying what generates it and that it is not for reading.** These files are excluded from the gem, since `woods.gemspec:45` packages `docs/*.md` non-recursively. That is correct and worth keeping.

### `docs/self-analysis/v2-audit-2/*.md` (9 files, 1,152 lines)

**Dated audit evidence, correctly structured, correctly unlinked.** Judged as a family because its own `README.md` already routes the other eight files with a purpose column, a severity table, and an evidence legend. That README is a better index than most of `docs/`.

**Verdict: leave it. No action.**

### `.claude/` (12 files, 668 lines) and `plugin/skills/` (5 files, 361 lines)

**Agent-facing instruction files, not reader documentation.** Judged as families because each file is a skill, agent, or rule definition with frontmatter, evaluated on trigger quality rather than prose.

- The five plugin skills have specific, trigger-rich descriptions after `bc7565d` and `fd70d49`. `woods-investigate` and `woods-agent-enable` post-date the v2 plan.
- `.claude/rules/docs.md:15` says "Avoid bullet-point-heavy sections" and applies to `docs/**/*.md`. The nine v2-rewritten docs are bullet-heavy and better for it. **The rule now contradicts the house style it governs; update or drop it.**
- `.claude/rules/docs.md:10` requires every configuration example to show both MySQL and PostgreSQL. `docs/GETTING_STARTED.md` and `docs/AGENT_SETUP.md` show neither, correctly, because structural extraction is adapter-independent. Scope the rule to `BACKEND_MATRIX.md` and `CONFIGURATION_REFERENCE.md`.

**Verdict: fix the two `.claude/rules/docs.md` clauses. No other action.**

### `.github/` (3 files), `spec/fixtures/**` (5 files), `.Codex/release-v2/verification.md`, `docs/design/` (2 files), `docs/superpowers/` (2 files)

Judged as a family of non-guide material.

- `.github/` templates are conventional and adequate.
- `spec/fixtures/**/*.md` are golden test outputs. They are markdown by accident of format.
- `.Codex/release-v2/verification.md` is a dated release record with reproducible commands. Correct as-is.
- `docs/design/README.md` explicitly labels its contents as ADRs and points elsewhere for user guides. Exemplary.
- `docs/superpowers/plans/` and `docs/superpowers/specs/` hold implementation plans inside the user documentation tree. **They are unlinked from every index, which is right, but the path is wrong; `.superpowers/` or `docs/design/plans/` would signal it.**

**Verdict: move `docs/superpowers/` out of `docs/`. No other action.**
