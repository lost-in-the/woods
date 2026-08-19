# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in woods.gemspec
gemspec

# sqlite3 2.0+ requires RubyGems >= 3.3.22, which Ruby 3.0.7 doesn't ship (it's
# stuck on 3.2.33) — pin to the 1.x line there. WOODS_SQLITE3_REQ lets the
# old-Rails appraisal gemfiles hold sqlite3 to '~> 1.4' (Rails < 7.1 pins that in
# its adapter at load time); the unit suite and newer Rails take the latest.
sqlite3_requirement =
  if (req = ENV.fetch('WOODS_SQLITE3_REQ', nil)) && !req.empty?
    [req]
  elsif Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1')
    ['>= 1.4']
  else
    ['>= 1.4', '< 2.0']
  end

group :development, :test do
  gem 'appraisal', '~> 2.5'
  gem 'benchmark-ips', '~> 2.0'
  # `benchmark` left Ruby's default gems in 4.0; the performance specs (and
  # benchmark-ips) `require 'benchmark'`, so declare it explicitly.
  gem 'benchmark'
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
  gem 'sqlite3', *sqlite3_requirement
  # A Rack handler so `exe/woods-mcp-http` can actually boot. The HTTP transport
  # is optional and users pick their own server, but the suite needs one to
  # exercise the binary. Opt in with
  # WOODS_RUN_HTTP_SERVER=1 (see spec/mcp/http_server_e2e_spec.rb).
  gem 'puma', '>= 6.0'
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
  # Note: `install_if` still resolves the gem during `bundle lock`, so on
  # Ruby 3.0 we have to skip the declaration entirely or lock fails before
  # install runs. Pinned to 0.5.x — tokenizers 0.6 requires Ruby 3.2+,
  # which would break our 3.1 CI matrix row.
  #
  # `install_if` gate: tokenizers 0.5.x links rb-sys 0.9.111, whose native
  # build cannot compile against the Ruby 4.0 ABI. Keep it in the lock for the
  # 3.1–3.x rows but skip *installing* it on Ruby >= 4.0 — exact token counting
  # is opt-in (Ollama path only) and TokenCounter falls back to a chars/token
  # ratio when the gem is absent, so the suite runs fine without it.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1')
    install_if -> { Gem::Version.new(RUBY_VERSION) < Gem::Version.new('4.0') } do
      gem 'tokenizers', '~> 0.5.0'
    end
  end
end
