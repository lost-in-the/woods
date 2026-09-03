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

`main` is the development branch: it holds work for the next release and can run ahead of the latest published gem. Releases are cut from version tags by the guarded workflow in the [release section below](#at-release-cutting-the-200-tag); documentation matching a published gem lives on that release's tag.

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
| `plugin/skills/` | Distributed Woods skills (setup/upgrade, MCP configuration, investigation, agent enablement, diagnosis) |

Read [CLAUDE.md](https://github.com/lost-in-the/woods/blob/v2.0.0/CLAUDE.md) for architecture and implementation gotchas before changing runtime behavior.

### Agent orientation and static self-map

When investigating Woods itself, agents can create a disposable, MCP-queryable
map of the gem source before planning a broad change or debugging a cross-cutting
problem:

```bash
output_dir="$(mktemp -d)"
bin/rake "woods:self_map[$output_dir]"
bundle exec woods-mcp-start "$output_dir"
```

This internal developer task publishes an atomic standard index generation.
Use `woods_status`, `structure`, `search`, `lookup`, `dependencies`, and
`dependents` to identify ownership and estimate the static blast radius. The
map is Woods-only, has no embeddings, and must remain out of version control.
It is not a replacement for booted Rails extraction or evidence of runtime
Rails behavior; use the normal host-app pipeline for that.

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

If a rake task, executable, MCP tool/argument, config key, setup step, or diagnosis path changes, inspect all five distributed skills under `plugin/skills/`. Update affected skills in the same Woods PR and bump `plugin/.claude-plugin/plugin.json` when skill content changes.

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

## At release: cutting the 2.0.0 tag

> Executed for 2.0.0 on 2026-09-02 (the release-flip commit). Kept as the template for the next major: while `main` documents an unreleased version, wrap every claim that depends on that gap in a `v2-unreleased-note` HTML comment fence, so tagging is a search, not a re-read. Do all four steps in the release commit:

| Step | What to change |
|---|---|
| Find every fence | `grep -rn "v2-unreleased-note" README.md CONTRIBUTING.md docs/` lists all of them. There are four: the `README.md` version banner, the "not published yet" note in `UPGRADING_TO_2.md`, and two around repository links in `CONTRIBUTING.md` |
| Delete the two version notes | Remove the fenced block whole in `README.md` and in `UPGRADING_TO_2.md`. Both name 1.6.1 and link the `tree/v1.6.1` tag, which is what expires |
| Repoint the `CONTRIBUTING.md` links | Keep the prose, delete the fence markers and the reminder comment, and move `blob/main/AGENTS.md` and `blob/main/CLAUDE.md` back to `blob/v2.0.0/` |
| Fold the changelog | Move `CHANGELOG.md`'s `[Unreleased]` entries into the release section so each `###` heading appears exactly once there (merge duplicates rather than appending a second block), stamp the release date, and leave an empty `[Unreleased]` for the next line of work |
| Re-verify | Run `bundle exec rake release_v2:verify_surface_inventory`, `bin/rspec spec/release_v2`, and `bin/rspec spec/integration/packaged_gem_spec.rb`, which pins the gemspec's `v2.0.0` metadata URIs and checks every local `README.md` link |

`README.md`'s "What's new in 2.0" table and its upgrade checklist describe released behavior and stay as they are.

### After the flip merges: tag and publish

The flip commit lands on `main` through a reviewed pull request like any other change. `main` is the development branch — it holds work for the next release and can run ahead of the published gem — so a release is pinned by its tag, never by a branch:

| Step | Command | What guards it |
|---|---|---|
| Tag the flip merge commit | `git tag v2.0.0 <merge-sha> && git push origin v2.0.0` (lightweight or annotated both work) | `script/validate-release` requires the tag to sit on `main` history, match `Woods::VERSION`, and match the dated `CHANGELOG.md` heading |
| Trigger the release workflow | `gh api --method POST repos/lost-in-the/woods/dispatches -f event_type=release -F 'client_payload[tag]=v2.0.0' -F 'client_payload[ci_run_id]=<id>'` where `<id>` is the green CI run on the tagged SHA (requires Contents write) | `.github/workflows/release.yml` re-validates the named CI run through the API, verifies the artifact digest, and runs secret-free candidate package tests before publishing |
| Verify publication | `gem info woods --remote` shows the new version; the README gem badge updates on its own | just before pushing, the workflow re-runs `script/verify-release-tag` so a tag that moved since validation aborts the publish |

Nothing is published from a laptop: the workflow builds and pushes the gem from the validated CI artifact, so the bytes on RubyGems are the bytes CI tested.
