# frozen_string_literal: true

require_relative 'lib/woods/version'

Gem::Specification.new do |spec|
  spec.name          = 'woods'
  spec.version       = Woods::VERSION
  spec.authors       = ['Leah Armstrong']
  spec.email         = ['info@leah.wtf']

  spec.summary       = 'Rails codebase extraction and indexing for AI-assisted development'
  spec.description   = <<~DESC
    Woods extracts structured data from Rails applications for use in
    AI-assisted development tooling. It provides version-specific context by
    running inside Rails to leverage runtime introspection, inlining concerns,
    mapping routes to controllers, and indexing the exact Rails/gem source
    versions in use.
  DESC
  spec.homepage      = 'https://github.com/lost-in-the/woods'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.0.0'

  release_ref = "v#{spec.version}"
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/#{release_ref}"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/#{release_ref}/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri'] = "#{spec.homepage}/tree/#{release_ref}/docs"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem
  spec.files = Dir[
    'lib/**/*',
    'exe/*',
    'docs/**/*',
    'plugin/**/*',
    'plugin/.claude-plugin/plugin.json',
    'assets/woods-wordmark-white-with-bg.png',
    'LICENSE.txt',
    'README.md',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md',
    'SECURITY.md'
  ]
  spec.bindir = 'exe'
  spec.executables = %w[woods-mcp woods-mcp-start woods-console-mcp woods-console
                        woods-mcp-http]
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'mcp', '>= 1.2', '< 2.0'
  spec.add_dependency 'msgpack', '>= 1.5', '< 2'
  # `prism` ships in stdlib on Ruby 3.3+; the gem fills the gap for 3.0–3.2.
  # EvalGuard reuses the existing Woods::Ast::Parser, which already auto-detects
  # Prism vs the parser gem — this dep guarantees the Prism path on the lower
  # Ruby range so the guard's behavior stays consistent across the support matrix.
  spec.add_dependency 'prism', '~> 1.4'
  # Floor is Rails 6.0: Woods runs cleanly on the 6.0 series (extraction + index
  # MCP serving). The only 6.1-introduced APIs touched (connection_db_config,
  # has_many_inversing) are respond_to?-guarded and degrade on 6.0. The Rails
  # version matrix in CI gates this floor. See #135 / #136.
  spec.add_dependency 'railties', '>= 6.0', '< 9'
end
