# Woods 2.0 Documentation Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Woods' duplicated, inventory-first usage documentation with a verified, audience-first v2 documentation path for users, contributors, installers, MCP configurators, and MCP-using agents.

**Architecture:** Keep the root README as the concise entry point, route readers by task from `docs/README.md`, and assign one canonical owner to setup, MCP configuration, MCP usage, migration, contribution, and agent-maintainer facts. Mirror the canonical setup/configuration commands into the distributed plugin skills, then update the paired marketplace's compatibility floor.

**Tech Stack:** GitHub-flavored Markdown, Ruby/Rails commands, MCP JSON configuration, Claude Code plugin skills, generated v2 public-surface inventory.

**Spec:** `docs/superpowers/specs/2026-08-27-v2-documentation-design.md`

## Global Constraints

- Target Woods 2.0.0, Ruby >= 3.0, Rails >= 6.0 and < 9, and `mcp >= 1.2, < 2.0`.
- Lead with the structural Index Server: 14 always-on tools; embeddings are optional; Console MCP is optional.
- Present Console MCP as 9 default or 11 with `console_embedded_read_tools`; never present Tier 2, Tier 3, or `console_eval` as executable.
- Present the other 15 Index tools as Ruby embedding/wiring capabilities, not settings normal packaged launchers expose.
- Do not modify production Ruby code, tests, generated surface inventory, or `woods-testbed` application code.
- Preserve the user's untracked `.hermes/` directory.
- Use `apply_patch` for every edit.
- Keep all relative README links valid inside the packaged gem.
- Do not publish unverified timing, scale, safety, or compatibility claims.
- Do not add AI attribution or signoffs to commits or pull requests.

---

### Task 1: Commit the evidence-backed documentation design and plan

**Files:**

- Create: `docs/superpowers/specs/2026-08-27-v2-documentation-design.md`
- Create: `docs/superpowers/plans/2026-08-27-v2-documentation-rewrite.md`

**Interfaces:**

- Consumes: `.Codex/release-v2/surface-inventory.json`, v1.6.1 tag, v2 source/docs, maintained gem repository research.
- Produces: the approved ownership map, constraints, file scope, and acceptance criteria for every later task.

- [ ] **Step 1: Check the design for incomplete markers and unsupported claims**

Run:

```bash
rg -n '[T]BD|[T]ODO|[F]IXME|we should probably' \
  docs/superpowers/specs/2026-08-27-v2-documentation-design.md \
  docs/superpowers/plans/2026-08-27-v2-documentation-rewrite.md
```

Expected: no output.

- [ ] **Step 2: Confirm every planned Woods file exists or is explicitly new**

Run:

```bash
for file in README.md CONTRIBUTING.md AGENTS.md docs/README.md \
  docs/GETTING_STARTED.md docs/MCP_SERVERS.md docs/AGENT_GUIDE.md \
  docs/UPGRADING_TO_2.md plugin/skills/woods-setup/SKILL.md \
  plugin/skills/woods-mcp-config/SKILL.md plugin/skills/woods-diagnose/SKILL.md; do
  test -f "$file" || exit 1
done
test ! -e docs/AGENT_SETUP.md
```

Expected: exit 0.

- [ ] **Step 3: Commit the planning checkpoint**

```bash
git add docs/superpowers/specs/2026-08-27-v2-documentation-design.md \
  docs/superpowers/plans/2026-08-27-v2-documentation-rewrite.md
git commit -m "docs: plan the v2 documentation rewrite"
```

### Task 2: Replace the public entry points

**Files:**

- Modify: `README.md`
- Modify: `docs/README.md`

**Interfaces:**

- Consumes: the canonical destinations defined in the design.
- Produces: a short product entry and an audience/task router used by every other guide.

- [ ] **Step 1: Rewrite `README.md` from scratch**

Keep these sections, in this order:

1. Product name, one-line outcome, status badges/wordmark if still accurate.
2. “What Woods knows that source-only tools miss” with one compact example.
3. “Five-minute setup” covering `bundle add`, generator, migration, extraction, validation, and Index MCP config.
4. “Choose your path” for Docker, semantic search, Console MCP, team/shared setup, and v1 upgrade.
5. “What gets exposed” with the 14-tool Index default and the 9/11 live Console boundary.
6. Compatibility and security boundary.
7. Documentation, contributing, license.

Remove long JSON examples, full task inventories, storage matrices, architecture diagrams, and advanced feature catalogs. Link their canonical references.

- [ ] **Step 2: Rewrite `docs/README.md` as a task router**

Start with “What are you trying to do?” and provide separate rows for:

- install Woods yourself;
- ask an agent to install Woods;
- configure an MCP client;
- use Woods tools as an agent;
- upgrade v1 to v2;
- troubleshoot;
- contribute to Woods;
- read implementation references.

Include a canonical-owner table so future contributors know where setup, config, MCP, security, migration, and contributor facts belong.

- [ ] **Step 3: Verify entry-point structure and size**

Run:

```bash
wc -l README.md docs/README.md
rg -n '^## ' README.md docs/README.md
rg -n 'AGENT_SETUP|GETTING_STARTED|MCP_SERVERS|AGENT_GUIDE|UPGRADING_TO_2|CONTRIBUTING' \
  README.md docs/README.md
```

Expected: README 180-260 lines; docs index 80-130 lines; all six routes present.

### Task 3: Create the human and agent installation paths

**Files:**

- Modify: `docs/GETTING_STARTED.md`
- Create: `docs/AGENT_SETUP.md`
- Modify: `docs/FAQ.md` only where a duplicated first-run answer conflicts with the new canonical guide.

**Interfaces:**

- Consumes: generator behavior, Rails task definitions, default configuration, Docker split-process constraints.
- Produces: a human walkthrough and a safe agent handoff using the same commands.

- [ ] **Step 1: Rewrite `docs/GETTING_STARTED.md`**

Cover:

1. Prerequisites and what the first run changes.
2. Install/generate/migrate with expected created files.
3. Default structural extraction without embeddings.
4. Extract, validate, and inspect via Woods commands rather than direct root `manifest.json` assumptions.
5. Connect the 14-tool Index Server.
6. Ask three first questions using `woods_status`, `search`/`lookup`, and `dependents`.
7. Optional branches: Docker, semantic search, Console MCP, watch/CI.
8. First-run failure table and next links.

- [ ] **Step 2: Write `docs/AGENT_SETUP.md`**

Use a deterministic runbook:

1. Preflight: repository status, Rails boot, installed Woods version, Docker layout, database adapter.
2. Decide structural-only vs semantic retrieval; default to structural-only.
3. Install on a branch; inspect generated initializer and migration.
4. Run migration only after checking for table/name conflicts.
5. Extract and validate.
6. Add Index MCP configuration using the host-visible path.
7. Ask before enabling Console MCP, HTTP exposure, secrets, or purge overrides.
8. Return a concise handoff report with files changed, commands run, and capabilities available.

Include a copyable prompt a user can give to an agent.

- [ ] **Step 3: Remove conflicting FAQ setup duplication**

Keep FAQ answers short and link to the canonical setup guide. Do not maintain full client configuration blocks in both files.

- [ ] **Step 4: Verify setup commands against source**

Run:

```bash
rg -n 'woods:(extract|validate|stats|watch)|woods:install|rails db:migrate|woods-mcp-start' \
  docs/GETTING_STARTED.md docs/AGENT_SETUP.md
bundle exec rake -T | rg 'woods:(extract|validate|stats|watch)'
```

Expected: every documented task appears in `rake -T`; both guides reach Index MCP success.

### Task 4: Rewrite MCP setup and MCP agent usage around callable tools

**Files:**

- Modify: `docs/MCP_SERVERS.md`
- Modify: `docs/AGENT_GUIDE.md`
- Modify: `docs/MCP_TOOL_COOKBOOK.md` only for links or examples that contradict the rewritten capability boundary.

**Interfaces:**

- Consumes: `.Codex/release-v2/surface-inventory.json` tool names and registration conditions.
- Produces: one server-administration guide and one agent-operating guide.

- [ ] **Step 1: Rewrite `docs/MCP_SERVERS.md`**

Order content as:

1. Choose Index vs Console.
2. Explain the extraction/host/live-Rails process boundary.
3. Configure Index stdio for Claude Code, Cursor, and Windsurf.
4. Configure Console stdio/Docker; link HTTP security to `CONSOLE_MCP_SETUP.md`.
5. Verify connection with client-native inspection and `woods_status`.
6. List the 14 core Index tools by workflow.
7. List 9/11 supported Console tools.
8. Label 15 Index conditional tools as embedding-API wiring.
9. Label remaining Console schemas as source inventory only.
10. Link protocol/tasks/HTTP reference.

Delete chooser rows for tools unavailable in normal configurations.

- [ ] **Step 2: Rewrite `docs/AGENT_GUIDE.md`**

Start with the operating loop:

```text
woods_status -> search -> lookup -> traverse/trace -> verify with live Console only when authorized
```

Then cover exact workflows for understanding a unit, tracing a feature, blast radius, navigation, framework behavior, semantic retrieval, and live-data validation. Include structured-error handling and token/call-efficiency guidance. Link tool schemas/cookbook instead of repeating the complete catalog.

- [ ] **Step 3: Compare every named tool with the generated inventory**

Run a Ruby or shell check that extracts backticked MCP-style names from the two changed guides and compares candidate names with:

```bash
jq -r '.index_mcp.tools[].name, .console_mcp.schemas[].name' \
  .Codex/release-v2/surface-inventory.json | sort -u
```

Expected: no misspelled or removed tool names; inventory-only tools appear only in explicitly negative context.

- [ ] **Step 4: Verify forbidden recommendations are gone**

Run:

```bash
rg -n 'I want to.*(diagnose|job queue)|pipeline_health|all 29|all 31' \
  docs/MCP_SERVERS.md docs/AGENT_GUIDE.md
```

Expected: no output claiming those capabilities are normally callable.

### Task 5: Rewrite the v1-to-v2 upgrade guide as a safe runbook

**Files:**

- Modify: `docs/UPGRADING_TO_2.md`

**Interfaces:**

- Consumes: `v1.6.1`, `CHANGELOG.md` v2 section, v2 generation/purge/config/MCP code.
- Produces: a complete upgrade, verification, rollback, and agent handoff path.

- [ ] **Step 1: Build a required-action summary**

Open with:

- who must read the guide;
- the last v1 and target v2 versions;
- one table separating required actions, conditional actions, and optional new features;
- the default safe path.

- [ ] **Step 2: Rewrite the migration sequence**

Sequence:

1. Record current version/config/index/export integrations.
2. Back up durable vector/export state.
3. Update bundle and review dependency constraints.
4. Remove reliance on `config.extractors`, `config.add_gem`, or a forced MCP protocol version.
5. Clean extract.
6. Re-embed with explicit handling for dimension and 30% purge guards.
7. Re-export if applicable.
8. Update direct artifact readers for `generation.json` payloads.
9. Restart/reconnect MCP clients.
10. Verify identifiers, status, retrieval, and Console surface.

- [ ] **Step 3: Add rollback and agent handoff**

The rollback must state that downgrade requires a v1 re-index and durable-store restoration. The agent prompt must forbid purge overrides and production Console changes without explicit approval.

- [ ] **Step 4: Verify every environment variable and configuration key**

Run:

```bash
rg -o 'WOODS_[A-Z0-9_]+' docs/UPGRADING_TO_2.md | sort -u
rg -n 'WOODS_ALLOW_PURGE|WOODS_PAYLOAD_RETENTION|MCP_PROTOCOL_VERSION' lib exe docs/UPGRADING_TO_2.md
```

Expected: each documented variable has a source definition or verified consumer.

### Task 6: Separate contributor policy from coding-agent instructions

**Files:**

- Modify: `CONTRIBUTING.md`
- Modify: `AGENTS.md`

**Interfaces:**

- Consumes: `CLAUDE.md`, CI workflow, testbed README, current contribution gates.
- Produces: shared contribution policy plus concise, tool-neutral agent execution instructions.

- [ ] **Step 1: Rewrite `CONTRIBUTING.md`**

Include issue/security routing, contribution types, setup, smallest relevant validation command, Rails matrix/live-backend guidance, docs/plugin synchronization, changelog expectations, and PR evidence. Keep low-level architecture out.

- [ ] **Step 2: Rewrite `AGENTS.md`**

Include project summary, repository map, read-before-edit pointers, exact commands, public-surface inventory contract, extraction/MCP/Console invariants, documentation ownership, plugin pairing, and completion checklist. Link `CONTRIBUTING.md` for shared policy instead of duplicating it.

- [ ] **Step 3: Check command consistency**

Run:

```bash
rg -n 'bin/(rake|rspec|rubocop)|BUNDLE_GEMFILE|WOODS_RUN_' CONTRIBUTING.md AGENTS.md CLAUDE.md
```

Expected: commands agree; any deliberate audience-specific difference is explained locally.

### Task 7: Align the distributed Woods plugin skills

**Files:**

- Modify: `plugin/skills/woods-setup/SKILL.md`
- Modify: `plugin/skills/woods-mcp-config/SKILL.md`
- Modify: `plugin/skills/woods-diagnose/SKILL.md`
- Modify: `plugin/.claude-plugin/plugin.json`

**Interfaces:**

- Consumes: `docs/AGENT_SETUP.md`, `docs/MCP_SERVERS.md`, `docs/TROUBLESHOOTING.md`.
- Produces: cached Claude Code workflows consistent with Woods 2.0 docs.

- [ ] **Step 1: Rewrite `woods-setup` as the agent runbook adapter**

Keep version preflight, environment discovery, branch/status safety, install/generate/migrate, structural-first extraction, verification, and handoff. Remove the unverified extraction time and “no external services” wording for Ollama.

- [ ] **Step 2: Rewrite `woods-mcp-config` around three supported shapes**

Support Index-only, Index + Console stdio/Docker, and authenticated Console HTTP. State exact 14 and 9/11 tool surfaces. Require approval before live-data access.

- [ ] **Step 3: Tighten `woods-diagnose`**

Use `woods_status`, Rails boot/eager load, generation-aware validation, path checks, embeddings, and Console security/config in that order. Remove initialize-less JSON-RPC smoke-test guarantees.

- [ ] **Step 4: Bump plugin version**

Change `plugin/.claude-plugin/plugin.json` from `2.0.0` to `2.0.1` because installed users cache skill content by plugin version.

- [ ] **Step 5: Validate the plugin**

Run:

```bash
claude plugin validate "$PWD/plugin"
```

Expected: validation succeeds.

### Task 8: Update the paired marketplace compatibility metadata

**Files (repository `../plugins`):**

- Modify: `README.md`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**

- Consumes: Woods plugin target/version from Task 7.
- Produces: marketplace metadata that no longer claims Woods 1.5 compatibility.

- [ ] **Step 1: Create a paired branch from updated `main`**

```bash
git -C ../plugins switch -c docs/woods-v2-plugin-compatibility
```

- [ ] **Step 2: Update the compatibility floor**

Change every Woods minimum from `>= 1.5.0` to `>= 2.0.0`. Keep the source on Woods `main`; no `ref`/`sha` pin is required.

- [ ] **Step 3: Validate marketplace JSON and links**

```bash
jq empty ../plugins/.claude-plugin/marketplace.json
rg -n 'woods.*1\.5|1\.5.*woods' ../plugins
```

Expected: valid JSON; no stale Woods 1.5 compatibility text.

- [ ] **Step 4: Commit the paired metadata change**

```bash
git -C ../plugins add README.md .claude-plugin/marketplace.json
git -C ../plugins commit -m "docs: require Woods 2.0 for the plugin"
```

### Task 9: Run documentation and package verification

**Files:**

- Modify: any changed documentation file only to fix failures found here.

**Interfaces:**

- Consumes: all documentation and plugin changes.
- Produces: evidence that claims, links, package contents, and plugin metadata are internally consistent.

- [ ] **Step 1: Review repository diffs before testing**

```bash
git status --short
git diff --check
git diff --stat main...HEAD
git diff main...HEAD -- README.md CONTRIBUTING.md AGENTS.md docs plugin
```

Expected: only planned files changed; `.hermes/` remains untracked and untouched.

- [ ] **Step 2: Verify the generated public surface contract**

```bash
bundle exec rake release_v2:verify_surface_inventory
```

Expected: pass with no drift.

- [ ] **Step 3: Run documentation/package integration specs**

```bash
bin/rspec spec/integration/packaged_gem_spec.rb spec/release_v2/surface_inventory_spec.rb
```

Expected: 0 failures.

- [ ] **Step 4: Check changed Markdown links**

Run a read-only Ruby script that extracts relative Markdown targets from every changed `.md`/`SKILL.md`, strips anchors, resolves paths relative to each source, and fails when a target does not exist. Ignore `http:`, `https:`, `mailto:`, and pure anchors.

Expected: no missing local targets.

- [ ] **Step 5: Run formatting/syntax checks**

```bash
git diff --check
jq empty plugin/.claude-plugin/plugin.json
claude plugin validate "$PWD/plugin"
```

Expected: all pass.

### Task 10: Commit, push, and open cross-linked pull requests

**Files:**

- No new files; GitHub PR metadata only.

**Interfaces:**

- Consumes: verified Woods and marketplace branches.
- Produces: one primary Woods documentation PR and one paired marketplace compatibility PR.

- [ ] **Step 1: Commit Woods documentation in reviewable units**

Use atomic commits for:

1. public/user documentation;
2. contributor/agent-maintainer docs;
3. plugin skill alignment.

Review `git diff --cached` before every commit.

- [ ] **Step 2: Push both branches**

```bash
git push -u origin docs/v2-documentation-rewrite
git -C ../plugins push -u origin docs/woods-v2-plugin-compatibility
```

- [ ] **Step 3: Open the paired marketplace PR first**

Create a PR against `lost-in-the/plugins:main` that explains the compatibility-floor correction and links the forthcoming Woods branch URL.

- [ ] **Step 4: Open the primary Woods PR**

The PR body must include:

- the audience and information-architecture decision;
- benchmark repositories and the lessons adopted;
- the actual 14 and 9/11 MCP surface correction;
- v1-to-v2 migration coverage;
- files/sections rewritten;
- verification commands/results;
- the paired marketplace PR link;
- a note that no production Ruby behavior changed.

- [ ] **Step 5: Cross-link the marketplace PR to the Woods PR**

Edit the paired PR body or add a concise comment with the final Woods PR URL. Do not add AI attribution.

## Final Review Checklist

- [ ] Every user can identify their starting page in 30 seconds.
- [ ] The first-run path works without embeddings or Console MCP.
- [ ] Live data and destructive upgrade actions have explicit safety gates.
- [ ] No normal-user page advertises uncallable MCP tools.
- [ ] Agent setup and agent MCP usage are separate.
- [ ] Contributor policy and agent instructions do not conflict.
- [ ] Plugin skills and marketplace compatibility match Woods 2.0.
- [ ] Surface inventory, package specs, plugin validation, link checks, and diff checks pass.
- [ ] Both PRs are pushed, open, cross-linked, and ready for review.
