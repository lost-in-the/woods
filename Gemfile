# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in codebase_index.gemspec
gemspec

group :development, :test do
  gem 'debug', '>= 1.0.0'
  # activesupport for specs that don't need full Rails
  gem 'activesupport'
  gem 'bundler', '>= 2.0'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '~> 1.50'
  gem 'rubocop-rails', '~> 2.19'
  gem 'rubocop-rspec', '~> 2.22'
  gem 'sqlite3', '>= 1.4'
  # Optional: only needed for flow analysis (AST parsing)
  gem 'parser', '~> 3.3'
  gem 'prism', '>= 0.24'
end
