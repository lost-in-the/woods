# frozen_string_literal: true

# SimpleCov settings shared by spec_helper and the collate step of
# script/parallel-rspec. When the suite runs as parallel processes
# (TEST_ENV_NUMBER set), each process stores its own named resultset and skips
# the report and the floor: whichever process exits first would otherwise judge
# a partial union of the others. The collate step reports and gates once.
module SimpleCovProfile
  CONFIG = proc do
    shard = ENV.fetch('TEST_ENV_NUMBER', '')
    shard = nil if shard.empty?
    coverage_dir ENV.fetch('WOODS_COVERAGE_DIR') if ENV.key?('WOODS_COVERAGE_DIR')
    if shard
      command_name "rspec-#{shard}"
      # Storing the result is what at_exit's default does before formatting it.
      SimpleCov.at_exit { SimpleCov.result }
    end

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
    # Calibrated on 2026-09-18: current local/CI default-suite line coverage
    # is 92.56–92.79%. A 90% floor leaves room for supported-runtime variance
    # while tightening the former provisional 85% gate. Branch coverage is
    # measured, not gated: current CI spans 79.99–80.15%, and opt-in lanes
    # are not yet collated. See the release verification record and #231.
    minimum_coverage line: 90 if ENV['CI'] && !shard
  end
end
