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
8. Open a pull request

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

The gem supports `railties >= 6.0`. CI runs the unit suite across Ruby 3.0–4.0
and a booted-app extraction test (`spec/integration/booted_extraction_spec.rb`,
against `spec/dummy`) across Rails 6.0–8.0 using per-version gemfiles under
`gemfiles/`. The Rails pins live in `Appraisals`; the gemfiles are hand-maintained
(`eval_gemfile`-ing the base `Gemfile` and pinning Rails) because Appraisal can't
generate from the conditional base Gemfile. To run a single Rails row locally:

```bash
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile \
  bundle exec rspec spec/integration/booted_extraction_spec.rb
```

The booted-app spec is tagged `:booted_app` and excluded from the default
`rake spec` run (it needs full Rails, which the base Gemfile doesn't bundle).
When adding a Rails line, add it to both `Appraisals` and `gemfiles/`, and add a
valid Ruby×Rails pair to the `rails-matrix` job in `.github/workflows/ci.yml`.

## Code Style

- `frozen_string_literal: true` on every file
- YARD documentation on public methods
- `rescue StandardError`, never bare `rescue`
- All extractors return `Array<ExtractedUnit>`

## Runtime Introspection Requirement

Woods uses runtime introspection, not static parsing. If your feature requires access to Rails internals (ActiveRecord reflections, route introspection, etc.), it must run inside a booted Rails environment. Unit tests should use mocks/stubs; integration tests should run in a real Rails app.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
