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
