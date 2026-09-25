# Contributing to Woods

Thank you for your interest in contributing to Woods!

## Bug Reports

Please open an issue on GitHub with:

- A clear description of the bug
- Steps to reproduce
- Expected vs. actual behavior
- Your Ruby version, Rails version, and database adapter

## Feature Requests

Open an issue describing:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Pull Requests

1. Fork the repo and create your branch from `main`
2. Install dependencies: `bin/setup`
3. Make your changes
4. Add tests for new functionality
5. Ensure the test suite passes: `bundle exec rake spec`
6. Ensure code style passes: `bundle exec rubocop`
7. Update CHANGELOG.md with your changes
8. Complete the **Pre-PR requirements** below
9. Open a pull request

### Pre-PR requirements

These are hard gates — a PR that fails either is incomplete:

1. **Documentation must be current.** Any doc affected by the change — README, `docs/`, the
   `plugin/skills/` user guides, `CHANGELOG.md` — must be updated in the *same* PR. Don't ship
   behavior the docs still describe the old way.
2. **Investigate plugin-functionality impact.** If the change touches anything the distributed
   user skills rely on — a rake task, MCP tool or its arguments, an executable (`woods-mcp`,
   `woods-mcp-start`, `woods-console-mcp`, `woods-mcp-http`), a config key, or setup steps —
   investigate whether `plugin/skills/{woods-setup,woods-mcp-config,woods-diagnose}` need to
   change.

### Claude Code plugin changes

`plugin/` is distributed as the `woods-plugin` via the
[`lost-in-the/plugins`](https://github.com/lost-in-the/plugins) marketplace (a `git-subdir`
reference to this subtree). Installed users may run an **older** gem than `main`, so:

- If a change adds/removes/renames a tool, task, executable, or config key that a skill
  documents, **update the skill in the same PR**.
- The skills carry a Version Preflight (operate only against the installed version). **Land the
  skill change with the release that ships the capability** — never document a feature in a
  skill before the version that provides it is released. Bump `plugin/.claude-plugin/plugin.json`
  `version` when the skill content changes.
- If the change requires a new marketplace entry, `ref` pin, or metadata edit, open a **paired
  PR against `lost-in-the/plugins`** and link it from this PR.

## Development Setup

```bash
git clone https://github.com/lost-in-the/woods.git
cd woods
bin/setup
bundle exec rake spec    # Run tests
bundle exec rubocop      # Check style
```

## Testing

Woods has two test suites:

- **Gem unit specs** (`spec/`): Run with `bundle exec rake spec`. No Rails boot required.
- **Integration specs**: Run inside a host Rails app to test real extraction.

All new features need tests. Bug fixes should include a regression test.

### Rails version matrix

The gem supports `railties >= 6.0`. Coverage is split across two CI jobs:

- The base unit `test` job runs `rake spec` across **Ruby 3.0–4.0** on the
  default (newest) Rails. The unit specs stub Rails, so they run once on the base
  Gemfile rather than per Rails version.
- The `rails-matrix` job runs the **booted-app extraction test**
  (`spec/integration/booted_extraction_spec.rb` against `spec/dummy`) under each
  supported Rails — 6.0, 6.1, 7.0, 7.1, 7.2, 8.0 — using per-version gemfiles
  under `gemfiles/`. This is the version-sensitive gate: it boots a real Rails
  app in-process and runs an extraction. (The booted spec is tagged `:booted_app`
  and excluded from the default `rake spec`; `WOODS_RUN_BOOTED_APP=1` opts it in,
  and it must run in its own process — it can't share one with the unit suite.)

The Rails pins live in `Appraisals`; the gemfiles are hand-maintained
(`eval_gemfile`-ing the base `Gemfile` and pinning Rails) because Appraisal can't
generate from the conditional base Gemfile. To run a single Rails row locally:

```bash
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile \
  bundle exec rspec spec/integration/booted_extraction_spec.rb
```

When adding a Rails line: add it to both `Appraisals` and `gemfiles/`, and add a
valid Ruby×Rails pair to the `rails-matrix` job in `.github/workflows/ci.yml`.
**For a row below Rails 7.1**, the gemfile must set `ENV['WOODS_SQLITE3_REQ'] =
'~> 1.4'` *before* `eval_gemfile` (those Rails versions pin `sqlite3 ~> 1.4` in
their adapter at load time) and pin `concurrent-ruby '< 1.3.5'` (1.3.5 dropped
the implicit `require "logger"` those releases rely on under Ruby 3.x) — copy an
existing `gemfiles/rails_6.0.gemfile` as the template.

## Code Style

- `frozen_string_literal: true` on every file
- YARD documentation on public methods
- `rescue StandardError`, never bare `rescue`
- All extractors return `Array<ExtractedUnit>`

## Runtime Introspection Requirement

Woods uses runtime introspection, not static parsing. If your feature requires access to Rails internals (ActiveRecord reflections, route introspection, etc.), it must run inside a booted Rails environment. Unit tests should use mocks/stubs; integration tests should run in a real Rails app.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Maintenance release

This tree has a one-off, no-publish preparation adapter for the reviewed 1.6.4
security patch while `main` carries the newer 2.1 development line. It does not
establish a permanent stable branch or authorize another maintenance version.
The approved target is `release/1.6.4`, based on immutable `v1.6.3`. Create that
remote target only after the trusted main maintenance policy is reviewed.

From a clean checkout, the only supported transitions are:

```sh
bin/rake "release:reopen[1.6.4.alpha]"
# Review and commit the generated development-state diff.
bin/rake "release:prepare[1.6.4]"
```

The tasks never commit, tag, push, dispatch or publish. Never edit VERSION or the
README maintenance `release-state` banner manually. The existing maintenance
banner must be present; both tasks update it. Prepare also folds classified
Unreleased notes and optional `changelog/<type>_<slug>.md` entries into a dated
release heading. Entry files are
nonempty Markdown without headings; supported types include `fixed`, `security`,
`build`, and `documentation`. Invalid transitions, dirty trees, malformed notes,
and missing/duplicate/unknown fences refuse before writes. This legacy profile
has no v2 migration guide or v2 surface inventory requirement.

CI also runs on pushes to the exact `release/1.6.4` branch, so a private-advisory
merge receives upstream validation before the trusted-main SHA pin. Publication
still requires a separate green tag-push run.

Validate the full suite, lint, booted extraction, real Console credential rotation,
installed maintenance package tests, and the real PostgreSQL/MySQL Console policy lane. CI builds one gem plus its SHA-256
sidecar into `woods-release-<commit SHA>` and tests that artifact on Ruby 3.0/Rails
6.0 with exactly MCP 0.23.0 and Ruby 4.0/Rails 8.1 with the latest compatible 0.x SDK.
MCP >=0.23.0 is required for upstream transport security fixes; update Woods and
MCP together (`bundle update woods mcp`). Ruby 3.0 remains supported.
The optional package specs require `WOODS_GEM_PATH` and
run standalone, without the repository's `spec_helper` or implementation path:

```sh
ruby -rrubygems -e 'load Gem.bin_path("rspec-core", "rspec")' -- \
  --options /dev/null spec/integration/maintenance_packaged_gem_spec.rb
```

Preparation is not publication; check RubyGems before describing 1.6.4 as released.
The legacy automatic tag publisher is disabled, and Bundler's `release`,
`release:rubygem_push`, and `release:source_control_push` tasks abort. Only a
maintainer may later tag the reviewed merge commit and dispatch the trusted
**main** workflow. That workflow must explicitly allow the exact tag, protected
maintenance branch, immutable 1.6.3 base, reviewed final candidate SHA, required
CI jobs, and immutable artifact. An unpinned candidate remains blocked. First merge a reviewed trusted-main profile update pinning `approved_sha` to that
exact maintenance merge SHA; only then may the maintainer tag it. The
workflow publishes the already tested gem bytes; never rebuild or publish locally.
