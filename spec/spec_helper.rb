# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'

    # Track every lib file, not just ones a spec happens to require, so a
    # file with zero specs shows up as 0% instead of being omitted from the
    # report entirely.
    track_files 'lib/**/*.rb'
    enable_coverage :branch

    add_group 'Extraction', 'lib/woods/extractors'
    add_group 'Retrieval', 'lib/woods/retrieval'
    add_group 'MCP', 'lib/woods/mcp'
    add_group 'Console', 'lib/woods/console'
    add_group 'Storage', 'lib/woods/storage'
    add_group 'Embedding', ['lib/woods/embedding', 'lib/woods/chunking']
    add_group 'Coordination', 'lib/woods/coordination'
    add_group 'AST & Analysis', [
      'lib/woods/ast', 'lib/woods/ruby_analyzer', 'lib/woods/flow_analysis',
      'lib/woods/flow_assembler.rb', 'lib/woods/flow_document.rb', 'lib/woods/flow_precomputer.rb'
    ]
    add_group 'Export', ['lib/woods/export', 'lib/woods/notion', 'lib/woods/obsidian', 'lib/woods/unblocked']
    add_group 'Observability & Resilience', ['lib/woods/observability', 'lib/woods/resilience']
    add_group 'Operator & Feedback', ['lib/woods/operator', 'lib/woods/feedback']
    add_group 'Watch & Temporal', ['lib/woods/watch', 'lib/woods/temporal']
    add_group 'Evaluation', 'lib/woods/evaluation'
    add_group 'Database', 'lib/woods/db'

    # Only gate the exit code in CI (GitHub Actions sets CI=true). Locally,
    # COVERAGE=1 against a single spec file would otherwise fail this floor
    # by construction: track_files above measures the whole lib tree, not
    # just what that one spec happens to touch.
    #
    # Provisional floor, a few points below the observed value so it gates
    # regressions without failing the suite today. Measured line coverage on
    # the default unit suite (COVERAGE=1 bin/rspec) was 90.42% on 2026-08-20;
    # branch coverage was 74.85% (not gated, see above). A later full-run
    # calibration can raise this. See Task 8.
    minimum_coverage line: 85 if ENV['CI']
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

  # Packaged-gem specs install and boot the built artifact in an isolated gem
  # home. Release CI opts in on the Ruby floor and latest lanes.
  config.filter_run_excluding(packaged_gem: true) unless ENV['WOODS_RUN_PACKAGE_SMOKE']

  # Booted-app specs (spec/integration/booted_extraction_spec.rb) boot a real
  # Rails app in-process and require full Rails (activerecord + actionpack),
  # which the default unit Gemfile doesn't bundle. Excluded from the default
  # suite; the CI Rails-version matrix opts in via WOODS_RUN_BOOTED_APP using
  # the per-version gemfiles under gemfiles/.
  config.filter_run_excluding(booted_app: true) unless ENV['WOODS_RUN_BOOTED_APP']

  # Live-backend specs use PostgreSQL+pgvector, Qdrant, and an actual Solid
  # Cache store. Excluded from the default suite; CI opts in through
  # WOODS_RUN_LIVE_BACKENDS with gemfiles/live_backends.gemfile.
  config.filter_run_excluding(live_backends: true) unless ENV['WOODS_RUN_LIVE_BACKENDS']

  # HTTP end-to-end specs boot `exe/woods-mcp-http` as a real subprocess and
  # bind a port, so they need a Rack handler bundled and a free port. Excluded
  # from the default suite; opt in with WOODS_RUN_HTTP_SERVER=1.
  config.filter_run_excluding(http_server: true) unless ENV['WOODS_RUN_HTTP_SERVER']

  # The official Inspector contract requires the pinned Node package and boots
  # both MCP executables. Release validation opts in after `npm ci`.
  config.filter_run_excluding(mcp_inspector: true) unless ENV['WOODS_RUN_MCP_INSPECTOR']

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
