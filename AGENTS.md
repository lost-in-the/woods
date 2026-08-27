# Woods coding-agent instructions

Woods is a Ruby gem that boots Rails, extracts the application's resolved runtime structure, publishes an atomic codebase index, and exposes it through MCP. Work narrowly: public extraction identifiers, generated artifacts, MCP schemas, and plugin guidance are compatibility surfaces.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for shared policy and [CLAUDE.md](CLAUDE.md) for architecture and implementation gotchas.

## Read before editing

1. Run `git status --short --branch` and `git diff HEAD`; preserve unrelated changes.
2. Read the nearest implementation and specs, then inspect a similar pattern elsewhere.
3. Check `git log` or `git diff main` before claiming what changed.
4. For public behavior, read its canonical document from [docs/README.md](docs/README.md).
5. For extractor or Rails-version work, inspect `spec/integration/booted_extraction_spec.rb` and the matching appraisal gemfiles.
6. For a task, executable, config, or MCP change, inspect `plugin/skills/` before completion.

## Repository map

| Area | Paths |
|---|---|
| Extraction and graph | `lib/woods/extractor.rb`, `lib/woods/extractors/`, `lib/woods/dependency_graph*`, `lib/woods/graph_*` |
| Index MCP | `lib/woods/mcp/`, `exe/woods-mcp*` |
| Console MCP | `lib/woods/console/`, `exe/woods-console-mcp` |
| Storage/retrieval | `lib/woods/storage/`, `lib/woods/embedding/`, `lib/woods/retrieval/` |
| Operational tasks | `lib/tasks/` |
| Tests and Rails fixture | `spec/`, `spec/dummy/`, `gemfiles/` |
| Public docs and skills | `README.md`, `docs/`, `plugin/skills/` |
| Generated release evidence | `.Codex/release-v2/surface-inventory.json` |

## Commands

```bash
bin/setup
bin/rspec spec/path/to/spec.rb
bin/rake spec
bin/rubocop
```

The default suite excludes booted Rails and live backends. Run the relevant opt-in lane when behavior depends on them:

```bash
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile \
  bin/rspec spec/integration/booted_extraction_spec.rb

WOODS_RUN_LIVE_BACKENDS=1 BUNDLE_GEMFILE=gemfiles/live_backends.gemfile \
  bin/rspec spec/integration/live_backends_spec.rb
```

Use the repository's selected Ruby and Bundler. Do not broadly update dependencies to make one command pass.

## Invariants

### Extraction

- Extract Rails behavior through runtime reflection, not static parsing.
- A full extraction publishes one complete generation; readers must never observe mixed generations.
- Identifiers, typed graph identity, relationship labels, and generated layout are public contracts.
- Whole-app extractors rerun on their trigger paths during incremental extraction; do not treat them as single-file units.
- Reproduce Rails boot and eager loading before changing Woods to handle an application boot failure.

### Index MCP

- The packaged default exposes 14 tools. `codebase_retrieve` registers but needs embeddings to return semantic context.
- The other 15 schemas require specialized builder collaborators or configuration. The packaged executable does not wire pipeline-operator or feedback-store capabilities.
- Extraction runs in Rails; the Index Server reads the published index without booting Rails.
- Docker clients must use a path visible to the process that starts MCP, usually the host side of a volume.
- Keep stdout protocol-only. Normally leave `MCP_PROTOCOL_VERSION` unset so the SDK negotiates.

### Console MCP

- The Console Server boots Rails and can read live application data; it is optional and disabled by default.
- Supported packaged modes register nine default tools or eleven with `console_embedded_read_tools`.
- Tier 2, Tier 3, and `console_eval` are source inventory only and never execute in a supported packaged mode.
- Do not weaken blocked-table, credential-scan, redaction, SQL-validation, or transaction safeguards to make a query pass.

## Public-surface evidence

`.Codex/release-v2/surface-inventory.json` is generated evidence for extractor, task, executable, preset, and MCP counts. When changing a public surface:

1. update code and contract specs;
2. regenerate or verify the inventory through its repository task;
3. compare every documentation claim with executable registration, not schema existence;
4. update the canonical guide and affected plugin skills;
5. update `CHANGELOG.md` when user-visible.

Do not hand-edit generated evidence to make a check pass.

## Documentation ownership

- setup: `docs/GETTING_STARTED.md`
- agent install/config: `docs/AGENT_SETUP.md`
- config keys/defaults: `docs/CONFIGURATION_REFERENCE.md`
- MCP setup and callable surface: `docs/MCP_SERVERS.md`
- MCP agent behavior: `docs/AGENT_GUIDE.md`
- Console security: `docs/CONSOLE_MCP_SETUP.md`
- v1-to-v2 migration: `docs/UPGRADING_TO_2.md`
- failures: `docs/TROUBLESHOOTING.md`
- contributor policy: `CONTRIBUTING.md`

Summarize and link from secondary pages; do not copy full setup blocks into FAQ or unrelated references.

## Plugin pairing

`plugin/` is published through the separate `lost-in-the/plugins` marketplace. If setup, configuration, executable, MCP, or diagnostic behavior changes:

- update affected `plugin/skills/{woods-setup,woods-mcp-config,woods-diagnose}` files;
- preserve installed-version preflight and do not promise unreleased capabilities;
- bump `plugin/.claude-plugin/plugin.json` when skill content changes;
- open a cross-linked marketplace PR when compatibility metadata, entry data, or ref changes.

## Completion checklist

- [ ] The change is limited to the requested behavior.
- [ ] Relevant tests failed before the fix and pass after it.
- [ ] `bin/rake spec` and `bin/rubocop` pass, or the handoff explains why not.
- [ ] Booted Rails/live backends were run when their behavior changed.
- [ ] Generated public-surface evidence matches executable behavior.
- [ ] Canonical docs, plugin skills, and changelog are synchronized.
- [ ] The full diff contains no unrelated edits, secrets, or generated local index data.
- [ ] The PR reports exact validation evidence and compatibility/rollback impact.
