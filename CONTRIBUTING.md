# Contributing to Woods

<!-- release-state:contributing-intro -->
Woods welcomes bug fixes, extractor coverage, storage and retrieval improvements, MCP compatibility work, documentation, and focused performance changes. This guide covers the shared contribution contract. Coding agents working from a source checkout should also read the repository's [AGENTS.md](https://github.com/lost-in-the/woods/blob/main/AGENTS.md).
<!-- release-state:end -->

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

`main` is the development branch: it holds work for the next release and can run ahead of the latest published gem. Releases are cut from version tags by the guarded workflow in the [release section below](#release-flow); documentation matching a published gem lives on that release's tag.

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

<!-- release-state:contributing-architecture -->
Read [CLAUDE.md](https://github.com/lost-in-the/woods/blob/main/CLAUDE.md) for architecture and implementation gotchas before changing runtime behavior.
<!-- release-state:end -->

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

Coverage from the default process excludes opt-in Rails, installed-artifact, and live-backend lanes. Report their results separately; a low percentage for subprocess-driven tasks does not establish that they are untested. CI enforces the aggregate line floor and measures branches, but does not enforce a branch floor. Add behavior-based regressions and real optional-gem fixtures for changed extraction paths before proposing higher thresholds.

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

### Live storage and SQL dialects

The opt-in `live-backends` lane verifies behavior against PostgreSQL/pgvector and Qdrant that doubles cannot prove, including batch conflicts, delete addressing, filter translation, and extension setup.

```bash
BUNDLE_GEMFILE=gemfiles/live_backends.gemfile bundle install
WOODS_RUN_LIVE_BACKENDS=1 BUNDLE_GEMFILE=gemfiles/live_backends.gemfile \
  bin/rspec spec/integration/live_backends_spec.rb spec/integration/console_sql_dialects_spec.rb
```

The lane expects reachable PostgreSQL/pgvector, MySQL, and Qdrant services. Configure endpoints with `WOODS_PG_URL`, `WOODS_MYSQL_URL`, and `WOODS_QDRANT_URL`. The Console contracts exercise blocked-table enforcement and legitimate SQL on both database dialects. New adapter behavior that depends on a real server belongs in this lane.

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

## Release flow

`main` is the development branch and never claims a released version. Between releases it carries the alpha development marker. Every release, including a beta or a release candidate, is an explicit commit plus a tag, cut by one rake task and published only by the guarded workflow.

| State | `Woods::VERSION` | Tagged | On RubyGems | Documentation links point at |
|---|---|---|---|---|
| Development | `X.Y.Z.alpha` | never | never | `main` |
| Beta | `X.Y.Z.betaN` | `vX.Y.Z.betaN` | prerelease | the tag |
| Release candidate | `X.Y.Z.rcN` | `vX.Y.Z.rcN` | prerelease | the tag |
| Release | `X.Y.Z` | `vX.Y.Z` | stable | the tag |

RubyGems treats any letter in a version as a prerelease, so a `~> 1.6` or `~> 2.0` constraint never resolves a beta or a release candidate. Adopting one is explicit: `gem "woods", "2.0.0.beta1"`.

`spec/release_v2/version_state_spec.rb` enforces this table on every commit. VERSION is either an alpha or the changelog carries its dated heading, and the four `release-state` documentation fences match the state VERSION declares.

### During feature work

- Do not edit `lib/woods/version.rb` by hand.
- Put changelog entries under `## [Unreleased]` only, beneath one of its `###` headings. Duplicate headings are merged at release time, in the order they first appear.
- Leave the `release-state` fences alone. `release:prepare` rewrites them.

### Preparing a release

One command per transition. It never commits, tags, pushes, or publishes.

| Transition | Command |
|---|---|
| Alpha to the first beta | `bin/rake "release:prepare[2.0.0.beta1]"` |
| Beta to the next beta or a release candidate | `bin/rake "release:prepare[2.0.0.rc1]"` |
| Release candidate to the release | `bin/rake "release:prepare[2.0.0]"` |
| After the release publishes, reopen development | `bin/rake "release:reopen[2.1.0.alpha]"` |

`release:prepare` refuses a dirty working tree, a version that moves backwards, a version whose base is not the line `main` is developing, and an alpha target. It then bumps VERSION, folds `## [Unreleased]` into `## [<version>] - <date>` with one block per `###` heading, restates the fences, regenerates the surface inventory, and prints the tag and dispatch commands. Every rewrite is computed before any of it is written, so a refusal leaves the working tree untouched.

A final release also absorbs every prerelease section of its own base version. Cutting `2.0.0` folds `## [2.0.0.beta1]` and `## [2.0.0.rc1]` into `## [2.0.0] - <date>` and removes their headings, prerelease entries first and anything written after them second, so the notes a user reads for 2.0.0 are the whole story rather than three fragments. An empty `## [Unreleased]` is therefore legitimate for a final release cut straight from a release candidate. A beta or a release candidate has nothing to absorb, so an empty Unreleased section refuses: there is nothing new to publish.

Review the diff and run the release contracts:

```bash
bin/rspec spec/release_v2
bin/rake release_v2:verify_surface_inventory
bin/rspec spec/integration/packaged_gem_spec.rb
```

Then commit and open a pull request. The release commit lands on `main` through review like any other change.

### After the release commit merges

A release is pinned by its tag, never by a branch:

| Step | Command | What guards it |
|---|---|---|
| Tag the merge commit | `git tag v<version> <merge-sha> && git push origin v<version>` (lightweight or annotated both work) | `script/validate-release` requires the tag to sit on `main` history, match `Woods::VERSION`, match the dated `CHANGELOG.md` heading, and not be an alpha |
| Trigger the release workflow | `gh api --method POST repos/lost-in-the/woods/dispatches -f event_type=release -F 'client_payload[tag]=v<version>' -F 'client_payload[ci_run_id]=<id>'` where `<id>` is the green CI run on the tagged SHA (requires Contents write) | `.github/workflows/release.yml` re-validates the named CI run through the API, verifies the artifact digest, and runs secret-free candidate package tests before publishing |
| Verify publication | `gem info woods --remote` shows the new version; for a prerelease, `gem info woods --remote --prerelease`. The README gem badge updates on its own | just before pushing, the workflow re-runs `script/verify-release-tag` so a tag that moved since validation aborts the publish |

Nothing is published from a laptop: the workflow builds and pushes the gem from the validated CI artifact, so the bytes on RubyGems are the bytes CI tested. `rake release` and `rake release:rubygem_push`, which `bundler/gem_tasks` installs, are blocked for that reason.

After a final release publishes, reopen development with `release:reopen` in a follow-up pull request.

### Stable branches

A stable branch is `N-M-stable`, cut from the release tag. Create one only when a released line needs a patch after a newer major has shipped on `main`; until then, `main` is the only branch. There is no stable branch today.

### What coding agents may do

Agents may run `release:prepare` and `release:reopen` when asked, report the commands those tasks print, and prepare the pull request. Agents must not edit `lib/woods/version.rb` or the `release-state` fences by hand, create or push tags, dispatch the release workflow, or run any form of `gem push`. See `.claude/skills/release-flow/SKILL.md`.
