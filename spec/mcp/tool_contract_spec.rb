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
                                      required: %w[query], properties: {
                                        'query' => string_contract(1, 10_000),
                                        'budget' => integer_contract(1, 200_000),
                                        'types' => array_contract(1_000, 10_000),
                                        'exclude_types' => array_contract(1_000, 10_000)
                                      }),
      'dependencies' => contract(:always, { 'identifier' => 'Comment' }, %w[Comment Post],
                                 required: %w[identifier], properties: {
                                   'identifier' => string_contract(1, 10_000),
                                   'depth' => integer_contract(0, 20),
                                   'types' => array_contract(1_000, 10_000),
                                   'via' => union_contract
                                 }),
      'dependents' => contract(:always, { 'identifier' => 'Post' }, %w[Post Comment],
                               required: %w[identifier], properties: {
                                 'identifier' => string_contract(1, 10_000),
                                 'depth' => integer_contract(0, 20),
                                 'types' => array_contract(1_000, 10_000),
                                 'via' => union_contract
                               }),
      'domain_clusters' => contract(:always, {}, %w[Billing PaymentService], properties: {
                                      'min_size' => integer_contract(1, 100_000),
                                      'types' => array_contract(1_000, 10_000)
                                    }),
      'framework' => contract(:always, { 'keyword' => 'ActiveRecord' }, ['ActiveRecord'],
                              required: %w[keyword], properties: {
                                'keyword' => string_contract(1, 10_000),
                                'limit' => integer_contract(1, 1_000)
                              }),
      'graph_analysis' => contract(:always, { 'analysis' => 'orphans' }, %w[orphans PostsController],
                                   properties: {
                                     'analysis' => enum_contract(
                                       %w[orphans dead_ends hubs cycles bridges all], nil, 10_000
                                     ),
                                     'limit' => integer_contract(1, 1_000),
                                     'offset' => integer_contract(0, 1_000_000)
                                   }),
      'list_snapshots' => contract(:snapshot, {}, %w[aaa111 snapshot_count], properties: {
                                     'limit' => integer_contract(1, 1_000),
                                     'branch' => string_contract(nil, 10_000)
                                   }),
      'lookup' => contract(:always, { 'identifier' => 'Post' }, %w[Post model],
                           properties: {
                             'identifier' => string_contract(nil, 10_000),
                             'name' => string_contract(nil, 10_000),
                             'include_source' => boolean_contract,
                             'sections' => array_contract(1_000, 10_000)
                           }),
      'notion_sync' => contract(:notion, {}, %w[synced data_models]),
      'pagerank' => contract(:always, {}, %w[Post total_nodes], properties: {
                               'limit' => integer_contract(1, 1_000),
                               'types' => array_contract(1_000, 10_000)
                             }),
      'pipeline_diagnose' => contract(:operator, { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
                                      %w[transient retryable], required: %w[error_class error_message], properties: {
                                        'error_class' => string_contract(1, 10_000),
                                        'error_message' => string_contract(1, 10_000)
                                      }),
      'pipeline_embed' => contract(:operator, {}, %w[started Embedding], properties: {
                                     'incremental' => boolean_contract
                                   }),
      'pipeline_extract' => contract(:operator, {}, %w[started Extraction], properties: {
                                       'incremental' => boolean_contract,
                                       'changed_files' => array_contract(1_000, 10_000)
                                     }),
      'pipeline_repair' => contract(:operator, { 'action' => 'reset_cooldowns' }, %w[repaired reset_cooldowns],
                                    required: %w[action], properties: {
                                      'action' => enum_contract(%w[clear_locks reset_cooldowns], 1, 10_000)
                                    }),
      'pipeline_status' => contract(:operator, {}, %w[status ok]),
      'recent_changes' => contract(:always, {}, %w[result_count Post], properties: {
                                     'limit' => integer_contract(1, 1_000),
                                     'types' => array_contract(1_000, 10_000)
                                   }),
      'reload' => contract(:always, {}, %w[reloaded true total_units 9]),
      'retrieval_explain' => contract(:feedback, {}, %w[total_ratings average_score]),
      'retrieval_rate' => contract(:feedback, { 'query' => 'Post', 'score' => 4 }, %w[recorded rating],
                                   required: %w[query score], properties: {
                                     'query' => string_contract(1, 10_000),
                                     'score' => integer_contract(1, 5),
                                     'comment' => string_contract(nil, 10_000)
                                   }),
      'retrieval_report_gap' => contract(:feedback,
                                         { 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model' },
                                         %w[recorded gap], required: %w[query missing_unit unit_type], properties: {
                                           'query' => string_contract(1, 10_000),
                                           'missing_unit' => string_contract(1, 10_000),
                                           'unit_type' => string_contract(1, 10_000)
                                         }),
      'retrieval_suggest' => contract(:feedback, {}, %w[issues_found missing_unit]),
      'search' => contract(
        :always, { 'query' => 'Post' }, %w[Post match_field],
        properties: {
          'query' => string_contract(nil, 10_000),
          'types' => array_contract(1_000, 10_000),
          'fields' => array_contract(1_000, 10_000),
          'limit' => integer_contract(1, 1_000),
          'exact_prefix' => string_contract(nil, 10_000),
          'exact_suffix' => string_contract(nil, 10_000)
        }
      ),
      'session_trace' => contract(:session, { 'session_id' => 'session-1' }, ['Session session-1'],
                                  required: %w[session_id], properties: {
                                    'session_id' => string_contract(1, 10_000),
                                    'budget' => integer_contract(1, 200_000),
                                    'depth' => integer_contract(0, 20)
                                  }),
      'snapshot_detail' => contract(:snapshot, { 'git_sha' => 'aaa111' }, %w[aaa111 main],
                                    required: %w[git_sha], properties: {
                                      'git_sha' => string_contract(1, 10_000)
                                    }),
      'snapshot_diff' => contract(:snapshot, { 'sha_a' => 'aaa111', 'sha_b' => 'bbb222' }, %w[aaa111 bbb222 Post],
                                  required: %w[sha_a sha_b], properties: {
                                    'sha_a' => string_contract(1, 10_000),
                                    'sha_b' => string_contract(1, 10_000)
                                  }),
      'structure' => contract(:always, {}, %w[manifest rails_version], properties: {
                                'detail' => enum_contract(%w[summary full], nil, 10_000)
                              }),
      'trace_flow' => contract(:always, { 'entry_point' => 'PostsController#create' },
                               %w[PostsController app/controllers/posts_controller.rb],
                               required: %w[entry_point], properties: {
                                 'entry_point' => string_contract(1, 10_000),
                                 'depth' => integer_contract(0, 20)
                               }),
      'unit_history' => contract(:snapshot, { 'identifier' => 'Post' }, %w[Post versions],
                                 required: %w[identifier], properties: {
                                   'identifier' => string_contract(1, 10_000),
                                   'limit' => integer_contract(1, 1_000)
                                 }),
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
  let(:pipeline_lock) { double('pipeline lock', release: nil) }
  let(:operator) do
    {
      status_reporter: double('status reporter', report: { status: 'ok', total_units: 5 }),
      error_escalator: double('error escalator', classify: { category: 'transient', retryable: true }),
      pipeline_guard: pipeline_guard,
      pipeline_lock: pipeline_lock
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
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(
      double(domain_clusters: [{ name: 'Billing', member_count: 2, hub: 'PaymentService' }])
    )
    allow(Woods::Notion::Exporter).to receive(:new)
      .and_return(notion_exporter)
  end

  def contract(registration, arguments, facts, required: [], properties: {})
    {
      registration: registration,
      arguments: arguments,
      facts: facts,
      required: required,
      properties: properties
    }
  end

  def integer_contract(minimum, maximum)
    { 'type' => 'integer', 'minimum' => minimum, 'maximum' => maximum }
  end

  def string_contract(minimum_length, maximum_length)
    { 'type' => 'string', 'minLength' => minimum_length, 'maxLength' => maximum_length }.compact
  end

  def array_contract(maximum_items, maximum_item_length)
    {
      'type' => 'array',
      'items' => { 'type' => 'string', 'maxLength' => maximum_item_length },
      'maxItems' => maximum_items
    }
  end

  def boolean_contract
    { 'type' => 'boolean' }
  end

  def enum_contract(values, minimum_length, maximum_length)
    string_contract(minimum_length, maximum_length).merge('enum' => values)
  end

  def union_contract
    {
      'anyOf' => [
        string_contract(nil, 10_000),
        array_contract(1_000, 10_000)
      ]
    }
  end

  def inventory_rows
    JSON.parse(File.read(inventory_path)).dig('index_mcp', 'tools')
  end

  def assert_semantic_facts(name, contract, text)
    contract.fetch(:facts).each { |fact| expect(text).to include(fact), "#{name}: #{fact}" }
  end

  def assert_boundary_semantics(name, contract, text)
    facts = {
      'dependencies' => %w[root Comment found],
      'dependents' => %w[root Post found],
      'graph_analysis' => %w[stats orphan_count],
      'recent_changes' => %w[result_count identifier]
    }.fetch(name, contract.fetch(:facts))
    facts.each { |fact| expect(text).to include(fact), "#{name} boundary: #{fact}" }
  end

  def assert_enum_semantics(name, value, text)
    facts = case name
            when 'graph_analysis' then value == 'all' ? %w[stats orphans] : [value, 'stats']
            when 'pipeline_repair' then ['repaired', value]
            when 'structure' then %w[manifest rails_version]
            else raise "Missing enum semantic oracle for #{name}.#{value}"
            end
    facts.each { |fact| expect(text).to include(fact), "#{name}=#{value}: #{fact}" }
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

  def projected_schema(schema, expected)
    schema.slice(*expected.keys).tap do |projected|
      projected['anyOf'] = schema['anyOf'] if expected.key?('anyOf')
    end
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
    contract_oracle.each do |name, contract|
      expect { assert_semantic_facts(name, contract, '{"ok":true}') }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError), name
    end
    expect { assert_semantic_facts('domain_clusters', contract_oracle.fetch('domain_clusters'), '{"clusters":[]}') }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /domain_clusters: Billing/)
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
    call_tool(full_server, 'pipeline_repair', 'action' => 'clear_locks')
    expect(pipeline_lock).to have_received(:release)
  end

  it 'exercises each explicit dependency class independently' do
    dependency_servers = {
      always: -> { Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false) },
      operator: -> { Woods::MCP::Server.build(index_dir: fixture_dir, operator: operator, warmup: false) },
      feedback: -> { Woods::MCP::Server.build(index_dir: fixture_dir, feedback_store: feedback_store, warmup: false) },
      snapshot: -> { Woods::MCP::Server.build(index_dir: fixture_dir, snapshot_store: snapshot_store, warmup: false) }
    }

    aggregate_failures do
      dependency_servers.each do |dependency, build|
        allow(Woods).to receive(:configuration).and_return(Woods::Configuration.new)
        expected = contract_oracle.filter_map do |name, entry|
          name if %i[always].include?(entry.fetch(:registration)) || entry.fetch(:registration) == dependency
        end
        expect(listed_tools(build.call).map { |tool| tool.fetch('name') })
          .to contain_exactly(*expected), dependency.to_s
      end

      session_config = Woods::Configuration.new
      session_config.session_store = config.session_store
      allow(Woods).to receive(:configuration).and_return(session_config)
      session = Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false)
      expected_session = contract_oracle.filter_map do |name, entry|
        name if %i[always session].include?(entry.fetch(:registration))
      end
      expect(listed_tools(session).map { |tool| tool.fetch('name') }).to contain_exactly(*expected_session)

      notion_config = Woods::Configuration.new
      notion_config.notion_api_token = 'test-token'
      notion_config.notion_database_ids = { data_models: 'test-database' }
      allow(Woods).to receive(:configuration).and_return(notion_config)
      notion = Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false)
      expected_notion = contract_oracle.filter_map do |name, entry|
        name if %i[always notion].include?(entry.fetch(:registration))
      end
      expect(listed_tools(notion).map { |tool| tool.fetch('name') }).to contain_exactly(*expected_notion)
    end
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

  it 'matches every runtime argument to the fully literal oracle' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        expected = contract_oracle.fetch(tool.fetch('name'))
        schema = tool.fetch('inputSchema')
        expect(schema.fetch('required', [])).to eq(expected.fetch(:required)), tool.fetch('name')
        expect(schema.fetch('properties').keys)
          .to contain_exactly(*expected.fetch(:properties).keys), tool.fetch('name')
        expected.fetch(:properties).each do |name, property|
          expect(projected_schema(schema.fetch('properties').fetch(name), property))
            .to eq(property), "#{tool.fetch('name')}.#{name}"
        end
      end
    end
  end

  it 'rejects unknown arguments for every row with stable tool error metadata' do
    aggregate_failures do
      contract_oracle.each do |name, contract|
        arguments = contract.fetch(:arguments).merge('__unknown' => true)
        result = call_tool(full_server, name, arguments).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), name
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
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          arguments = contract.fetch(:arguments).merge(name => wrong_value(property))
          result = call_tool(full_server, tool_name, arguments).fetch('result')

          expect(result['isError']).to be(true), "#{tool_name}.#{name}"
          expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name}"
        end
      end
    end
  end

  it 'accepts inclusive integer boundaries and rejects values immediately outside them' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['type'] == 'integer'

          [property.fetch('minimum'), property.fetch('maximum')].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(false), label
            assert_boundary_semantics(tool_name, contract, result.dig('content', 0, 'text'))
          end

          [property.fetch('minimum') - 1, property.fetch('maximum') + 1].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(true), label
            expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), label
            expect(result.dig('content', 0, 'text')).to include(name), label
          end
        end
      end
    end
  end

  it 'declares and executes every documented string-or-array union' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['anyOf']

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
          assert_boundary_semantics(tool_name, contract, string_result.dig('result', 'content', 0, 'text'))
          invalid = call_tool(full_server, tool_name, contract.fetch(:arguments).merge(name => false)).fetch('result')
          expect(invalid['isError']).to be(true), "#{tool_name}.#{name} invalid"
          expect(invalid.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name} invalid"
          expect(invalid.dig('content', 0, 'text')).to include(name), "#{tool_name}.#{name} invalid"
        end
      end
    end
  end

  it 'bounds every explicitly enumerated string and array argument' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless %w[string array].include?(property['type'])

          expected = property['type'] == 'string' ? property.fetch('maxLength') : property.fetch('maxItems')
          expect(expected).to be_positive, "#{tool_name}.#{name}"
        end
      end
    end
  end

  it 'accepts exact string/array maxima and rejects the adjacent overflow for every oracle entry' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        input = MCP::Tool::InputSchema.new(tools.fetch(tool_name).fetch('inputSchema'))
        contract.fetch(:properties).each do |name, property|
          case property['type']
          when 'string'
            next if property['enum']

            maximum = property.fetch('maxLength')
            valid = contract.fetch(:arguments).merge(name => 'x' * maximum)
            invalid = contract.fetch(:arguments).merge(name => 'x' * (maximum + 1))
            expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=#{maximum}"
            expect { input.validate_arguments(invalid) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=#{maximum + 1}"
          when 'array'
            maximum = property.fetch('maxItems')
            item_maximum = property.dig('items', 'maxLength')
            valid = contract.fetch(:arguments).merge(name => Array.new(maximum, 'x'))
            too_many = contract.fetch(:arguments).merge(name => Array.new(maximum + 1, 'x'))
            long_item = contract.fetch(:arguments).merge(name => ['x' * (item_maximum + 1)])
            expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=#{maximum}"
            expect { input.validate_arguments(too_many) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=#{maximum + 1}"
            expect { input.validate_arguments(long_item) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name} item=#{item_maximum + 1}"
          end
        end
      end
    end
  end

  it 'accepts and rejects every explicitly enumerated value set' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['enum']

          property.fetch('enum').each do |value|
            result = call_tool(
              full_server, tool_name, contract.fetch(:arguments).merge(name => value)
            ).fetch('result')
            expect(result['isError']).to be(false), "#{tool_name}.#{name}=#{value}"
            assert_enum_semantics(tool_name, value, result.dig('content', 0, 'text'))
          end
          result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => '__invalid__')
          ).fetch('result')
          expect(result['isError']).to be(true), "#{tool_name}.#{name}=invalid"
          expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name}=invalid"
          expect(result.dig('content', 0, 'text')).to include(name), "#{tool_name}.#{name}=invalid"
        end
      end
    end
  end

  it 'rejects missing schema-required arguments with stable metadata' do
    aggregate_failures do
      contract_oracle.each do |name, contract|
        next if contract.fetch(:required).empty?

        result = call_tool(full_server, name, {}).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('missing_required_arguments'), name
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
