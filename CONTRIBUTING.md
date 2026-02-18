# Contributing to CodebaseIndex

Thank you for your interest in contributing to CodebaseIndex!

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
git clone https://github.com/LeahArmstrong/codebase_index.git
cd codebase_index
bin/setup
bundle exec rake spec    # Run tests
bundle exec rubocop      # Check style
```

## Testing

CodebaseIndex has two test suites:

- **Gem unit specs** (`spec/`): Run with `bundle exec rake spec`. No Rails boot required.
- **Integration specs**: Run inside a host Rails app to test real extraction.

All new features need tests. Bug fixes should include a regression test.

## Code Style

- `frozen_string_literal: true` on every file
- YARD documentation on public methods
- `rescue StandardError`, never bare `rescue`
- All extractors return `Array<ExtractedUnit>`

## Runtime Introspection Requirement

CodebaseIndex uses runtime introspection, not static parsing. If your feature requires access to Rails internals (ActiveRecord reflections, route introspection, etc.), it must run inside a booted Rails environment. Unit tests should use mocks/stubs; integration tests should run in a real Rails app.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
