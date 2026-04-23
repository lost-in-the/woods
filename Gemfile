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
  # sqlite3 2.0+ requires RubyGems >= 3.3.22, which Ruby 3.0.7 doesn't ship
  # (it's stuck on 3.2.33). Pin to the 1.x line on 3.0 so the matrix row
  # can still resolve; everywhere else we get the latest.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1')
    gem 'sqlite3', '>= 1.4'
  else
    gem 'sqlite3', '>= 1.4', '< 2.0'
  end
  # Optional: only needed for flow analysis (AST parsing)
  gem 'parser', '~> 3.3'
  gem 'prism', '>= 0.24'
  # Optional: exact token counting for the Ollama embedding path. Uses the
  # `bert-base-uncased` WordPiece tokenizer that nomic-embed-text is built
  # on, so we can size chunks to num_ctx without char-ratio guessing.
  # Users running OpenAI don't need this. Users on Ollama install it in
  # their own Gemfile to opt into exact sizing (see docs/CONFIGURATION_REFERENCE).
  # Gated to Ruby >= 3.1 — the gem itself requires 3.1+, and the TokenCounter
  # falls back to a chars/token ratio when the gem is absent.
  install_if -> { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1') } do
    # Pinned to 0.5.x — tokenizers 0.6 requires Ruby 3.2+, which would
    # break our 3.1 CI matrix row.
    gem 'tokenizers', '~> 0.5.0'
  end
end
