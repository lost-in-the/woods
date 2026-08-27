# Contributing to Woods

Woods welcomes bug fixes, extractor coverage, storage and retrieval improvements, MCP compatibility work, documentation, and focused performance changes. This guide covers the shared contribution contract. Coding agents working from a source checkout should also read the repository's [AGENTS.md](https://github.com/lost-in-the/woods/blob/v2.0.0/AGENTS.md).

## Choose the right channel

- **Bug:** open an issue with reproduction steps, expected and actual behavior, Woods/Ruby/Rails versions, database adapter, and the smallest useful log or stack trace.
- **Feature:** describe the user problem, intended outcome, alternatives considered, and affected extraction/MCP/storage surfaces.
- **Security issue:** do not open a public issue. Follow [SECURITY.md](SECURITY.md).
- **Question or documentation gap:** open an issue and point to the page or workflow that was unclear.

Search existing issues and pull requests first. A minimal reproduction in a small Rails app is more useful than a large application dump; never attach secrets or production data.

## Development setup

Prerequisites are Git, Ruby 3.0 or later, and a Bundler version compatible with that Ruby. The repository tests several Ruby versions and intentionally does not pin one local version; select a supported Ruby with your normal version manager, then confirm `ruby --version` and `bundle --version`. `bin/setup` installs the bundle but does not install or select Ruby.

```bash
git clone https://github.com/lost-in-the/woods.git
cd woods
bin/setup
bin/rake spec
bin/rubocop
```

Create a branch from current `main`. Keep each pull request to one logical change and preserve unrelated formatting and refactors for separate work.

## Understand the repository

| Path | Responsibility |
|---|---|
| `lib/woods/extractor.rb`, `lib/woods/extractors/` | Runtime Rails extraction pipeline and extractors |
| `lib/woods/mcp/` | Read-only Index MCP server and protocol behavior |
| `lib/woods/console/` | Live Rails Console MCP and safeguards |
| `lib/woods/storage/`, `lib/woods/embedding/`, `lib/woods/retrieval/` | Persistence, vectors, and semantic retrieval |
| `lib/tasks/` | Rails/Rake operational interface |
| `spec/` | Unit, contract, and opt-in integration specs |
| `spec/dummy/` | Booted Rails fixture application |
| `docs/` | User, agent, operational, and reference documentation |
| `plugin/skills/` | Distributed Woods setup/configuration/diagnosis skills |

Read [CLAUDE.md](https://github.com/lost-in-the/woods/blob/v2.0.0/CLAUDE.md) for architecture and implementation gotchas before changing runtime behavior.

## Make the change

1. Reproduce a bug or define the expected behavior.
2. Add or update the smallest test that can fail for the behavior.
3. Make the targeted implementation change.
4. Run the narrow test, then the relevant broader suite.
5. Update the canonical documentation, plugin skill, and changelog when the public contract changes.
6. Review the complete diff before opening a pull request.

Woods extracts Rails behavior through a booted runtime. Features that depend on routes, Active Record reflections, descendants, or framework internals must use runtime introspection. Unit tests may isolate collaborators, but version-sensitive behavior also needs the booted-app lane.

## Validate in proportion to the change

Start with the smallest command that exercises your work:

```bash
# One spec file
bin/rspec spec/path/to/spec.rb

# Unit/contract suite (booted-app and live-backend lanes excluded)
bin/rake spec

# Style
bin/rubocop
```

Before requesting review, run the full unit suite and style check unless the PR explains why one cannot run.

### Rails version matrix

The gem supports Ruby 3.0 or later and Rails 6.0 through 8.x. CI separates fast unit coverage from real Rails boots:

- the base test job runs unit specs across supported Ruby versions;
- the `rails-matrix` job boots `spec/dummy` and performs extraction for each supported Rails line using `gemfiles/rails_*.gemfile`.

Run one Rails row locally:

```bash
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile \
  bin/rspec spec/integration/booted_extraction_spec.rb
```

When adding a Rails line, update `Appraisals`, the corresponding hand-maintained gemfile, and `.github/workflows/ci.yml`. For Rails below 7.1, copy an existing 6.x gemfile so its sqlite3 and concurrent-ruby compatibility pins are preserved.

### Live storage backends

The opt-in `live-backends` lane verifies behavior against PostgreSQL/pgvector and Qdrant that doubles cannot prove, including batch conflicts, delete addressing, filter translation, and extension setup.

```bash
BUNDLE_GEMFILE=gemfiles/live_backends.gemfile bundle install
WOODS_RUN_LIVE_BACKENDS=1 BUNDLE_GEMFILE=gemfiles/live_backends.gemfile \
  bin/rspec spec/integration/live_backends_spec.rb
```

The lane expects reachable PostgreSQL/pgvector and Qdrant services. Configure endpoints with `WOODS_PG_URL` and `WOODS_QDRANT_URL`. New adapter behavior that depends on a real server belongs in this lane.

## Keep public surfaces synchronized

A pull request is incomplete when behavior and user guidance disagree.

Update the canonical owner for any changed contract:

| Change | Documentation owner |
|---|---|
| Install or first run | `docs/GETTING_STARTED.md` |
| Agent-operated installation | `docs/AGENT_SETUP.md` |
| Configuration key/default | `docs/CONFIGURATION_REFERENCE.md` |
| MCP setup or registered tools | `docs/MCP_SERVERS.md` |
| Agent query workflow | `docs/AGENT_GUIDE.md` |
| Console security/transport | `docs/CONSOLE_MCP_SETUP.md` |
| Major-version behavior | `docs/UPGRADING_TO_2.md` |
| Failure diagnosis | `docs/TROUBLESHOOTING.md` |

If a rake task, executable, MCP tool/argument, config key, setup step, or diagnosis path changes, inspect all three distributed skills under `plugin/skills/`. Update affected skills in the same Woods PR and bump `plugin/.claude-plugin/plugin.json` when skill content changes.

The plugin is published through the [`lost-in-the/plugins`](https://github.com/lost-in-the/plugins) marketplace as a git-subdir reference. Open and cross-link a paired marketplace PR when compatibility metadata, the entry, or its ref must change. Skills must check the installed Woods version and must not document unreleased capabilities as available.

Update `CHANGELOG.md` for user-visible changes. Internal refactors and typo-only documentation fixes normally do not need an entry.

## Pull request evidence

Include:

- the problem and user-visible outcome;
- implementation scope and important tradeoffs;
- exact validation commands and results;
- Rails/storage lanes run or intentionally not run;
- public docs and plugin impact;
- migration, compatibility, security, and rollback notes when applicable;
- screenshots or transcript excerpts only when they materially verify behavior.

Do not use empty assertions or output-only tests. A regression test must fail before the fix and exercise the same runtime path as production behavior.

## Code conventions

- Add `# frozen_string_literal: true` to Ruby files.
- Document public APIs with YARD where it improves their contract.
- Rescue `StandardError` or a narrower class; never use a bare rescue.
- Extractors return `Array<Woods::ExtractedUnit>`.
- Keep MCP stdout free of non-protocol output.
- Prefer explicit structured errors over suppressing a failure.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE.txt).
