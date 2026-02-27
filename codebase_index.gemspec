# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'codebase_index'
  spec.version       = '0.1.0'
  spec.authors       = ['Leah Armstrong']
  spec.email         = ['info@leah.wtf']

  spec.summary       = 'Rails codebase extraction and indexing for AI-assisted development'
  spec.description   = <<~DESC
    CodebaseIndex extracts structured data from Rails applications for use in
    AI-assisted development tooling. It provides version-specific context by
    running inside Rails to leverage runtime introspection, inlining concerns,
    mapping routes to controllers, and indexing the exact Rails/gem source
    versions in use.
  DESC
  spec.homepage      = 'https://github.com/LeahArmstrong/codebase_index'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri'] = "#{spec.homepage}/tree/main/docs"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem
  spec.files = Dir[
    'lib/**/*',
    'exe/*',
    'LICENSE.txt',
    'README.md',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md'
  ]
  spec.bindir = 'exe'
  spec.executables = %w[codebase-index-mcp codebase-index-mcp-start codebase-console-mcp codebase-index-mcp-http]
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'mcp', '~> 0.6'
  spec.add_dependency 'railties', '>= 6.1'
end
