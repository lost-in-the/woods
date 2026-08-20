# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'
require 'timeout'
require 'woods'
require 'woods/dependency_graph'
require 'woods/feedback/gap_detector'
require 'woods/mcp/server'
require 'woods/notion/exporter'
require 'woods/session_tracer/session_flow_assembler'

RSpec.describe 'Index MCP tool contracts' do
  let(:expected_tools) do
    %w[
      codebase_retrieve dependencies dependents domain_clusters framework graph_analysis
      list_snapshots lookup notion_sync pagerank pipeline_diagnose pipeline_embed pipeline_extract
      pipeline_repair pipeline_status recent_changes reload retrieval_explain retrieval_rate
      retrieval_report_gap retrieval_suggest search session_trace snapshot_detail snapshot_diff
      structure trace_flow unit_history woods_status
    ]
  end
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:inventory_path) { File.expand_path('../../.Codex/release-v2/surface-inventory.json', __dir__) }
  let(:tool_contract_meta) do
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'tool-contract-spec', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
  end
  let(:valid_arguments) do
    {
      'codebase_retrieve' => { 'query' => 'How does Post work?' },
      'dependencies' => { 'identifier' => 'Comment' },
      'dependents' => { 'identifier' => 'Post' },
      'domain_clusters' => {},
      'framework' => { 'keyword' => 'ActiveRecord' },
      'graph_analysis' => { 'analysis' => 'orphans' },
      'list_snapshots' => {},
      'lookup' => { 'identifier' => 'Post' },
      'notion_sync' => {},
      'pagerank' => {},
      'pipeline_diagnose' => { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
      'pipeline_embed' => {},
      'pipeline_extract' => {},
      'pipeline_repair' => { 'action' => 'reset_cooldowns' },
      'pipeline_status' => {},
      'recent_changes' => {},
      'reload' => {},
      'retrieval_explain' => {},
      'retrieval_rate' => { 'query' => 'Post', 'score' => 4 },
      'retrieval_report_gap' => { 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model' },
      'retrieval_suggest' => {},
      'search' => { 'query' => 'Post' },
      'session_trace' => { 'session_id' => 'session-1' },
      'snapshot_detail' => { 'git_sha' => 'aaa111' },
      'snapshot_diff' => { 'sha_a' => 'aaa111', 'sha_b' => 'bbb222' },
      'structure' => {},
      'trace_flow' => { 'entry_point' => 'PostsController#create' },
      'unit_history' => { 'identifier' => 'Post' },
      'woods_status' => {}
    }
  end
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
  let(:retriever) do
    double('retriever', retrieve: Struct.new(:context).new("## Post\nclass Post; end"))
  end
  let(:pipeline_guard) { double('pipeline guard', allow?: true, record!: nil) }
  let(:operator) do
    {
      status_reporter: double('status reporter', report: { status: 'ok', total_units: 5 }),
      error_escalator: double('error escalator', classify: { category: 'transient', retryable: true }),
      pipeline_guard: pipeline_guard,
      pipeline_lock: double('pipeline lock', release: nil)
    }
  end
  let(:feedback_store) do
    double(
      'feedback store',
      record_rating: nil,
      record_gap: nil,
      ratings: [{ 'query' => 'Post', 'score' => 4 }],
      gaps: [],
      average_score: 4.0
    )
  end
  let(:snapshot_store) do
    double(
      'snapshot store',
      list: [{ git_sha: 'aaa111', branch: 'main' }],
      diff: { added: ['Post'], modified: [], deleted: [] },
      unit_history: [{ git_sha: 'aaa111', identifier: 'Post' }],
      find: { git_sha: 'aaa111', branch: 'main' }
    )
  end
  let(:full_server) do
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

  before do
    allow(Woods).to receive(:configuration).and_return(config)
    allow(config).to receive(:output_dir).and_return(nil)
    stub_const('Woods::Extractor', double('extractor class', new: double(extract_all: nil, extract_changed: nil)))
    allow(Woods::Tasks).to receive(:build_embed_indexer)
      .and_return(double(index_all: nil, index_incremental: nil))
    allow(Woods::SessionTracer::SessionFlowAssembler).to receive(:new)
      .and_return(double(assemble: double(to_markdown: "## Session session-1\n1 request")))
    allow(Woods::Feedback::GapDetector).to receive(:new)
      .and_return(double(detect: [{ kind: 'missing_unit', count: 1 }]))
    allow(Woods::Notion::Exporter).to receive(:new)
      .and_return(double(sync_all: { data_models: 2, columns: 4, errors: [] }))
  end

  def inventory_rows
    JSON.parse(File.read(inventory_path)).dig('index_mcp', 'tools')
  end

  def rpc(server, method, params = {})
    params = params.merge('_meta' => tool_contract_meta) unless method == 'server/discover'
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params))
    JSON.parse(raw)
  end

  def listed_tools(server)
    rpc(server, 'tools/list').dig('result', 'tools')
  end

  def call_tool(server, name, arguments)
    rpc(server, 'tools/call', 'name' => name, 'arguments' => arguments)
  end

  def required_arguments(tool)
    Array(tool.dig('inputSchema', 'required')).to_h do |name|
      schema = tool.dig('inputSchema', 'properties', name)
      value = if schema['enum']
                schema.fetch('enum').first
              elsif schema['type'] == 'integer'
                schema.fetch('minimum')
              else
                'valid'
              end
      [name, value]
    end
  end

  def wait_for_pipeline(tool_name)
    kind = { 'pipeline_extract' => :extraction, 'pipeline_embed' => :embedding }[tool_name]
    return unless kind

    Timeout.timeout(2) do
      in_flight = Woods::MCP::Server.instance_variable_get(:@pipeline_in_flight)
      sleep 0.005 while in_flight[kind]
    end
  end

  def wrong_value(schema)
    return false if schema['anyOf']

    {
      'array' => {},
      'boolean' => 'true',
      'integer' => 'one',
      'string' => false
    }.fetch(schema.fetch('type'))
  end

  it 'derives exactly 29 tool rows from the release surface inventory' do
    expect(inventory_rows.size).to eq(29)
    expect(inventory_rows.map { |row| row.fetch('name') }).to contain_exactly(*expected_tools)
    expect(valid_arguments.keys).to contain_exactly(*inventory_rows.map { |row| row.fetch('name') })
    expect(listed_tools(full_server).map { |tool| tool.fetch('name') })
      .to contain_exactly(*expected_tools)
  end

  it 'returns a non-vacuous schema-valid success for every inventory row' do
    schemas = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool['outputSchema']] }

    aggregate_failures do
      valid_arguments.each do |name, arguments|
        result = call_tool(full_server, name, arguments).fetch('result')
        wait_for_pipeline(name)
        text = result.dig('content', 0, 'text')

        expect(result['isError']).to be(false), name
        expect(text).to be_a(String), name
        expect(text).not_to be_empty, name
        expect(result.dig('structuredContent', 'text')).to eq(text), name
        schema = schemas.fetch(name)
        next unless schema

        expect do
          MCP::Tool::OutputSchema.new(schema).validate_result(result.fetch('structuredContent'))
        end.not_to raise_error, name
      end
    end
  end

  it 'registers only always-on rows when collaborators are unavailable' do
    lean_config = Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(lean_config)
    lean = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)
    expected = inventory_rows.filter_map do |row|
      row.fetch('name') if row.dig('registration_condition', 'call_site_guard') == 'always registered'
    end

    expect(listed_tools(lean).map { |tool| tool.fetch('name') }).to contain_exactly(*expected)
  end

  it 'returns stable unavailability errors for every collaborator-gated row' do
    lean_config = Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(lean_config)
    lean = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)
    unavailable = inventory_rows.reject do |row|
      row.dig('registration_condition', 'call_site_guard') == 'always registered'
    end

    aggregate_failures do
      unavailable.each do |row|
        response = call_tool(lean, row.fetch('name'), {})
        expect(response.dig('error', 'code')).to eq(-32_602), row.fetch('name')
        expect(response.dig('error', 'data')).to include(row.fetch('name')), row.fetch('name')
      end
    end
  end

  it 'returns stable not-configured metadata for present tools with missing nested collaborators' do
    partial = Woods::MCP::Server.build(
      index_dir: fixture_dir,
      operator: {},
      response_format: :json,
      warmup: false
    )
    calls = {
      'pipeline_status' => {},
      'pipeline_diagnose' => { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
      'pipeline_repair' => { 'action' => 'clear_locks' }
    }

    aggregate_failures do
      calls.each do |name, arguments|
        result = call_tool(partial, name, arguments).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('not_configured'), name
      end
    end
  end

  it 'keeps codebase_retrieve registered with a typed fallback when retrieval is unavailable' do
    unavailable = Woods::MCP::Server.build(
      index_dir: fixture_dir,
      response_format: :json,
      warmup: false
    )
    result = call_tool(unavailable, 'codebase_retrieve', 'query' => 'Post').fetch('result')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('not_configured')
    expect(result.dig('_meta', 'config_key')).to eq('embedding_provider')
  end

  it 'publishes closed input schemas and non-vacuous output schemas for every row' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        input = tool.fetch('inputSchema')

        expect(input['type']).to eq('object'), tool.fetch('name')
        expect(input['additionalProperties']).to be(false), tool.fetch('name')
        if Woods::MCP::ToolContract::TASK_RESULT_TOOLS.include?(tool.fetch('name'))
          expect(tool).not_to have_key('outputSchema')
          next
        end

        output = tool.fetch('outputSchema')
        expect(output).to include(
          'type' => 'object',
          'required' => ['text'],
          'additionalProperties' => false
        ), tool.fetch('name')
        expect(output.dig('properties', 'text')).to eq('type' => 'string'), tool.fetch('name')
      end
    end
  end

  it 'defines inclusive minimum and maximum bounds for every integer argument' do
    integer_properties = listed_tools(full_server).flat_map do |tool|
      tool.dig('inputSchema', 'properties').to_h.filter_map do |name, schema|
        [tool.fetch('name'), name, schema] if schema['type'] == 'integer'
      end
    end

    expect(integer_properties).not_to be_empty
    aggregate_failures do
      integer_properties.each do |tool_name, property, schema|
        expect(schema['minimum']).to be_a(Integer), "#{tool_name}.#{property}"
        expect(schema['maximum']).to be_a(Integer), "#{tool_name}.#{property}"
        expect(schema['maximum']).to be >= schema['minimum'], "#{tool_name}.#{property}"
      end
    end
  end

  it 'rejects unknown arguments for every row with stable tool error metadata' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        arguments = required_arguments(tool).merge('__unknown' => true)
        result = call_tool(full_server, tool.fetch('name'), arguments).fetch('result')
        expect(result['isError']).to be(true), tool.fetch('name')
        expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), tool.fetch('name')
      end
    end
  end

  it 'rejects non-object arguments for every row without an internal error' do
    aggregate_failures do
      inventory_rows.each do |row|
        response = call_tool(full_server, row.fetch('name'), [])
        expect(response['error']).to be_nil, row.fetch('name')
        expect(response.dig('result', 'isError')).to be(true), row.fetch('name')
        expect(response.dig('result', '_meta', 'error_code')).to eq('invalid_arguments'), row.fetch('name')
      end
    end
  end

  it 'rejects every declared argument at the wrong JSON type with stable metadata' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        tool.dig('inputSchema', 'properties').to_h.each do |name, schema|
          arguments = valid_arguments.fetch(tool.fetch('name')).merge(name => wrong_value(schema))
          result = call_tool(full_server, tool.fetch('name'), arguments).fetch('result')

          expect(result['isError']).to be(true), "#{tool.fetch('name')}.#{name}"
          expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool.fetch('name')}.#{name}"
        end
      end
    end
  end

  it 'accepts inclusive integer boundaries and rejects values immediately outside them' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        tool.dig('inputSchema', 'properties').to_h.each do |name, schema|
          next unless schema['type'] == 'integer'

          [schema.fetch('minimum'), schema.fetch('maximum')].each do |value|
            arguments = valid_arguments.fetch(tool.fetch('name')).merge(name => value)
            result = call_tool(full_server, tool.fetch('name'), arguments).fetch('result')
            label = "#{tool.fetch('name')}.#{name}=#{value}"
            expect(result['isError']).to be(false), label
          end

          [schema.fetch('minimum') - 1, schema.fetch('maximum') + 1].each do |value|
            arguments = valid_arguments.fetch(tool.fetch('name')).merge(name => value)
            result = call_tool(full_server, tool.fetch('name'), arguments).fetch('result')
            label = "#{tool.fetch('name')}.#{name}=#{value}"
            expect(result['isError']).to be(true), label
            expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), label
          end
        end
      end
    end
  end

  it 'declares and executes via as the documented string-or-array union' do
    tool = listed_tools(full_server).find { |entry| entry.fetch('name') == 'dependencies' }
    schema = tool.dig('inputSchema', 'properties', 'via')
    expected_union = [{ 'type' => 'string', 'maxLength' => 10_000 },
                      { 'type' => 'array', 'items' => { 'type' => 'string', 'maxLength' => 10_000 },
                        'maxItems' => 1_000 }]

    expect(schema.fetch('anyOf')).to eq(expected_union)

    string_result = call_tool(full_server, 'dependencies', 'identifier' => 'Comment', 'via' => 'code_reference')
    array_result = call_tool(full_server, 'dependencies', 'identifier' => 'Comment', 'via' => ['code_reference'])
    expect(string_result.dig('result', 'isError')).to be(false)
    expect(array_result.dig('result', 'isError')).to be(false)
    expect(string_result.dig('result', 'structuredContent', 'data'))
      .to eq(array_result.dig('result', 'structuredContent', 'data'))
  end

  it 'bounds every declared string and array branch' do
    schemas = listed_tools(full_server).flat_map do |tool|
      tool.dig('inputSchema', 'properties').to_h.values.flat_map { |schema| schema.fetch('anyOf', [schema]) }
    end

    aggregate_failures do
      schemas.each do |schema|
        expect(schema['maxLength']).to eq(10_000) if schema['type'] == 'string'
        next unless schema['type'] == 'array'

        expect(schema['maxItems']).to eq(1_000)
        expect(schema.dig('items', 'maxLength')).to eq(10_000) if schema.dig('items', 'type') == 'string'
      end
    end
  end

  it 'rejects missing schema-required arguments with stable metadata' do
    required = listed_tools(full_server).select { |tool| tool.dig('inputSchema', 'required')&.any? }

    aggregate_failures do
      required.each do |tool|
        result = call_tool(full_server, tool.fetch('name'), {}).fetch('result')
        expect(result['isError']).to be(true), tool.fetch('name')
        expect(result.dig('_meta', 'error_code')).to eq('missing_required_arguments'), tool.fetch('name')
      end
    end
  end

  it 'returns schema-valid structured content alongside text' do
    tool = listed_tools(full_server).find { |entry| entry.fetch('name') == 'woods_status' }
    result = call_tool(full_server, 'woods_status', {}).fetch('result')
    schema = MCP::Tool::OutputSchema.new(tool.fetch('outputSchema'))

    expect(result.dig('structuredContent', 'text')).to eq(result.dig('content', 0, 'text'))
    expect(result.dig('structuredContent', 'data')).to be_a(Hash)
    expect { schema.validate_result(result.fetch('structuredContent')) }.not_to raise_error
  end
end
