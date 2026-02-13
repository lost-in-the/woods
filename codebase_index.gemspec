# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'codebase_index'
  spec.version       = '0.1.0'
  spec.authors       = ['Your Name']
  spec.email         = ['your.email@example.com']

  spec.summary       = 'Rails codebase extraction and indexing for AI-assisted development'
  spec.description   = <<~DESC
    CodebaseIndex extracts structured data from Rails applications for use in
    AI-assisted development tooling. It provides version-specific context by
    running inside Rails to leverage runtime introspection, inlining concerns,
    mapping routes to controllers, and indexing the exact Rails/gem source
    versions in use.
  DESC
  spec.homepage      = 'https://github.com/yourusername/codebase_index'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem
  spec.files = Dir[
    'lib/**/*',
    'exe/*',
    'LICENSE.txt',
    'README.md',
    'CHANGELOG.md'
  ]
  spec.bindir = 'exe'
  spec.executables = ['codebase-index-mcp']
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'mcp', '~> 0.6'
  spec.add_dependency 'rails', '>= 6.1'

  spec.add_dependency 'parser', '~> 3.3'
  spec.add_dependency 'prism', '>= 0.24'

  # Development dependencies
  spec.add_development_dependency 'bundler', '>= 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
  spec.add_development_dependency 'rubocop-rails', '~> 2.19'
  spec.add_development_dependency 'rubocop-rspec', '~> 2.22'
end
