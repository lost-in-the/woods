# Contributing to Woods

<!-- release-state:contributing-intro -->
Woods welcomes bug fixes, extractor coverage, storage and retrieval improvements, MCP compatibility work, documentation, and focused performance changes. This guide covers the shared contribution contract. Coding agents working from a source checkout should also read the repository's [AGENTS.md](https://github.com/lost-in-the/woods/blob/v2.0.0.beta3/AGENTS.md).
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

`Gemfile.lock` is gitignored, so a fresh worktree (as opposed to a clone) needs it copied in from an existing checkout before running any `bin/*` command.

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
Read [CLAUDE.md](https://github.com/lost-in-the/woods/blob/v2.0.0.beta3/CLAUDE.md) for architecture and implementation gotchas before changing runtime behavior.
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

Coverage from the default process excludes opt-in Rails, installed-artifact, and live-backend lanes. Report their results separately; a low percentage for subprocess-driven tasks does not establish that they are untested. CI enforces a 90% aggregate line floor and measures branches, but does not enforce a branch floor. The line gate was calibrated against local and CI default-suite results on 2026-09-18; it does not establish per-file coverage or coverage across the opt-in lanes. Add behavior-based regressions and real optional-gem fixtures for changed extraction paths before proposing higher thresholds.

### Pending examples in CI

CI fails when a running example becomes unexpectedly pending, including `skip`,
`xit`, and pending metadata. `spec/support/pending_policy.rb` records the exact
file, full description, reason, and unavailable capability for each reviewed
exception. Current exceptions cover the two optional tiktoken benchmarks, one
optional Tokenizers example, two Ruby-before-3.2 regexp-timeout examples, one
procfs example, and three filesystem-permission examples when running as root.
The Linux CI unit jobs run the real procfs identity example as an unprivileged
user, so the procfs and root exceptions normally apply only to other environments.
Opt-in suites excluded by their documented environment gates are not pending
examples. Focused runs do not need to include every reviewed exception.

Adding a new skip requires review of both its exact entry and capability check;
matching an existing reason alone is insufficient. Local runs retain normal
RSpec pending behavior. Exercise the policy and matrix consistency checks with
`CI=true bin/rspec spec/ci`.

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

The unit suite evaluates every hand-maintained Rails gemfile and checks its
Appraisal requirements, old-Rails compatibility pins, and CI matrix membership.
This detects configuration drift; it does not replace the booted rows.

### Exact runtime dependency floors

The separate `minimum-dependencies` CI job runs on Ruby 3.0 with Bundler 2.5.23:

```bash
gem install bundler -v 2.5.23
ruby script/test-minimum-dependencies
```

Run outside `bundle exec`. The harness builds and installs the candidate gem,
resolves `gemfiles/minimum_runtime.gemfile` independently of the development
bundle, and verifies every loaded Woods library comes from that installed gem.
All five direct runtime dependencies are pinned to their advertised gemspec
floors. Transitive dependencies are compatible solver selections, **not** a
claim that every transitive version is minimal. CI retains the full resolved
version/platform list, lockfile, candidate gem and SHA-256 under the
`minimum-runtime-dependencies` artifact; local output defaults to
`tmp/minimum-dependencies/`.

The probe exercises lexical retrieval and typed lookup over a synthetic published
index, MCP SDK dispatch, Prism parsing, and MessagePack snapshots. It also boots
an actual Rails 6.0.0 API-style app, loads Woods tasks, and checks the real Rails
middleware stack for disabled Console passthrough, authorized requests, missing
and incorrect token refusal, and forbidden origins. Static serving is explicitly
disabled: Rails 6.0.0's own Static middleware predates Ruby 3 keyword forwarding.
This is a bounded Woods runtime-floor contract, not evidence that arbitrary
Rails 6.0.0 applications boot on Ruby 3. The booted Rails matrix uses compatible
patch releases and covers full extraction; enabled database-backed Console and
optional storage/provider combinations remain in their separate lanes.

The exact-floor job is required by release CI validation. Changing a runtime
lower bound requires updating its explicit pin and retaining a successful
installed-artifact run, rather than silently advancing a pin to make CI pass.

When adding a Rails line, update `Appraisals`, the corresponding hand-maintained gemfile, and `.github/workflows/ci.yml`. For Rails below 7.1, copy an existing 6.x gemfile so its sqlite3 and concurrent-ruby compatibility pins are preserved.

### Live storage and SQL dialects

The opt-in `live-backends` lane verifies behavior against PostgreSQL/pgvector and Qdrant that doubles cannot prove, including batch conflicts, delete addressing, filter translation, and extension setup.

```bash
BUNDLE_GEMFILE=gemfiles/live_backends.gemfile bundle install
WOODS_RUN_LIVE_BACKENDS=1 BUNDLE_GEMFILE=gemfiles/live_backends.gemfile \
  bin/rspec spec/integration/live_backends_spec.rb spec/integration/console_sql_dialects_spec.rb
```

The lane expects reachable PostgreSQL/pgvector, MySQL, and Qdrant services. Configure endpoints with `WOODS_PG_URL`, `WOODS_MYSQL_URL`, and `WOODS_QDRANT_URL`. The Console contracts exercise blocked-table enforcement and legitimate SQL on both database dialects. New adapter behavior that depends on a real server belongs in this lane.

### Solid Cache session compatibility

The live-backend job runs `spec/integration/solid_cache_compatibility_spec.rb`
against SQLite, PostgreSQL, and MySQL. MySQL coverage asserts that the adapter
has no insert `RETURNING`, checks actual insert ownership (including same-value
conflicts), exercises concurrent ownership, expiry, conditional deletion, and
session clear/epoch recovery. A separate case strips only insert-result metadata
to exercise the older Rails read-back fallback against real MySQL rows.

Solid Cache coordination depends on private APIs. Before declaring a newly
resolved `solid_cache` version supported:

1. Record the exact Ruby, Active Record, Solid Cache, and database versions.
2. Run the complete compatibility file against disposable PostgreSQL and MySQL
   databases, with `WOODS_RUN_LIVE_BACKENDS=1`,
   `BUNDLE_GEMFILE=gemfiles/live_backends.gemfile`, `WOODS_PG_URL`, and
   `WOODS_MYSQL_URL` set. The suite recreates `solid_cache_entries`; never point
   it at an application cache database.
3. Require every example to pass, including SQLite local-cache bypass, TTL,
   sharding, missing-private-API errors, and the MySQL ownership cases. Attach
   the versions and results to the PR; a passing double-based unit suite is
   insufficient.

The live gemfile resolves `solid_cache ~> 1.0`; this is a dependency selection
range, not evidence that every version in it has been tested. The baseline
validated for #228 is Ruby 4.0.6, Solid Cache 1.0.10, Active Record 8.1.3.1,
SQLite 3.53.2, PostgreSQL 16.15, and MySQL 26.7.0.
Accepted crash/eviction limits are documented in the
[configuration reference](docs/CONFIGURATION_REFERENCE.md#solid-cache-session-retention-and-compatibility).

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

`main` is the development branch. It carries an alpha marker before the first prerelease of a version line and after reopening development following a final release. During beta/RC iteration, it retains the last prepared prerelease version until the next `release:prepare`. Every published release is identified by its exact tagged commit; later commits on `main` are not that release even if `Woods::VERSION` is unchanged.

| State | `Woods::VERSION` | Tagged | On RubyGems | Documentation links point at |
|---|---|---|---|---|
| Development | `X.Y.Z.alpha` | never | never | `main` |
| Beta | `X.Y.Z.betaN` | `vX.Y.Z.betaN` | prerelease | the tag |
| Release candidate | `X.Y.Z.rcN` | `vX.Y.Z.rcN` | prerelease | the tag |
| Release | `X.Y.Z` | `vX.Y.Z` | stable | the tag |

RubyGems treats any letter in a version as a prerelease, so a `~> 1.6` or `~> 2.0` constraint never resolves a beta or a release candidate. Adopting one is explicit: `gem "woods", "2.0.0.beta1"`.

`spec/release_v2/version_state_spec.rb` verifies that VERSION is either an alpha or the changelog carries its dated heading, and that the four `release-state` documentation fences match the state VERSION declares. Those checks do not establish that a checkout is the published release.

For Git-sourced candidates, record the locked Git revision, loaded gem path, and working-tree changes alongside `Woods::VERSION`. Version-only preflight establishes the declared version, not whether a particular post-tag fix is present. Match capability claims to the pinned commit or published tag. Generated release-state links continue to describe the prepared version; use the candidate commit when linking evidence about unreleased changes.

### During feature work

- Do not edit `lib/woods/version.rb` by hand.
- Leave the `release-state` fences alone. `release:prepare` rewrites them.
- Put changelog entries under `## [Unreleased]`, beneath one of its `###` headings, or in an optional `changelog/<type>_<slug>.md` file. Entry files avoid conflicts between parallel branches; inline entries remain supported. Duplicate headings merge at release time, in the order they first appear.

Entry files contain nonempty UTF-8 Markdown without ATX (`#`) or setext
(underlined) headings, usually a bullet
and indented continuation lines. For example, `changelog/fixed_watch-restart.md`
can contain `- Preserve pending work across watch restarts.` Supported types are
`added`, `build`, `changed`, `dependencies`, `documentation`, `fixed`,
`performance`, `security`, `testing`, and `upgrade-notes`. Slugs start with a
lowercase letter or digit and use lowercase letters, digits, hyphens, or
underscores. Use one unique file per change; do not copy its entry into
Unreleased as well. Keep entry files directly inside a real `changelog/`
directory; symlinks and directories masquerading as entries are refused.
Other file extensions are left untouched.

`release:prepare` appends entry files in filename order after inline Unreleased
entries, folds them through the same heading merger, and deletes exactly the
consumed files. It validates every entry and documentation rewrite before
changing any files; an invalid entry or a later refusal preserves all entries.
A prepared release has an empty Unreleased section and no entry files. During
an ordinary beta cycle, entry files may accumulate even with an empty Unreleased section while
VERSION stays at the previous beta; the tag validator always rejects entry
files at the candidate release SHA, regardless of inline notes or the version.

### Preparing a release

One command per transition. It never commits, tags, pushes, or publishes.

| Transition | Command |
|---|---|
| Alpha to the first beta | `bin/rake "release:prepare[2.0.0.beta1]"` |
| Beta to the next beta or a release candidate | `bin/rake "release:prepare[2.0.0.rc1]"` |
| Release candidate to the release | `bin/rake "release:prepare[2.0.0]"` |
| After a final release publishes, reopen development | `bin/rake "release:reopen[2.1.0.alpha]"` |

`release:prepare` refuses a dirty working tree, a version that moves backwards, a version whose base is not the line `main` is developing, and an alpha target. It then bumps VERSION, folds `## [Unreleased]` and optional entry files into `## [<version>] - <date>` with one block per `###` heading, restates the fences, regenerates the surface inventory, and prints the tag and dispatch commands. Every rewrite is computed before any of it is written, so a refusal leaves the working tree untouched.

`release:reopen` accepts only a final release and a strictly later alpha. It does not reopen a beta/RC or move the same version line backwards to alpha. Continue prerelease development with Unreleased notes or changelog fragments, then use `release:prepare` for the next forward beta, RC, or final when authorized.

A final release also absorbs every prerelease section of its own base version. Cutting `2.0.0` folds `## [2.0.0.beta1]` and `## [2.0.0.rc1]` into `## [2.0.0] - <date>` and removes their headings, prerelease entries first and anything written after them second, so the notes a user reads for 2.0.0 are the whole story rather than three fragments. An empty `## [Unreleased]` is therefore legitimate for a final release cut straight from a release candidate. A beta or a release candidate has nothing to absorb, so an empty Unreleased section without entry files refuses: there is nothing new to publish.

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
| Tag the merge commit | `git tag v<version> <merge-sha> && git push origin v<version>` (lightweight or annotated both work) | `script/validate-release` requires the tag to sit on `main` history (or the explicitly approved maintenance history below), match `Woods::VERSION`, match the dated `CHANGELOG.md` heading, and not be an alpha |
| Trigger the release workflow | `gh api --method POST repos/lost-in-the/woods/dispatches -f event_type=release -F 'client_payload[tag]=v<version>' -F 'client_payload[ci_run_id]=<id>'` where `<id>` is the green CI run the tag push itself started, the one whose branch column reads `v<version>`; main's run on the same commit is refused with `tested ref is main` (requires Contents write) | `.github/workflows/release.yml` re-validates the named CI run through the API, verifies the artifact digest, and runs secret-free candidate package tests before publishing |
| Verify publication | `gem info woods --remote` shows the new version; for a prerelease, `gem info woods --remote --prerelease`. The README gem badge updates on its own | just before pushing, the workflow re-runs `script/verify-release-tag` so a tag that moved since validation aborts the publish |

Nothing is published from a laptop: the workflow builds and pushes the gem from the validated CI artifact, so the bytes on RubyGems are the bytes CI tested. `rake release` and `rake release:rubygem_push`, which `bundler/gem_tasks` installs, are blocked for that reason.

After a final release publishes, reopen development with `release:reopen` in a follow-up pull request.

### When a dispatch fails

`release-context` and `publish` both check out `github.sha`, the default
branch's tip at dispatch time, not the tag: `release-context` re-validates the
named CI run, checks the live `release` environment, and runs
`script/validate-release`; `publish` runs `script/verify-release-tag` and
pushes the downloaded artifact. Only `package-test` checks out
`needs.release-context.outputs.release-sha`, the tag's own commit, because
that is what CI actually built and tested. The gem bytes `publish` pushes were
built by CI at `release-sha`; `publish` never rebuilds them.

That split decides the fix for a failed dispatch:

| What failed | Lives in | Fix |
|---|---|---|
| `script/validate-release-run`, `script/validate-release`, `script/verify-release-tag`, or the workflow files themselves | main, read at `github.sha` | merge the fix to main, then re-dispatch at the same tag; the tag never moves |
| Live `release` environment settings (protection rule, admin bypass) | GitHub environment configuration, not the tree | fix the setting directly; no commit or re-dispatch needed |
| Anything under `spec/` or `lib/` that `package-test` actually runs against the candidate | the tagged commit, read at `release-sha` | a main-only fix does not reach the candidate; merge it, then move the tag to the new main tip and get a fresh CI run on it |

Both failure classes happened in the beta1 dispatch: a `REQUIRED_CI_JOBS`
prefix left behind by a `ci.yml` job rename was a validator fix that needed
only a merge and a re-dispatch; two `packaged_gem_spec.rb` smoke failures
traced to hard-coded `2.0.0` literals needed the tag moved to the commit that
fixed them, because the candidate job runs the spec file at the tag.

**Moving a tag is acceptable only before publication.** Once `publish` has
pushed the gem to RubyGems, the tag is the permanent, immutable record of what
was published; move it before that point only, with
`git tag -f v<version> <new-sha> && git push --force origin v<version>` run by
the maintainer, followed by a fresh CI run on the new tag SHA before
re-dispatching.

### Publishing the GitHub Release entry

The workflow deliberately creates no GitHub Release: the API cannot bind an
existing tag to an expected commit atomically, so automating it would race the
tag's own verification. Once `gem info woods --remote` (or `--remote
--prerelease`) confirms publication, create the entry by hand:

```bash
gh release create v<version> --verify-tag --notes-file <file>            # release
gh release create v<version> --verify-tag --prerelease --notes-file <file> # beta or rc
```

`--verify-tag` refuses if the tag is missing or moved. Write `<file>` as a
short body that links `CHANGELOG.md` at the tag itself (not at `main`) and
anchors straight to that version's dated heading, so the note a reader lands
on always matches the bytes RubyGems published.

### One-off 1.6.3 security maintenance release

The [security policy](SECURITY.md#supported-versions) supports 1.6.x security
fixes until 2027-02-20. While main develops v2, the sole maintenance exception
is `v1.6.3` from the short-lived `release/1.6.3` branch, descending from the
immutable v1.6.2 commit `4b40e17fd68122a70ccf00d9d2ffb8af42171d3d`.
This is a stable patch, separate from the next v2 prerelease; it does not declare
v2 final or establish a general-purpose maintenance publishing path.

`script/release_profile.rb` on trusted main owns this exact tag/branch/base and
its required CI jobs. `MAINTENANCE_APPROVED_SHA` starts as `nil`: publication
fails closed until a **separate reviewed main PR** pins the exact prepared
maintenance commit. Neither a dispatch parameter nor candidate code can choose
another profile, branch, base, SHA or weaker CI requirements. The SHA binds the
whole reviewed candidate, including its CI definition and installed-package
tests; review those files as release controls, not just their job names.

The preparation order is:

1. Merge the main-side maintenance policy/tooling PR. Before creating the remote
   target, confirm its effective branch rules require pull requests and prevent
   force pushes and deletion; configure those rules before creating the target. The GitHub
   rules API can check `release/1.6.3` before the branch exists.
2. Create that target from the immutable v1.6.2 commit. Review the narrow security
   backport and its legacy preparation adapter against that line. Confirm the
   inherited automatic tag-push publisher remains disabled before any maintenance tag exists.
3. Use the legacy adapter's `release:reopen[1.6.3.alpha]` and
   `release:prepare[1.6.3]` transitions in clean, separately reviewed commits.
   The adapter owns the legacy documentation profile; do not copy v2 fences or
   surface claims into v1, and never hand-edit VERSION.
4. Review and merge the prepared candidate into `release/1.6.3`. Require passing
   unit, booted Rails, installed-package, lint, coverage, security and build
   jobs. Review the complete CI and package-test implementation at that SHA.
   Then pin that **exact final commit** in `MAINTENANCE_APPROVED_SHA` through the
   separate main PR. No pin means no maintenance release.
5. Only after the pin merges, the maintainer may tag that exact commit and wait
   for its tag-push CI run. Dispatch uses the ordinary tag/run-ID payload.
   Every exact maintenance matrix row in the trusted profile must succeed;
   missing, duplicated, skipped or failed rows refuse publication.

[Temporary security-advisory forks](https://docs.github.com/en/code-security/tutorials/fix-reported-vulnerabilities/collaborate-in-a-fork)
do not run CI or enforce destination branch protections when the advisory is
merged. Review and test those patches privately, then require the upstream CI
matrix triggered by the push to `release/1.6.3` before pinning its prepared SHA.
A private test report cannot replace the upstream tag-push run and immutable
artifact required for publication. Keep the advisory unpublished until the fixed
gems are available.

The validators require the approved SHA to remain reachable from the freshly
fetched maintenance branch and to descend from the fixed legacy base. They retain
exact tag/VERSION/changelog checks, the unpublished-version check, one immutable
CI artifact ID/digest, and protected `release` environment approval. Both Ruby
package-test rows install that same artifact and run the pinned v1-specific
`maintenance_packaged_gem_spec.rb` outside the repository load path. The oldest
Ruby maintenance row explicitly activates MCP 0.23.0, the reviewed security
floor; the latest row resolves the candidate's supported SDK range. Candidate
code still executes only in secret-free, read-only jobs. After environment
approval, maintenance history/publication checks run again before requesting
RubyGems credentials; the remote tag is checked again immediately before push.

A candidate fix or changed prepared SHA requires a new reviewed main pin and a
fresh tag-push CI run. Updating main's tooling alone never authorizes different
candidate bytes. Main's v2 release contract remains unchanged. Do not create or
push tags, dispatch, publish, or claim 1.6.3 is available during preparation.

### Stable branches

A stable branch is `N-M-stable`, cut from the release tag. Create one only when a released line needs a patch after a newer major has shipped on `main`; until then, `main` is the development branch. The explicitly approved short-lived `release/1.6.3` security exception above does not establish an `N-M-stable` branch.

### What coding agents may do

Agents may run `release:prepare` and `release:reopen` when asked, report the commands those tasks print, and prepare the pull request. Agents must not edit `lib/woods/version.rb` or the `release-state` fences by hand, create or push tags, dispatch the release workflow, or run any form of `gem push`. See `.claude/skills/release-flow/SKILL.md`.
