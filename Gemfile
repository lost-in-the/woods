# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in woods.gemspec
gemspec

group :development, :test do
  gem 'benchmark-ips', '~> 2.0'
  gem 'bundler', '>= 2.0'
  gem 'bundler-audit', '~> 0.9'
  gem 'debug', '>= 1.0.0'
  # activesupport for specs that don't need full Rails
  gem 'activesupport'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '~> 1.50'
  gem 'rubocop-rails', '~> 2.19'
  gem 'rubocop-rspec', '~> 3.9'
  gem 'simplecov', '~> 0.22', require: false
  gem 'sqlite3', '>= 1.4'
  # Optional: only needed for flow analysis (AST parsing)
  gem 'parser', '~> 3.3'
  gem 'prism', '>= 0.24'
  # Optional: exact token counting for the Ollama embedding path. Uses the
  # `bert-base-uncased` WordPiece tokenizer that nomic-embed-text is built
  # on, so we can size chunks to num_ctx without char-ratio guessing.
  # Users running OpenAI don't need this. Users on Ollama install it in
  # their own Gemfile to opt into exact sizing (see docs/CONFIGURATION_REFERENCE).
  gem 'tokenizers', '~> 0.5'
end
