# Woods 2.0 Documentation Architecture

Woods 2.0 will use a layered, repository-native documentation set: a concise product README, a task-oriented documentation index, separate human and agent setup paths, an executable-surface-first MCP guide, a workflow-focused MCP agent guide, a major-version upgrade runbook, and focused contributor/agent-maintainer instructions. This replaces the current README monolith and removes setup facts duplicated across five or more documents. The primary risk is publishing commands or MCP capabilities that do not match the packaged gem, so every public claim will be checked against the generated v2 surface inventory and packaged-gem verification suite.

---

## Decision

Use the documentation structure common to mature gems that have outgrown a single README:

1. Keep the root README focused on value, compatibility, a minimal working path, and navigation.
2. Put task-oriented usage guides in `docs/` and make `docs/README.md` the router.
3. Keep upgrade instructions in a dedicated major-version guide.
4. Keep contributor policy in `CONTRIBUTING.md`.
5. Keep repository-working instructions for coding agents in `AGENTS.md`.
6. Keep install/configure/diagnose automation in the distributed Woods plugin skills, sourced from the same verified commands as the human guides.
7. Describe MCP capabilities from the user's executable surface first. Put theoretical or embedding-only wiring in a clearly labeled advanced section.

The public launch path becomes:

```text
README quick start
  -> docs/GETTING_STARTED.md (human setup)
  -> docs/AGENT_SETUP.md (agent-operated setup)
  -> docs/MCP_SERVERS.md (server configuration and security)
  -> docs/AGENT_GUIDE.md (using the MCP tools effectively)
  -> docs/UPGRADING_TO_2.md (existing installations)
```

## Research Findings

### Maintained gem repository patterns

The comparison sampled framework, testing, linting, background-job, authentication, and HTTP-client gems. Line counts were measured from each repository's default branch on 2026-08-27.

| Repository | README shape | Supporting documentation | Strategy Woods should adopt |
|---|---|---|---|
| [Rails](https://github.com/rails/rails) | 102 lines: purpose, framework map, getting started, contribution links | Published Guides, component READMEs, release notes, 201-line `AGENTS.md` | Keep the root entry concise; separate human onboarding from agent codebase instructions. |
| [RSpec](https://github.com/rspec/rspec) | 159 lines: install, first example, command, contribution links | Component READMEs and focused contribution guide | Give users one successful first workflow before reference detail. |
| [RuboCop](https://github.com/rubocop/rubocop) | 255 lines, but delegates real usage after installation/quickstart | Navigated docs for installation, usage, configuration, MCP, versioning, and v1 upgrade; separate `AGENTS.md` | Use an explicit docs navigation layer and separate MCP/setup/versioning pages. |
| [Sidekiq](https://github.com/sidekiq/sidekiq) | 126 lines and a product-doc link | Wiki for usage; one checked-in upgrade guide per major release | Keep major-version migration instructions independent and durable. |
| [Devise](https://github.com/heartcombo/devise) | 776-line all-in-one manual with a table of contents | Wiki for specialized topics | Treat as the counterexample: comprehensive, but hard to scan and easy to duplicate. |
| [Faraday](https://github.com/lostisland/faraday) | 67 lines: value, start link, compatibility, contribution link | Navigated docs, API docs, and a dedicated `UPGRADING.md` | Let the README orient; let focused guides teach and migrate. |

GitHub's own README guidance says a README should explain why a project is useful, what users can do with it, how to start, and where to find longer documentation. The [AGENTS.md convention](https://agents.md/) treats `AGENTS.md` as the coding-agent complement to that human README: project layout, build/test commands, conventions, and security constraints.

### Woods documentation audit

The current repository has strong reference coverage but weak ownership boundaries:

| Finding | Evidence | Consequence |
|---|---|---|
| The root README is 655 lines and includes marketing, examples, install, MCP setup, configuration, CI, architecture, advanced features, security, upgrade, and development content. | `README.md` | Readers cannot tell which path is required; shared facts drift. |
| The default setup path is repeated in the README, Getting Started, FAQ, Why Woods, Docker guide, agent guide, and plugin skill. | `rg 'woods:install' README.md docs plugin` | One setup change requires a broad manual sync. |
| `docs/MCP_SERVERS.md` recommends unavailable tools. | Its chooser maps `console_diagnose_model`, `console_job_queues`, and `pipeline_status` as user choices. The generated inventory says Tier 2/3 console schemas never register, and packaged executables do not wire an operator. | Users and agents chase capabilities they cannot enable. |
| Top-line MCP counts emphasize theoretical inventory over the installed experience. | 29 Index schemas = 14 always-on + 15 collaborator-conditional; 31 Console schemas = 9 default + 2 opt-in + 20 Tier 2/3 inventory + `console_eval` inventory. | The product appears larger and less predictable than the executable surface actually is. |
| Agent setup and agent usage are mixed. | `docs/AGENT_GUIDE.md` contains server setup, configuration, tool catalog, workflows, and maintainer-oriented extractor details. | An agent consuming Woods gets a long manual instead of an operating sequence. |
| The upgrade guide is technically accurate but begins with identifier internals rather than a decision/runbook. | `docs/UPGRADING_TO_2.md` | Upgraders must assemble backup, destructive gates, commands, and verification themselves. |
| Marketplace compatibility metadata is stale. | `lost-in-the/plugins/README.md` and `.claude-plugin/marketplace.json` say Woods >= 1.5.0; Woods plugin skills say >= 2.0.0. | Agents may install a plugin whose documented commands do not match the gem. |

### Verified v2 public surface

The source of truth is `.Codex/release-v2/surface-inventory.json`, generated from code and checked in CI.

| Surface | Verified v2 value | Documentation rule |
|---|---|---|
| Ruby | >= 3.0 | State once in README and Getting Started. |
| Rails | >= 6.0, < 9 | State once in README and Getting Started. |
| MCP SDK | >= 1.2, < 2.0 | Explain only in the upgrade/protocol section. |
| Rake tasks | 32 | Teach the core lifecycle; link a compact reference instead of listing all tasks in the README. |
| Extractors | 34 | Keep the count in reference material, not the quick start. |
| Index MCP | 14 always-on tools; 15 additional tools require collaborators at server construction | Lead with 14. State that normal packaged launchers do not expose a user switch for operator/feedback/snapshot wiring. |
| Console MCP | 9 default; 11 with `console_embedded_read_tools`; 31 schemas in source | Lead with 9/11. Treat the remaining schemas as non-executable inventory, not product capabilities. |
| Index resources | 2 resources and 2 templates | Keep in MCP reference, not onboarding. |
| Storage presets | `local`, `shared_filesystem`, `postgresql`, `production` | Explain that presets select adapter types and still require their provider/service dependencies. |

## Audience Requirements

### People installing and using the gem

They need, in this order:

1. A one-sentence explanation of what Woods changes for them.
2. Compatibility and trust-boundary information.
3. The shortest useful path: add gem, generate config, migrate, extract, validate, connect the Index Server.
4. A clear statement that embeddings and Console MCP are optional.
5. A choice guide for Docker, embeddings, shared indexes, and live data.
6. Expected success signals and first troubleshooting steps.
7. Stable links to configuration and deeper reference.

Owner: `README.md` for orientation, `docs/GETTING_STARTED.md` for the complete first run.

### People and agents contributing to Woods

They need:

1. Repository purpose and public-contract boundaries.
2. Exact setup, unit, integration, matrix, backend, lint, and release-surface commands.
3. File ownership and where similar changes live.
4. Required documentation/plugin synchronization rules.
5. Security constraints for Console MCP and release artifacts.
6. PR expectations and what evidence reviewers expect.

Owners: `CONTRIBUTING.md` for shared policy; `AGENTS.md` for precise agent execution and non-obvious invariants.

### Agents installing or configuring the gem

They need:

1. A version preflight before suggesting commands.
2. Environment discovery: host vs Docker, app root, database adapter, optional embedding provider.
3. A conservative default: structural extraction and Index MCP first.
4. Exact files the generator creates and a reminder to inspect generated changes.
5. Verification after every state change.
6. Stop conditions for migration conflicts, production Console enablement, destructive purge overrides, and secrets.
7. Machine-copyable handoff instructions.

Owners: new `docs/AGENT_SETUP.md` plus the `woods-setup` plugin skill.

### Agents installing or configuring MCP

They need:

1. The split-process model: extraction inside Rails; Index Server on the host over published files; Console Server inside a live Rails process.
2. Correct host/container path translation.
3. Client config templates with absolute/relative path rules.
4. A choice between Index-only, Index + Console stdio, and authenticated Console HTTP.
5. The exact tools each configuration makes available.
6. Security boundaries and a refusal to enable live-data access silently.
7. Connection verification using a real MCP client or repository tests, not an incomplete hand-written protocol request.

Owners: `docs/MCP_SERVERS.md` plus the `woods-mcp-config` plugin skill.

### Agents using MCP

They need:

1. Start with `woods_status` to learn readiness and capabilities.
2. Use `search` to discover identifiers, then `lookup` for full context.
3. Use `dependencies` for forward flow and `dependents` for blast radius.
4. Use `trace_flow`, graph tools, and `framework` for specialized questions.
5. Use `codebase_retrieve` only when embeddings are ready.
6. Treat Console tools as live-data access; minimize scope and avoid sensitive fields.
7. Read structured MCP errors and retry only when the error contract says retry.
8. Avoid assuming a tool exists merely because it appears in source inventory.

Owner: `docs/AGENT_GUIDE.md`; examples remain in `docs/MCP_TOOL_COOKBOOK.md`.

## Information Architecture

| Document | Single responsibility | Target size |
|---|---|---:|
| `README.md` | Product orientation, trust boundary, compatibility, 5-minute Index quick start, next-step routing | 180-260 lines |
| `docs/README.md` | Audience/task router and canonical-owner map | 80-130 lines |
| `docs/GETTING_STARTED.md` | Human first run from dependency to first useful MCP question | 220-320 lines |
| `docs/AGENT_SETUP.md` | Safe, deterministic install/configure handoff for agents | 180-280 lines |
| `docs/MCP_SERVERS.md` | MCP architecture, client configuration, actual executable tool surfaces, security | 260-380 lines |
| `docs/AGENT_GUIDE.md` | MCP operating workflows and tool-selection rules for agents | 220-340 lines |
| `docs/UPGRADING_TO_2.md` | v1-to-v2 decision, backup, migration, verification, rollback, agent handoff | 220-320 lines |
| `CONTRIBUTING.md` | Shared contributor workflow and validation | 150-230 lines |
| `AGENTS.md` | Agent-specific repository map, commands, invariants, and documentation sync contract | 140-220 lines |
| `plugin/skills/*` | Claude Code workflows that mirror canonical human/agent docs | 80-180 lines each |

Deep references (`CONFIGURATION_REFERENCE`, `CONSOLE_MCP_SETUP`, `DOCKER_SETUP`, `TROUBLESHOOTING`, extractor/retrieval/backend references) remain in place. The rewrite links to them instead of reproducing them.

## Content Rules

1. **One canonical owner per fact.** Other pages summarize and link.
2. **Required before optional.** Structural Index setup precedes embeddings, Console, exports, watch, and HTTP.
3. **Outcome before mechanism.** Each task says what success looks like before internals.
4. **Executable before theoretical.** Document tools users can list and call before source-only inventories.
5. **Human and agent paths share commands, not prose.** Agent docs add preflight, safety, branching, and stop conditions.
6. **Version-qualified migration facts.** Upgrade copy names v1.6.1 as the last v1 release and 2.0.0 as the target.
7. **No unverified performance numbers.** Remove “10-30 seconds” unless a reproducible benchmark supports it.
8. **No “no external services” for Ollama.** Say “local, no cloud API key”; Ollama is still a required local service.
9. **No fake MCP smoke tests.** Use tested commands or client-native inspection; do not promise that an initialize-less JSON-RPC `tools/list` pipe is sufficient.
10. **Search-friendly language.** Pair terms with plain descriptions: “Index Server (pre-extracted code context),” “Console Server (live Rails data),” and “semantic search (natural-language retrieval using embeddings).”

## MCP Scope Assessment

### Index Server

The 14-tool default surface is appropriately sized. It covers health, exact search, full lookup, graph traversal, flow tracing, framework source, change recency, reload, and optional semantic retrieval without forcing users to understand backend wiring.

The 29-tool marketing number is too large for the normal user experience. Five operator tools, four feedback tools, four snapshot tools, session tracing, and Notion only register when Ruby collaborators are passed to `Woods::MCP::Server.build`; normal packaged executables do not offer a configuration switch for most of that wiring. Documentation should call these an embedding API surface, not imply that adding an initializer key exposes them.

One naming inconsistency needs documentation containment: the inventory defines `pipeline_diagnose`, while older prose also says `pipeline_health`; all rewritten docs will use inventory names only.

### Console Server

The 9 default and 11 opt-in tools are a coherent read-only product. The additional Tier 2/Tier 3/`console_eval` schemas do too much as public-facing inventory because they cannot execute in a supported mode. They create support burden and agent confusion without adding capability.

This documentation PR will not change the API. It will:

- present 9/11 as the complete supported Console surface;
- move the other 20 Tier 2/3 schemas and `console_eval` into a clearly labeled implementation inventory note;
- recommend a post-launch code decision: either implement and secure those schemas or remove them from the public inventory.

## v1.6.1 to v2.0.0 Upgrade Coverage

The guide will distinguish required actions from new capabilities:

| Change | User impact | Required action |
|---|---|---|
| Correct namespaced and constrained-route identifiers | Saved identifiers and exports can miss | Back up durable stores, clean extract, re-embed, re-export. |
| Per-generation payload layout via `generation.json` | Direct file consumers looking for root `manifest.json` break | Use the payload pointer; Woods-owned readers require no special action. |
| Typed graph identity | Same identifier can exist for multiple unit types | Re-index; update custom graph consumers for `variants` if applicable. |
| MCP dependency from `< 1.0` to `>= 1.2, < 2.0` | Modern protocol, discovery, cache hints, task polling | Update bundle and remove unnecessary forced `MCP_PROTOCOL_VERSION`. |
| New watch/refresh/evaluate task families | New operational options | Optional; no migration action. |
| Durable vector reconciliation and 30% purge guard | First post-upgrade embed may refuse intended mass deletion | Back up, inspect refusal, use `WOODS_ALLOW_PURGE=1` once only when verified. |
| Dimension preflight | Previously latent model/store mismatches now fail early | Recreate/re-embed the store at the configured dimension. |
| Exporter reconciliation guards | Rename-heavy exports may refuse mass cleanup | Follow exporter-specific backup and override instructions. |
| `config.extractors` and `config.add_gem` explicitly warn as unimplemented | Old configuration may imply behavior it never controlled | Remove or comment those settings; do not rely on them for selection. |
| Console surface tightened to 9/11 executable tools | Agents may have expected inventory-only tools | Update agent prompts/config; stop expecting Tier 2/3 or eval. |

## Risk Matrix

| Area | Risk | Blast Radius | Why |
|---|---|---|---|
| Quick-start commands | High | Every new installation | One wrong command blocks adoption immediately. |
| Upgrade purge guidance | High | Durable vector stores and managed exports | Incorrect override advice can delete recoverable but costly state. |
| Console security wording | High | Live application data | Ambiguous enablement can expose sensitive records or encourage unsafe production use. |
| MCP capability tables | Medium | All agent integrations | Stale tool names cause repeated failed calls and misleading setup work. |
| Plugin skill synchronization | Medium | Claude Code plugin users | Cached plugin content can outlive the gem version it describes. |
| README reduction | Low | Repository visitors | Details remain available through focused links; rollback is a Git revert. |
| Contributor/AGENTS split | Low | Maintainers and coding agents | Both files remain in place; only ownership and navigation change. |

## Alternatives Rejected

### Keep the README comprehensive

This maximizes single-page search but preserves the current duplication and drift. Devise shows that an all-in-one manual can work for a mature audience, but Woods has five distinct human/agent roles and two servers with different trust boundaries. The page would continue mixing required setup with optional internals.

### Launch a documentation website now

RuboCop and Faraday benefit from dedicated navigation and versioned publishing. Woods can adopt that later, but a site adds build, hosting, search, versioning, and release coordination work unrelated to v2 documentation correctness. Repository Markdown is already packaged with the gem and verified by integration specs.

### Create a separate document for every audience bullet

That would produce too many short files and make shared command changes harder to synchronize. The selected structure separates only where the reader's task, safety posture, or execution model changes.

## Verification and Acceptance Criteria

The rewrite is complete when:

1. `README.md` gets a user from install to a healthy Index Server without requiring embeddings or Console MCP.
2. Every audience named in this design has one obvious starting page in `docs/README.md`.
3. `docs/MCP_SERVERS.md` never recommends an inventory-only or unwired tool as normally callable.
4. `docs/AGENT_GUIDE.md` starts with an operating sequence and uses only names in the generated inventory.
5. `docs/UPGRADING_TO_2.md` has explicit backup, migrate, verify, and rollback paths plus an agent handoff block.
6. `CONTRIBUTING.md` and `AGENTS.md` contain exact, non-conflicting validation commands.
7. All three plugin skills target >= 2.0.0, link canonical docs, and pass `claude plugin validate` after a plugin version bump.
8. The paired marketplace metadata says Woods >= 2.0.0.
9. `bundle exec rake release_v2:verify_surface_inventory` passes.
10. Packaged-gem documentation/link specs pass.
11. A repository-wide Markdown link check finds no broken relative targets in changed files.
12. `git diff main...HEAD` contains documentation/plugin/metadata changes only.

## Rollback

All changes are documentation, plugin instructions, or marketplace metadata. Roll back by reverting the documentation commits in `lost-in-the/woods` and the paired metadata commit in `lost-in-the/plugins`. No generated index, database schema, release artifact, or user data changes as part of this work.

## Gotchas

- The root `.hermes/` directory is pre-existing, untracked user state and must remain untouched.
- Woods documentation is packaged with the gem. Relative links from `README.md` must resolve inside the built artifact, not only on GitHub.
- The marketplace follows Woods `main` through `git-subdir`. A skill content change requires a version bump in `plugin/.claude-plugin/plugin.json` or installed users keep the cached version.
- `woods-testbed` is evidence and validation infrastructure, not the owner of gem usage documentation. Do not duplicate the Woods manual there.
- Counts such as 34 extractors, 29 Index schemas, and 31 Console schemas are guarded by the release surface inventory. If prose count placement changes, regenerate and verify the inventory rather than hand-editing its JSON.
- `docs/CONSOLE_MCP_SETUP.md` remains the security reference. The rewritten MCP overview must link to it instead of re-explaining every defense layer.
