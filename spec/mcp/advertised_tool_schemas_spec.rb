# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/coordination/pipeline_lock'
require 'woods/feedback/store'
require 'woods/mcp/server'
require 'woods/operator/error_escalator'
require 'woods/operator/pipeline_guard'
require 'woods/operator/status_reporter'
require 'woods/console/server'

# Every Woods MCP server mode serializes its tools through `tools/list`. Some
# MCP clients reject or mishandle a tool whose input schema has a combinator
# (`oneOf`, `anyOf`, `allOf`) at its root, so no mode may advertise one.
# Combinators nested inside a property are allowed.
RSpec.describe 'Advertised tool input schemas across every Woods MCP server mode' do
  let(:top_level_combinators) { %w[oneOf anyOf allOf] }
  let(:source_fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:runtime_root) { Dir.mktmpdir('woods-advertised-schemas') }
  let(:fixture_dir) { File.join(runtime_root, 'woods') }
  let(:operator) do
    {
      status_reporter: Woods::Operator::StatusReporter.new(output_dir: fixture_dir),
      error_escalator: Woods::Operator::ErrorEscalator.new,
      pipeline_guard: Woods::Operator::PipelineGuard.new(state_dir: File.join(runtime_root, 'operator'),
                                                         cooldown: 300),
      pipeline_lock: Woods::Coordination::PipelineLock.new(
        lock_dir: File.join(runtime_root, 'operator'), name: 'extraction', stale_timeout: 60
      )
    }
  end
  let(:feedback_store) { Woods::Feedback::Store.new(path: File.join(runtime_root, 'feedback.jsonl')) }
  let(:snapshot_store) { double('snapshot store', list: [], diff: {}, unit_history: [], find: nil) }
  let(:retriever) { double('retriever', retrieve: nil) }
  let(:session_and_notion_config) do
    Woods::Configuration.new.tap do |value|
      value.session_store = Class.new do
        def read(*) = nil
        def sessions = []
      end.new
      value.notion_api_token = 'test-token'
      value.notion_database_ids = { data_models: 'test-database' }
    end
  end
  let(:console_validator) { Woods::Console::ModelValidator.new(registry: { 'Post' => %w[id title] }) }
  let(:console_connection) { double('Connection', adapter_name: 'SQLite', execute: nil) }
  let(:console_safe_context) { Woods::Console::SafeContext.new(connection: console_connection) }

  before do
    FileUtils.cp_r(source_fixture_dir, fixture_dir)
    allow(console_connection).to receive(:transaction) { |&block| block.call }
  end

  after { FileUtils.rm_rf(runtime_root) }

  def listed_tools(server)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list', params: {}))
    JSON.parse(raw).dig('result', 'tools')
  end

  def index_server(config: Woods::Configuration.new, **collaborators)
    allow(Woods).to receive(:configuration).and_return(config)
    Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false, **collaborators)
  end

  def console_server(read_tools_enabled:)
    Woods::Console::Server.build_embedded(
      model_validator: console_validator, safe_context: console_safe_context,
      connection: console_connection, read_tools_enabled: read_tools_enabled
    )
  end

  # Mode name => listed tools. Built lazily inside the example so each index
  # mode sees its own stubbed configuration.
  def tools_by_mode
    {
      'index: packaged default (no collaborators)' => listed_tools(index_server),
      'index: operator, feedback, snapshot and retriever wired' => listed_tools(
        index_server(operator: operator, feedback_store: feedback_store, snapshot_store: snapshot_store,
                     retriever: retriever)
      ),
      'index: session tracer and Notion wired' => listed_tools(index_server(config: session_and_notion_config)),
      'console: embedded' => listed_tools(console_server(read_tools_enabled: false)),
      'console: embedded with read tools' => listed_tools(console_server(read_tools_enabled: true))
    }
  end

  it 'advertises no top-level oneOf, anyOf or allOf in any mode' do
    modes = tools_by_mode

    aggregate_failures do
      modes.each do |mode, tools|
        expect(tools).not_to be_empty, mode
        tools.each do |tool|
          offending = tool.fetch('inputSchema').keys & top_level_combinators
          expect(offending).to be_empty, "#{mode}: #{tool.fetch('name')} advertises top-level #{offending}"
        end
      end
    end
  end

  it 'covers every registrable tool of both servers' do
    modes = tools_by_mode
    index_names = modes.select { |mode, _| mode.start_with?('index') }.values.flatten.map { |t| t['name'] }.uniq
    console_names = modes.select { |mode, _| mode.start_with?('console') }.values.flatten.map { |t| t['name'] }.uniq

    # 32 index tools: 16 always-on plus 16 wiring-conditional.
    expect(index_names.size).to eq(32)
    executable = Woods::Console::Server::EXECUTABLE_MODES.values.flatten.uniq
    expect(console_names).to match_array(executable)
  end

  it 'still advertises the find and aggregate properties and states their rules in the description' do
    tools = tools_by_mode.fetch('console: embedded').to_h { |tool| [tool.fetch('name'), tool] }

    find = tools.fetch('console_find')
    expect(find.dig('inputSchema', 'properties').keys).to include('id', 'by')
    expect(find.fetch('description')).to include('exactly one of id or by', 'never both')

    aggregate = tools.fetch('console_aggregate')
    expect(aggregate.dig('inputSchema', 'required')).to eq(%w[model function])
    expect(aggregate.fetch('description'))
      .to include('column is required for sum, average, minimum and maximum')
  end
end
