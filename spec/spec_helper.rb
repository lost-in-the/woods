# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    minimum_coverage 88
  end
end

require 'rspec'
require 'active_support/core_ext/string/inflections'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'
require 'woods/update_check'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include ThreadHelpers

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed

  # Perf-tagged specs (see spec/performance/) are wall-clock regression
  # guards — measurably jittery on shared CI runners. Excluded from the
  # default suite; opt in with `rspec --tag perf` from a dedicated job
  # against a predictable box.
  config.filter_run_excluding(perf: true) unless ENV['WOODS_RUN_PERF_SPECS']

  # Booted-app specs (spec/integration/booted_extraction_spec.rb) boot a real
  # Rails app in-process and require full Rails (activerecord + actionpack),
  # which the default unit Gemfile doesn't bundle. Excluded from the default
  # suite; the CI Rails-version matrix opts in via WOODS_RUN_BOOTED_APP using
  # the per-version gemfiles under gemfiles/.
  config.filter_run_excluding(booted_app: true) unless ENV['WOODS_RUN_BOOTED_APP']

  # Live-backend specs (spec/integration/live_backends_spec.rb) talk to a real
  # PostgreSQL+pgvector and a real Qdrant over the network. Every other storage
  # spec drives the adapters through doubles, which is how #181 (a PG-only
  # CardinalityViolation on duplicate batch ids) reached a release. Excluded
  # from the default suite; the CI `live-backends` job opts in via
  # WOODS_RUN_LIVE_BACKENDS with service containers and gemfiles/live_backends.gemfile.
  config.filter_run_excluding(live_backends: true) unless ENV['WOODS_RUN_LIVE_BACKENDS']

  # HTTP end-to-end specs boot `exe/woods-mcp-http` as a real subprocess and
  # bind a port, so they need a Rack handler bundled and a free port. Excluded
  # from the default suite; opt in with WOODS_RUN_HTTP_SERVER=1.
  config.filter_run_excluding(http_server: true) unless ENV['WOODS_RUN_HTTP_SERVER']

  config.after(:each) do
    Woods::ModelNameCache.reset! if defined?(Woods::ModelNameCache) && Woods::ModelNameCache.respond_to?(:reset!)
  end

  # Keep the RubyGems update check hermetic and deterministic across the suite:
  # never touch the network, and isolate the cache to a per-process tmp file so
  # an incidental `build_status`/`woods_status` call can't hit rubygems.org or
  # read a developer's real ~/.cache. Specs that exercise the update path inject
  # their own fetcher/cache_path or override these stubs.
  config.before do
    cache = File.join(Dir.tmpdir, "woods-update-check-test-#{Process.pid}.json")
    FileUtils.rm_f(cache)
    allow(Woods::UpdateCheck).to receive(:default_cache_path).and_return(cache)
    allow(Woods::UpdateCheck).to receive(:fetch_latest_version).and_return(nil)
  end
end
