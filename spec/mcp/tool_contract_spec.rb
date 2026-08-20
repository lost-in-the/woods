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
  let(:contract_oracle) do
    {
      'codebase_retrieve' => contract(:always, { 'query' => 'How does Post work?' }, ['Post'],
                                      integers: %w[budget], strings: %w[query], arrays: %w[types exclude_types]),
      'dependencies' => contract(:always, { 'identifier' => 'Comment' }, %w[Comment Post],
                                 integers: %w[depth], strings: %w[identifier], arrays: %w[types], unions: %w[via]),
      'dependents' => contract(:always, { 'identifier' => 'Post' }, %w[Post Comment],
                               integers: %w[depth], strings: %w[identifier], arrays: %w[types], unions: %w[via]),
      'domain_clusters' => contract(:always, {}, ['clusters'], integers: %w[min_size], arrays: %w[types]),
      'framework' => contract(:always, { 'keyword' => 'ActiveRecord' }, ['ActiveRecord'],
                              integers: %w[limit], strings: %w[keyword]),
      'graph_analysis' => contract(:always, { 'analysis' => 'orphans' }, %w[orphans PostsController],
                                   integers: %w[limit offset], enums: %w[analysis]),
      'list_snapshots' => contract(:snapshot, {}, %w[aaa111 snapshot_count],
                                   integers: %w[limit], strings: %w[branch]),
      'lookup' => contract(:always, { 'identifier' => 'Post' }, %w[Post model],
                           strings: %w[identifier name], arrays: %w[sections]),
      'notion_sync' => contract(:notion, {}, %w[synced data_models]),
      'pagerank' => contract(:always, {}, %w[Post total_nodes], integers: %w[limit], arrays: %w[types]),
      'pipeline_diagnose' => contract(:operator, { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
                                      %w[transient retryable], strings: %w[error_class error_message]),
      'pipeline_embed' => contract(:operator, {}, %w[started Embedding]),
      'pipeline_extract' => contract(:operator, {}, %w[started Extraction], arrays: %w[changed_files]),
      'pipeline_repair' => contract(:operator, { 'action' => 'reset_cooldowns' }, %w[repaired reset_cooldowns],
                                    enums: %w[action]),
      'pipeline_status' => contract(:operator, {}, %w[status ok]),
      'recent_changes' => contract(:always, {}, %w[result_count Post], integers: %w[limit], arrays: %w[types]),
      'reload' => contract(:always, {}, %w[reloaded true]),
      'retrieval_explain' => contract(:feedback, {}, %w[total_ratings average_score]),
      'retrieval_rate' => contract(:feedback, { 'query' => 'Post', 'score' => 4 }, %w[recorded rating],
                                   integers: %w[score], strings: %w[query comment]),
      'retrieval_report_gap' => contract(:feedback,
                                         { 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model' },
                                         %w[recorded gap], strings: %w[query missing_unit unit_type]),
      'retrieval_suggest' => contract(:feedback, {}, %w[issues_found missing_unit]),
      'search' => contract(
        :always, { 'query' => 'Post' }, %w[Post match_field],
        integers: %w[limit], strings: %w[query exact_prefix exact_suffix], arrays: %w[types fields]
      ),
      'session_trace' => contract(:session, { 'session_id' => 'session-1' }, ['Session session-1'],
                                  integers: %w[budget depth], strings: %w[session_id]),
      'snapshot_detail' => contract(:snapshot, { 'git_sha' => 'aaa111' }, %w[aaa111 main], strings: %w[git_sha]),
      'snapshot_diff' => contract(:snapshot, { 'sha_a' => 'aaa111', 'sha_b' => 'bbb222' }, %w[aaa111 bbb222 Post],
                                  strings: %w[sha_a sha_b]),
      'structure' => contract(:always, {}, %w[manifest rails_version], enums: %w[detail]),
      'trace_flow' => contract(:always, { 'entry_point' => 'PostsController#create' },
                               %w[PostsController app/controllers/posts_controller.rb],
                               integers: %w[depth], strings: %w[entry_point]),
      'unit_history' => contract(:snapshot, { 'identifier' => 'Post' }, %w[Post versions],
                                 integers: %w[limit], strings: %w[identifier]),
      'woods_status' => contract(:always, {}, %w[ready index])
    }
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
  let(:valid_arguments) { contract_oracle.transform_values { |entry| entry.fetch(:arguments) } }
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
  let(:notion_exporter) { double(sync_all: { data_models: 2, columns: 4, errors: [] }) }
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
      .and_return(notion_exporter)
  end

  def contract(registration, arguments, facts, integers: [], strings: [], arrays: [], unions: [], enums: [])
    {
      registration: registration,
      arguments: arguments,
      facts: facts,
      integers: integers,
      strings: strings,
      arrays: arrays,
      unions: unions,
      enums: enums
    }
  end

  def inventory_rows
    JSON.parse(File.read(inventory_path)).dig('index_mcp', 'tools')
  end

  def assert_semantic_facts(name, contract, text)
    contract.fetch(:facts).each { |fact| expect(text).to include(fact), "#{name}: #{fact}" }
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

  it 'keeps code-derived inventory as a separate drift input to the independent oracle' do
    expect(inventory_rows.size).to eq(29)
    expect(inventory_rows.map { |row| row.fetch('name') }).to contain_exactly(*contract_oracle.keys)
    expect(listed_tools(full_server).map { |tool| tool.fetch('name') })
      .to contain_exactly(*contract_oracle.keys)
  end

  it 'proves exact semantic facts and schema-valid success for every explicit tool contract' do
    schemas = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool['outputSchema']] }

    aggregate_failures do
      contract_oracle.each do |name, contract|
        result = call_tool(full_server, name, contract.fetch(:arguments)).fetch('result')
        wait_for_pipeline(name)
        text = result.dig('content', 0, 'text')

        expect(result['isError']).to be(false), name
        assert_semantic_facts(name, contract, text)
        expect(result.dig('structuredContent', 'text')).to eq(text), name
        schema = schemas.fetch(name)
        next unless schema

        expect do
          MCP::Tool::OutputSchema.new(schema).validate_result(result.fetch('structuredContent'))
        end.not_to raise_error, name
      end
    end
  end

  it 'rejects a generic ok payload in the semantic harness' do
    expect { assert_semantic_facts('lookup', contract_oracle.fetch('lookup'), '{"ok":true}') }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /lookup: Post/)
  end

  it 'proves the explicit side effects for mutating and collaborator-backed tools' do
    %w[pipeline_extract pipeline_embed retrieval_rate retrieval_report_gap notion_sync
       list_snapshots snapshot_diff unit_history snapshot_detail].each do |name|
      call_tool(full_server, name, contract_oracle.fetch(name).fetch(:arguments))
      wait_for_pipeline(name)
    end

    expect(pipeline_guard).to have_received(:record!).with(:extraction)
    expect(pipeline_guard).to have_received(:record!).with(:embedding)
    expect(feedback_store).to have_received(:record_rating).with(query: 'Post', score: 4, comment: nil)
    expect(feedback_store).to have_received(:record_gap).with(query: 'Post', missing_unit: 'Post', unit_type: 'model')
    expect(notion_exporter).to have_received(:sync_all)
    expect(snapshot_store).to have_received(:list).with(limit: 20, branch: nil)
    expect(snapshot_store).to have_received(:diff).with('aaa111', 'bbb222')
    expect(snapshot_store).to have_received(:unit_history).with('Post', limit: 20)
    expect(snapshot_store).to have_received(:find).with('aaa111')
  end

  it 'registers only always-on rows when collaborators are unavailable' do
    lean_config = Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(lean_config)
    lean = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)
    expected = contract_oracle.filter_map { |name, contract| name if contract.fetch(:registration) == :always }

    expect(listed_tools(lean).map { |tool| tool.fetch('name') }).to contain_exactly(*expected)
  end

  it 'returns stable unavailability errors for every collaborator-gated row' do
    lean_config = Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(lean_config)
    lean = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)
    unavailable = contract_oracle.reject { |_name, contract| contract.fetch(:registration) == :always }

    aggregate_failures do
      unavailable.each_key do |name|
        response = call_tool(lean, name, {})
        expect(response.dig('error', 'code')).to eq(-32_602), name
        expect(response.dig('error', 'data')).to include(name), name
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
      contract_oracle.each_key do |name|
        response = call_tool(full_server, name, [])
        expect(response['error']).to be_nil, name
        expect(response.dig('result', 'isError')).to be(true), name
        expect(response.dig('result', '_meta', 'error_code')).to eq('invalid_arguments'), name
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
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:integers).each do |name|
          schema = tools.fetch(tool_name).dig('inputSchema', 'properties', name)

          [schema.fetch('minimum'), schema.fetch('maximum')].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(false), label
          end

          [schema.fetch('minimum') - 1, schema.fetch('maximum') + 1].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(true), label
            expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), label
          end
        end
      end
    end
  end

  it 'declares and executes every documented string-or-array union' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }
    expected_union = [{ 'type' => 'string', 'maxLength' => 10_000 },
                      { 'type' => 'array', 'items' => { 'type' => 'string', 'maxLength' => 10_000 },
                        'maxItems' => 1_000 }]

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:unions).each do |name|
          expect(tools.fetch(tool_name).dig('inputSchema', 'properties', name, 'anyOf')).to eq(expected_union)
          string_result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => 'code_reference')
          )
          array_result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => ['code_reference'])
          )
          expect(string_result.dig('result', 'isError')).to be(false), "#{tool_name}.#{name} string"
          expect(array_result.dig('result', 'isError')).to be(false), "#{tool_name}.#{name} array"
          expect(string_result.dig('result', 'structuredContent', 'data'))
            .to eq(array_result.dig('result', 'structuredContent', 'data'))
        end
      end
    end
  end

  it 'bounds every explicitly enumerated string and array argument' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        properties = tools.fetch(tool_name).dig('inputSchema', 'properties')
        contract.fetch(:strings).each do |name|
          expect(properties.dig(name, 'maxLength')).to eq(10_000), "#{tool_name}.#{name}"
        end
        contract.fetch(:arrays).each do |name|
          expect(properties.dig(name, 'maxItems')).to eq(1_000), "#{tool_name}.#{name}"
          expect(properties.dig(name, 'items', 'maxLength')).to eq(10_000), "#{tool_name}.#{name} items"
        end
      end
    end
  end

  it 'accepts exact string/array maxima and rejects the adjacent overflow for every oracle entry' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        input = MCP::Tool::InputSchema.new(tools.fetch(tool_name).fetch('inputSchema'))
        contract.fetch(:strings).each do |name|
          valid = contract.fetch(:arguments).merge(name => 'x' * 10_000)
          invalid = contract.fetch(:arguments).merge(name => 'x' * 10_001)
          expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=10000"
          expect { input.validate_arguments(invalid) }
            .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=10001"
        end
        contract.fetch(:arrays).each do |name|
          valid = contract.fetch(:arguments).merge(name => Array.new(1_000, 'x'))
          too_many = contract.fetch(:arguments).merge(name => Array.new(1_001, 'x'))
          long_item = contract.fetch(:arguments).merge(name => ['x' * 10_001])
          expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=1000"
          expect { input.validate_arguments(too_many) }
            .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=1001"
          expect { input.validate_arguments(long_item) }
            .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name} item=10001"
        end
      end
    end
  end

  it 'accepts and rejects every explicitly enumerated value set' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        input = MCP::Tool::InputSchema.new(tools.fetch(tool_name).fetch('inputSchema'))
        contract.fetch(:enums).each do |name|
          schema = tools.fetch(tool_name).dig('inputSchema', 'properties', name)
          schema.fetch('enum').each do |value|
            expect { input.validate_arguments(contract.fetch(:arguments).merge(name => value)) }
              .not_to raise_error, "#{tool_name}.#{name}=#{value}"
          end
          expect { input.validate_arguments(contract.fetch(:arguments).merge(name => '__invalid__')) }
            .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=invalid"
        end
      end
    end
  end

  it 'has an explicit oracle entry for every declared integer, string, array, and union' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        contract = contract_oracle.fetch(tool.fetch('name'))
        tool.dig('inputSchema', 'properties').to_h.each do |name, schema|
          expected = if schema['enum']
                       contract.fetch(:enums)
                     else
                       case schema['type']
                       when 'integer' then contract.fetch(:integers)
                       when 'string' then contract.fetch(:strings)
                       when 'array' then contract.fetch(:arrays)
                       else contract.fetch(:unions) if schema['anyOf']
                       end
                     end
          expect(expected).to include(name), "#{tool.fetch('name')}.#{name}" if expected
        end
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
