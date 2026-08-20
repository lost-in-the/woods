# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# Regression coverage for the pipeline_extract tool running in a process
# shaped like exe/woods-mcp, which deliberately loads no extraction
# machinery. The tool's background run references Woods::Extractor
# directly; before the lazy require in run_extraction, every invocation in
# a standalone index-server process died with NameError. The in-suite
# operator specs can't see this — by the time they run, other spec files
# have loaded the constant — so this spec drives the tool in a fresh
# subprocess with only the index server's own require set.
RSpec.describe 'pipeline_extract in a standalone index-server process' do
  it 'resolves Woods::Extractor without the host having pre-loaded it' do
    fixture_dir = File.expand_path('../fixtures/woods', __dir__)

    script = <<~RUBY
      require 'fileutils'
      require 'logger'
      require 'tmpdir'
      require 'woods'
      require 'woods/mcp/server'
      require 'woods/operator/pipeline_guard'
      require 'woods/operator/status_reporter'

      abort 'precondition failed: Woods::Extractor already loaded' if defined?(Woods::Extractor)

      state_dir = Dir.mktmpdir
      Woods.configuration.output_dir = state_dir
      server = Woods::MCP::Server.build(
        index_dir: ARGV[0],
        operator: {
          pipeline_guard: Woods::Operator::PipelineGuard.new(state_dir: state_dir, cooldown: 60),
          status_reporter: Woods::Operator::StatusReporter.new(output_dir: ARGV[0])
        }
      )
      tool = server.instance_variable_get(:@tools).fetch('pipeline_extract')
      response = tool.call(server_context: {})
      (Thread.list - [Thread.main]).each do |thread|
        abort 'background pipeline thread did not finish' unless thread.join(10)
      end
      puts response.content.first[:text]
      FileUtils.remove_entry(state_dir)
    RUBY

    lib = File.expand_path('../../lib', __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', script, fixture_dir)

    expect(status).to be_success, "subprocess failed:\nstdout: #{stdout}\nstderr: #{stderr}"
    expect(stdout).to include('started')
    # The background extraction still fails in this subprocess (there is no
    # booted Rails app — Ruby reports that lookup as
    # Woods::Extractor::Rails), but it must get far enough to have loaded
    # the extractor — the failure this spec pins is Woods::Extractor itself
    # never resolving, which the (?!:) guard distinguishes from failures
    # *inside* a successfully loaded extractor.
    expect(stderr).not_to match(/uninitialized constant Woods::Extractor(?!:)/)
  end
end
