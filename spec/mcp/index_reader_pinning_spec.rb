# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require 'woods/coordination/pipeline_lock'
require 'woods/feedback/store'
require 'woods/operator/error_escalator'
require 'woods/operator/pipeline_guard'
require 'woods/operator/status_reporter'

RSpec.describe Woods::MCP::IndexReaderPinning do
  # A server with every optional collaborator wired registers all 29 tools
  # (see Woods::MCP::Server#build) — the full set pin coverage must account
  # for. Building it once per example, the same way spec/mcp/tool_contract_spec.rb
  # does, rather than the 14-tool default `spec/mcp/server_spec.rb` uses.
  let(:runtime_root) { Dir.mktmpdir('woods-pinning-spec') }
  let(:fixture_dir) { File.join(runtime_root, 'woods') }
  let(:config) do
    Woods::Configuration.new.tap do |value|
      value.session_store = Class.new do
        def read(*) = nil
        def sessions = []
      end.new
      value.notion_api_token = 'test-token'
      value.notion_database_ids = { data_models: 'test-database' }
    end
  end
  let(:operator) do
    {
      status_reporter: Woods::Operator::StatusReporter.new(output_dir: fixture_dir),
      error_escalator: Woods::Operator::ErrorEscalator.new,
      pipeline_guard: Woods::Operator::PipelineGuard.new(state_dir: File.join(runtime_root, 'operator')),
      pipeline_lock: Woods::Coordination::PipelineLock.new(
        lock_dir: File.join(runtime_root, 'operator'), name: 'extraction'
      )
    }
  end
  let(:feedback_store) { Woods::Feedback::Store.new(path: File.join(runtime_root, 'feedback.jsonl')) }
  let(:snapshot_store) { double('snapshot store') }
  let(:retriever) { double('retriever') }

  let(:full_server) do
    allow(Woods).to receive(:configuration).and_return(config)
    Woods::MCP::Server.build(
      index_dir: fixture_dir,
      retriever: retriever,
      operator: operator,
      feedback_store: feedback_store,
      snapshot_store: snapshot_store,
      response_format: :json,
      warmup: false
    )
  end

  before { FileUtils.cp_r(File.expand_path('../fixtures/woods', __dir__), fixture_dir) }
  after { FileUtils.rm_rf(runtime_root) }

  def pinned_names(server)
    server.instance_variable_get(:@woods_index_reader_tool_names)
  end

  it 'registers all 29 tools when fully wired' do
    expect(full_server.tools.keys.size).to eq(29)
  end

  it 'leaves reload as the sole non-reader exception' do
    expect(described_class::NON_READER_TOOL_NAMES).to eq(Set.new(%w[reload]))
  end

  it 'pins every registered tool except the documented exceptions' do
    server = full_server

    expect(pinned_names(server)).to eq(server.tools.keys.to_set - described_class::NON_READER_TOOL_NAMES)
  end

  it 'accounts for every registered tool between the pin set and the exception list' do
    server = full_server

    expect(pinned_names(server) | described_class::NON_READER_TOOL_NAMES).to eq(server.tools.keys.to_set)
  end

  it 'pins the retrieval, pipeline, snapshot, and feedback tools the old static allowlist left uncovered' do
    server = full_server

    %w[
      codebase_retrieve
      pipeline_extract pipeline_embed pipeline_status pipeline_diagnose pipeline_repair
      list_snapshots snapshot_diff unit_history snapshot_detail
      retrieval_rate retrieval_report_gap retrieval_explain retrieval_suggest
    ].each { |tool_name| expect(pinned_names(server)).to include(tool_name) }
  end

  it 'excludes reload from the pin set' do
    expect(pinned_names(full_server)).not_to include('reload')
  end

  # Regression guard for the coverage mechanism itself: a tool the installer
  # has never enumerated by name must still land in the pinned set, because
  # coverage is derived from the server's actual `tools` registry rather
  # than a hand-maintained list. A future revert to a static allowlist would
  # leave this tool out of BOTH the pin set and the exception list, which is
  # exactly the silent-skip #{Woods::MCP::Server} shipped with for 14/28
  # tools before this fix.
  it 'pins a tool the exception list has never heard of, rather than silently skipping it' do
    server = full_server
    server.tools['a_future_tool_nobody_classified_yet'] = double('future tool')

    described_class.install(server, reader: server.instance_variable_get(:@woods_index_reader))

    expect(pinned_names(server)).to include('a_future_tool_nobody_classified_yet')
  end
end
