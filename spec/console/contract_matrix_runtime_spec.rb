# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
ENV['WOODS_DUMMY_DB'] ||= File.join(Dir.tmpdir, "woods-console-contract-#{Process.pid}.sqlite3")
require_relative 'support/booted_console_app' if ENV['WOODS_RUN_BOOTED_APP']
require 'woods/console/server'

# rubocop:disable Metrics/ModuleLength
module ConsoleContractMatrixRuntime
  POST_STATUS_INDEX = {
    'name' => 'index_posts_on_status_for_console_contract',
    'columns' => ['status'],
    'unique' => false
  }.freeze
  RECORD_ROWS = [
    { 'id' => 1, 'title' => 'Alpha' },
    { 'id' => 2, 'title' => 'Beta' },
    { 'id' => 3, 'title' => 'Gamma' }
  ].freeze
  POSITIONAL_ROWS = [[1, 'Alpha'], [2, 'Beta'], [3, 'Gamma']].freeze
  EXPECTED_RESULTS = {
    'console_count' => { 'count' => 3 },
    'console_sample' => { 'records' => RECORD_ROWS },
    'console_find' => { 'record' => RECORD_ROWS.first },
    'console_pluck' => { 'columns' => %w[id title], 'values' => POSITIONAL_ROWS },
    'console_aggregate' => { 'value' => 60 },
    'console_association_count' => { 'count' => 2 },
    'console_schema' => {
      'columns' => %w[created_at id status title updated_at],
      'indexes' => [POST_STATUS_INDEX]
    },
    'console_recent' => { 'records' => RECORD_ROWS.reverse },
    'console_status' => { 'status' => 'ok', 'models' => %w[Comment Post], 'adapter' => 'SQLite' },
    'console_sql' => { 'columns' => %w[id title], 'rows' => POSITIONAL_ROWS, 'count' => 3 },
    'console_query' => { 'columns' => %w[id title], 'rows' => POSITIONAL_ROWS, 'count' => 3 }
  }.freeze

  MAX_RECORD_ID = 9_223_372_036_854_775_807

  def self.schema_case(label, arguments, keyword, path)
    { label: label, arguments: arguments, schema: { keyword: keyword, path: path } }.freeze
  end

  def self.execution_case(label, arguments, message, public_prefix: 'validation: ')
    {
      label: label,
      arguments: arguments,
      execution: { error_type: 'validation', message: message, public_prefix: public_prefix }
    }.freeze
  end

  # Literal audit of each predictable validation branch exposed by the 11
  # registered tools. Repeated scope-key behavior is exercised for every
  # scoped tool in its own cross-tool example below.
  VALIDATION_CASES = {
    'console_count' => [
      schema_case(:model_type, { model: 1 }, 'type', '/model'),
      schema_case(:model_pattern, { model: ' ' }, 'pattern', '/model'),
      schema_case(:scope_type, { model: 'Post', scope: [] }, 'type', '/scope'),
      execution_case(
        :unknown_model, { model: 'Missing' },
        'Unknown model: Missing. Available: Comment, Post'
      )
    ],
    'console_sample' => [
      schema_case(:limit_type, { model: 'Post', limit: '5' }, 'type', '/limit'),
      schema_case(:limit_minimum, { model: 'Post', limit: 0 }, 'minimum', '/limit'),
      schema_case(:limit_maximum, { model: 'Post', limit: 26 }, 'maximum', '/limit'),
      schema_case(:columns_type, { model: 'Post', columns: 'id' }, 'type', '/columns'),
      schema_case(:column_type, { model: 'Post', columns: [1] }, 'type', '/columns/0'),
      schema_case(:column_pattern, { model: 'Post', columns: ['bad key'] }, 'pattern', '/columns/0'),
      execution_case(
        :unknown_column, { model: 'Post', columns: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ],
    'console_find' => [
      schema_case(:id_type, { model: 'Post', id: '1' }, 'type', '/id'),
      schema_case(:id_minimum, { model: 'Post', id: 0 }, 'minimum', '/id'),
      schema_case(:id_maximum, { model: 'Post', id: MAX_RECORD_ID + 1 }, 'maximum', '/id'),
      schema_case(:by_type, { model: 'Post', by: [] }, 'type', '/by'),
      schema_case(:by_key_pattern, { model: 'Post', by: { 'bad key' => 1 } }, 'pattern', '/by'),
      schema_case(:columns_type, { model: 'Post', columns: 'id' }, 'type', '/columns'),
      schema_case(:column_type, { model: 'Post', columns: [1] }, 'type', '/columns/0'),
      schema_case(:column_pattern, { model: 'Post', columns: ['bad key'] }, 'pattern', '/columns/0'),
      execution_case(
        :unknown_lookup_column, { model: 'Post', by: { 'missing' => 1 } },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_output_column, { model: 'Post', id: 1, columns: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ],
    'console_pluck' => [
      schema_case(:columns_type, { model: 'Post', columns: {} }, 'type', '/columns'),
      schema_case(:columns_min_items, { model: 'Post', columns: [] }, 'minItems', '/columns'),
      schema_case(:column_type, { model: 'Post', columns: [1] }, 'type', '/columns/0'),
      schema_case(:column_pattern, { model: 'Post', columns: ['bad key'] }, 'pattern', '/columns/0'),
      schema_case(:limit_type, { model: 'Post', columns: ['id'], limit: '100' }, 'type', '/limit'),
      schema_case(:limit_minimum, { model: 'Post', columns: ['id'], limit: 0 }, 'minimum', '/limit'),
      schema_case(:limit_maximum, { model: 'Post', columns: ['id'], limit: 1001 }, 'maximum', '/limit'),
      schema_case(:distinct_type, { model: 'Post', columns: ['id'], distinct: 'false' }, 'type', '/distinct'),
      execution_case(
        :unknown_column, { model: 'Post', columns: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ],
    'console_aggregate' => [
      schema_case(:function_type, { model: 'Post', function: 1 }, 'type', '/function'),
      schema_case(:function_enum, { model: 'Post', function: 'bogus' }, 'enum', '/function'),
      schema_case(:column_type, { model: 'Post', function: 'sum', column: 1 }, 'type', '/column'),
      schema_case(:column_pattern, { model: 'Post', function: 'sum', column: 'bad key' }, 'pattern', '/column'),
      schema_case(:column_coupling, { model: 'Post', function: 'sum' }, 'required', ''),
      execution_case(
        :unknown_column, { model: 'Post', function: 'sum', column: 'missing' },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ],
    'console_association_count' => [
      schema_case(
        :id_type, { model: 'Post', id: '1', association: 'comments' }, 'type', '/id'
      ),
      schema_case(
        :id_minimum, { model: 'Post', id: 0, association: 'comments' }, 'minimum', '/id'
      ),
      schema_case(
        :id_maximum, { model: 'Post', id: MAX_RECORD_ID + 1, association: 'comments' }, 'maximum', '/id'
      ),
      schema_case(:association_type, { model: 'Post', id: 1, association: 1 }, 'type', '/association'),
      schema_case(
        :association_pattern, { model: 'Post', id: 1, association: 'bad key' }, 'pattern', '/association'
      ),
      execution_case(
        :unknown_association, { model: 'Post', id: 1, association: 'missing' },
        "Unknown association 'missing' on Post"
      )
    ],
    'console_schema' => [
      schema_case(:model_pattern, { model: ' ' }, 'pattern', '/model'),
      schema_case(:include_indexes_type, { model: 'Post', include_indexes: 'true' }, 'type', '/include_indexes'),
      execution_case(
        :unknown_model, { model: 'Missing' },
        'Unknown model: Missing. Available: Comment, Post'
      )
    ],
    'console_recent' => [
      schema_case(:order_by_type, { model: 'Post', order_by: 1 }, 'type', '/order_by'),
      schema_case(:order_by_pattern, { model: 'Post', order_by: 'bad key' }, 'pattern', '/order_by'),
      schema_case(:direction_type, { model: 'Post', direction: 1 }, 'type', '/direction'),
      schema_case(:direction_enum, { model: 'Post', direction: 'sideways' }, 'enum', '/direction'),
      schema_case(:limit_type, { model: 'Post', limit: '10' }, 'type', '/limit'),
      schema_case(:limit_minimum, { model: 'Post', limit: 0 }, 'minimum', '/limit'),
      schema_case(:limit_maximum, { model: 'Post', limit: 51 }, 'maximum', '/limit'),
      schema_case(:columns_type, { model: 'Post', columns: 'id' }, 'type', '/columns'),
      schema_case(:column_type, { model: 'Post', columns: [1] }, 'type', '/columns/0'),
      schema_case(:column_pattern, { model: 'Post', columns: ['bad key'] }, 'pattern', '/columns/0'),
      execution_case(
        :unknown_order_column, { model: 'Post', order_by: 'missing' },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_output_column, { model: 'Post', columns: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ],
    'console_status' => [
      schema_case(:arguments_type, [], 'type', '')
    ],
    'console_sql' => [
      schema_case(:sql_type, { sql: 1 }, 'type', '/sql'),
      schema_case(:sql_pattern, { sql: " \n\t" }, 'pattern', '/sql'),
      schema_case(:limit_type, { sql: 'SELECT 1', limit: '100' }, 'type', '/limit'),
      schema_case(:limit_minimum, { sql: 'SELECT 1', limit: 0 }, 'minimum', '/limit'),
      schema_case(:limit_maximum, { sql: 'SELECT 1', limit: 10_001 }, 'maximum', '/limit'),
      execution_case(
        :write_statement, { sql: 'DELETE FROM posts' },
        'Rejected: DELETE statements are not allowed', public_prefix: ''
      ),
      execution_case(
        :multiple_statements, { sql: 'SELECT 1; SELECT 2' },
        'Rejected: multiple statements are not allowed', public_prefix: ''
      ),
      execution_case(
        :writable_cte, { sql: 'WITH gone AS (DELETE FROM posts RETURNING *) SELECT * FROM gone' },
        'Rejected: writable CTEs are not allowed', public_prefix: ''
      ),
      execution_case(
        :set_operator, { sql: 'SELECT 1 UNION SELECT 2' },
        'Rejected: UNION is not allowed', public_prefix: ''
      ),
      execution_case(
        :dangerous_function, { sql: 'SELECT pg_sleep(1)' },
        'Rejected: dangerous function pg_sleep is not allowed', public_prefix: ''
      ),
      execution_case(
        :write_keyword_in_body, { sql: 'SELECT 1 UPDATE posts SET status = 10' },
        'Rejected: UPDATE statements are not allowed (found in SQL body)', public_prefix: ''
      ),
      execution_case(
        :non_read_prefix, { sql: 'VALUES (1)' },
        'Rejected: SQL must start with SELECT, WITH, or EXPLAIN', public_prefix: ''
      )
    ],
    'console_query' => [
      schema_case(:model_type, { model: 1, select: ['id'] }, 'type', '/model'),
      schema_case(:model_pattern, { model: ' ', select: ['id'] }, 'pattern', '/model'),
      schema_case(:select_type, { model: 'Post', select: 'id' }, 'type', '/select'),
      schema_case(:select_min_items, { model: 'Post', select: [] }, 'minItems', '/select'),
      schema_case(:select_item_type, { model: 'Post', select: [1] }, 'type', '/select/0'),
      schema_case(:select_pattern, { model: 'Post', select: ['bad key'] }, 'pattern', '/select/0'),
      schema_case(:joins_type, { model: 'Post', select: ['id'], joins: 'comments' }, 'type', '/joins'),
      schema_case(:join_type, { model: 'Post', select: ['id'], joins: [1] }, 'type', '/joins/0'),
      schema_case(
        :join_pattern, { model: 'Post', select: ['id'], joins: ['bad key'] }, 'pattern', '/joins/0'
      ),
      schema_case(:group_type, { model: 'Post', select: ['id'], group_by: 'status' }, 'type', '/group_by'),
      schema_case(:group_item_type, { model: 'Post', select: ['id'], group_by: [1] }, 'type', '/group_by/0'),
      schema_case(
        :group_pattern, { model: 'Post', select: ['id'], group_by: ['bad key'] }, 'pattern', '/group_by/0'
      ),
      schema_case(:having_type, { model: 'Post', select: ['id'], having: 'COUNT(*) > 1' }, 'type', '/having'),
      schema_case(:having_min_properties, { model: 'Post', select: ['id'], having: {} }, 'minProperties', '/having'),
      schema_case(
        :having_key_pattern, { model: 'Post', select: ['id'], having: { 'bad key' => 1 } },
        'pattern', '/having'
      ),
      schema_case(
        :having_array_min_items, { model: 'Post', select: ['id'], having: ['COUNT(*) > ?'] },
        'minItems', '/having'
      ),
      schema_case(
        :having_array_max_items, { model: 'Post', select: ['id'], having: ['COUNT(*) > ?', 1, 2] },
        'maxItems', '/having'
      ),
      schema_case(
        :having_template_type, { model: 'Post', select: ['id'], having: [1, 2] },
        'type', '/having/0'
      ),
      schema_case(
        :having_template, { model: 'Post', select: ['id'], having: ['not executable', 1] },
        'pattern', '/having/0'
      ),
      schema_case(:order_type, { model: 'Post', select: ['id'], order: [] }, 'type', '/order'),
      schema_case(
        :order_key_pattern, { model: 'Post', select: ['id'], order: { 'bad key' => 'asc' } },
        'pattern', '/order'
      ),
      schema_case(
        :order_direction_type, { model: 'Post', select: ['id'], order: { 'id' => 1 } },
        'type', '/order/id'
      ),
      schema_case(
        :order_direction_pattern, { model: 'Post', select: ['id'], order: { 'id' => 'sideways' } },
        'pattern', '/order/id'
      ),
      schema_case(:scope_type, { model: 'Post', select: ['id'], scope: 'status = 10' }, 'type', '/scope'),
      schema_case(:scope_min_items, { model: 'Post', select: ['id'], scope: ['status = ?'] }, 'minItems', '/scope'),
      schema_case(
        :scope_max_items, { model: 'Post', select: ['id'], scope: ['status = ?', 10, 20] },
        'maxItems', '/scope'
      ),
      schema_case(
        :scope_template, { model: 'Post', select: ['id'], scope: ['status = 10', 10] },
        'pattern', '/scope/0'
      ),
      schema_case(
        :scope_template_type, { model: 'Post', select: ['id'], scope: [1, 10] },
        'type', '/scope/0'
      ),
      schema_case(
        :scope_bind_type, { model: 'Post', select: ['id'], scope: ['status = ?', [10]] },
        'type', '/scope/1'
      ),
      schema_case(:limit_type, { model: 'Post', select: ['id'], limit: '100' }, 'type', '/limit'),
      schema_case(:limit_minimum, { model: 'Post', select: ['id'], limit: 0 }, 'minimum', '/limit'),
      schema_case(:limit_maximum, { model: 'Post', select: ['id'], limit: 10_001 }, 'maximum', '/limit'),
      execution_case(
        :unknown_model, { model: 'Missing', select: ['id'] },
        'Unknown model: Missing. Available: Comment, Post'
      ),
      execution_case(
        :unknown_select_column, { model: 'Post', select: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_join, { model: 'Post', select: ['id'], joins: ['missing'] },
        "Unknown association 'missing' on Post"
      ),
      execution_case(
        :unknown_group_column, { model: 'Post', select: ['id'], group_by: ['missing'] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_having_column, { model: 'Post', select: ['id'], having: { 'missing' => 1 } },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_order_column, { model: 'Post', select: ['id'], order: { 'missing' => 'asc' } },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      ),
      execution_case(
        :unknown_scope_column, { model: 'Post', select: ['id'], scope: ['missing = ?', 1] },
        "Unknown column 'missing' on Post. Available: created_at, id, status, title, updated_at"
      )
    ]
  }.transform_values(&:freeze).freeze
end
# rubocop:enable Metrics/ModuleLength

RSpec.describe 'Console MCP contract matrix runtime', :booted_app do
  let(:models) { [Post, Comment] }
  let(:connection) { ActiveRecord::Base.connection }
  let(:validator) do
    Woods::Console::ModelValidator.new(
      registry: models.to_h { |model| [model.name, model.column_names] }
    )
  end
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }
  let(:model_tables) { models.to_h { |model| [model.name, model.table_name] } }
  let(:model_reflections) do
    models.to_h do |model|
      associations = model.reflect_on_all_associations.to_h do |reflection|
        [reflection.name.to_s, reflection.klass.table_name]
      end
      [model.name, associations]
    end
  end
  let(:matrix) do
    Woods::Console::Server::CONTRACT_MATRIX.select do |row|
      row.fetch(:executable_modes).include?(:embedded_read)
    end
  end
  let(:direct_executor) do
    Woods::Console::EmbeddedExecutor.new(
      model_validator: validator,
      safe_context: safe_context,
      connection: connection,
      read_tools_enabled: true
    )
  end

  before do
    @original_context_format = Woods.configuration.context_format
    @original_blocked_tables = Woods.configuration.console_blocked_tables
    Woods.configuration.context_format = :json
    Woods.configuration.console_blocked_tables = %w[schema_migrations ar_internal_metadata]
    seed_contract_rows
  end

  after do
    Woods.configuration.context_format = @original_context_format
    Woods.configuration.console_blocked_tables = @original_blocked_tables
  end

  def seed_contract_rows
    unless connection.indexes(Post.table_name).any? { |index| index.name == ConsoleContractMatrixRuntime::POST_STATUS_INDEX['name'] }
      connection.add_index(
        Post.table_name,
        :status,
        name: ConsoleContractMatrixRuntime::POST_STATUS_INDEX['name'],
        unique: false
      )
    end

    Comment.delete_all
    Post.delete_all
    Post.create!(id: 1, title: 'Alpha', status: 10, created_at: Time.utc(2026, 1, 1))
    Post.create!(id: 2, title: 'Beta', status: 20, created_at: Time.utc(2026, 1, 2))
    Post.create!(id: 3, title: 'Gamma', status: 30, created_at: Time.utc(2026, 1, 3))
    Comment.create!(id: 1, post_id: 1, body: 'First')
    Comment.create!(id: 2, post_id: 1, body: 'Second')
    Comment.create!(id: 3, post_id: 2, body: 'Third')
  end

  def build_server(redacted_columns: [], redacted_key_values: [])
    Woods::Console::Server.build_embedded(
      model_validator: validator,
      safe_context: safe_context,
      redacted_columns: redacted_columns,
      redacted_key_values: redacted_key_values,
      connection: connection,
      read_tools_enabled: true,
      model_tables: model_tables,
      model_reflections: model_reflections
    )
  end

  def tools_call(server, name, arguments)
    request = JSON.generate(
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: name, arguments: arguments }
    )
    JSON.parse(server.handle_json(request))
  end

  def tool_result(response)
    expect(response).to include('jsonrpc' => '2.0', 'id' => 1)
    result = response.fetch('result')
    expect(result.fetch('isError')).to be(false)
    expect(result.dig('content', 0, 'type')).to eq('text')
    JSON.parse(result.dig('content', 0, 'text'))
  end

  def tool_error(response)
    expect(response).to include('jsonrpc' => '2.0', 'id' => 1)
    expect(response).not_to have_key('error')
    result = response.fetch('result')
    text = result.dig('content', 0, 'text')
    expect(result).to eq(
      'content' => [{ 'type' => 'text', 'text' => text }],
      'isError' => true
    )
    text
  end

  def execute_after_schema(name, arguments)
    spec = Woods::Console::Server::TOOL_SPECS.find { |candidate| candidate.name == name }
    handler_arguments = arguments.is_a?(Hash) ? arguments.transform_keys(&:to_sym) : arguments
    request = spec.handler.call(handler_arguments)
    direct_executor.send_request(request)
  rescue Woods::Console::InputContract::ValidationError, Woods::Console::SqlValidationError => e
    { 'ok' => false, 'error' => e.message, 'error_type' => 'validation' }
  end

  def execute_direct(name, arguments)
    direct_executor.send_request(
      'tool' => name.delete_prefix('console_'),
      'params' => arguments
    )
  end

  def schema_errors(server, name, arguments)
    tool = server.instance_variable_get(:@tools).fetch(name)
    normalized = JSON.parse(JSON.generate(arguments))
    tool.input_schema_value.send(:schemer).validate(normalized).to_a
  end

  def schema_error_message(server, name, arguments)
    tool = server.instance_variable_get(:@tools).fetch(name)
    tool.input_schema_value.validate_arguments(arguments)
    raise "Expected #{name} schema validation to fail"
  rescue MCP::Tool::InputSchema::ValidationError => e
    e.message
  end

  def schema_keyword(error)
    json_types = %w[null boolean object array number string integer]
    json_types.include?(error.fetch('type')) ? 'type' : error.fetch('type')
  end

  def schema_accepts?(server, name, arguments)
    tool = server.instance_variable_get(:@tools).fetch(name)
    tool.input_schema_value.validate_arguments(arguments)
    true
  rescue MCP::Tool::InputSchema::ValidationError
    false
  end

  def normalize_concrete_result(name, result)
    case name
    when 'console_sample'
      result.merge('records' => result.fetch('records').sort_by { |row| row.fetch('id') })
    when 'console_schema'
      result.merge(
        'columns' => result.fetch('columns').keys.sort,
        'indexes' => result.fetch('indexes').sort_by { |index| index.fetch('name') }
      )
    else
      result
    end
  end

  it 'dispatches all 11 valid representatives through the public JSON-RPC server with concrete results' do
    server = build_server
    registered = server.instance_variable_get(:@tools).keys

    expect(matrix.size).to eq(11)
    expect(registered).to contain_exactly(*matrix.map { |row| row.fetch(:name) })
    matrix.each do |row|
      name = row.fetch(:name)
      response = tools_call(server, name, row.fetch(:representative_valid_input))

      expect(normalize_concrete_result(name, tool_result(response))).to eq(
        ConsoleContractMatrixRuntime::EXPECTED_RESULTS.fetch(name)
      )
    end
  end

  it 'dispatches all 11 invalid representatives to their declared wire error contract' do
    server = build_server

    matrix.each do |row|
      invalid = row.fetch(:representative_invalid_input)
      text = tool_error(tools_call(server, row.fetch(:name), invalid.fetch(:arguments)))
      contract = invalid.fetch(:error_contract)

      expect(contract.fetch(:is_error)).to be(true)
      expect(text).to start_with(contract.fetch(:text_prefix)), row.fetch(:name)
    end
  end

  it 'enforces every required argument at schema, executor, handler, and public MCP boundaries' do
    server = build_server

    aggregate_failures do
      matrix.each do |row|
        row.dig(:arguments, :required).each do |required_name|
          name = row.fetch(:name)
          arguments = row.fetch(:representative_valid_input).reject do |key, _value|
            key.to_s == required_name
          end
          failure_message = "#{name}: missing #{required_name}"
          matching_error = schema_errors(server, name, arguments).find do |error|
            error.fetch('type') == 'required' && error.fetch('data_pointer').empty?
          end
          expect(matching_error).not_to be_nil, failure_message
          expected_message = "Missing required arguments: #{required_name}"

          [execute_direct(name, arguments), execute_after_schema(name, arguments)].each do |execution|
            expect(execution).to include(
              'ok' => false, 'error_type' => 'validation', 'error' => expected_message
            ), failure_message
          end
          expect(tool_error(tools_call(server, name, arguments))).to eq(expected_message), failure_message
        end
      end
    end
  end

  it 'validates model identity across every model-bearing registered tool and boundary' do
    server = build_server
    rows = matrix.select { |row| row.dig(:arguments, :constraints, :properties).key?(:model) }

    aggregate_failures do
      rows.each do |row|
        name = row.fetch(:name)
        base = row.fetch(:representative_valid_input)

        [{ value: 1, keyword: 'type' }, { value: ' ', keyword: 'pattern' }].each do |invalid|
          arguments = base.merge(model: invalid.fetch(:value))
          failure_message = "#{name}: model #{invalid.fetch(:keyword)}"
          matching_error = schema_errors(server, name, arguments).find do |error|
            schema_keyword(error) == invalid.fetch(:keyword) && error.fetch('data_pointer') == '/model'
          end
          expect(matching_error).not_to be_nil, failure_message
          expected_message = schema_error_message(server, name, arguments)

          [execute_direct(name, arguments), execute_after_schema(name, arguments)].each do |execution|
            expect(execution).to include(
              'ok' => false, 'error_type' => 'validation', 'error' => expected_message
            ), failure_message
          end
          expect(tool_error(tools_call(server, name, arguments))).to eq(expected_message), failure_message
        end

        arguments = base.merge(model: 'Missing')
        expected_message = 'Unknown model: Missing. Available: Comment, Post'
        expect(schema_errors(server, name, arguments)).to be_empty, name
        [execute_direct(name, arguments), execute_after_schema(name, arguments)].each do |execution|
          expect(execution).to include(
            'ok' => false, 'error_type' => 'validation', 'error' => expected_message
          ), name
        end
        expect(tool_error(tools_call(server, name, arguments))).to eq("validation: #{expected_message}"), name
      end
    end
  end

  it 'keeps SQL, select, and order SDK schemas in parity with real execution' do
    server = build_server
    cases = [
      ['console_sql', { sql: " \nSELECT 1\t" }, true],
      ['console_sql', { sql: " \n\t" }, false],
      ['console_query', { model: 'Post', select: ['sum(status) AS total'] }, true],
      ['console_query', { model: 'Post', select: ['SuM(status) aS total'] }, true],
      ['console_query', { model: 'Post', select: ['id, title'] }, false],
      ['console_query', { model: 'Post', select: ['id'], order: { 'id' => 'ASC' } }, true],
      ['console_query', { model: 'Post', select: ['id'], order: { 'id' => 'dEsC' } }, true],
      ['console_query', { model: 'Post', select: ['id'], order: { 'id' => 'sideways' } }, false]
    ]

    aggregate_failures do
      cases.each do |name, arguments, accepted|
        execution = execute_after_schema(name, arguments)
        response = tools_call(server, name, arguments)

        expect(schema_accepts?(server, name, arguments)).to be(accepted), arguments.inspect
        expect(execution.fetch('ok')).to be(accepted), arguments.inspect
        expect(response.dig('result', 'isError')).to be(!accepted), arguments.inspect
      end
    end
  end

  it 'keeps console_query object and exact two-element array scopes in public and executor parity' do
    server = build_server
    base = { model: 'Post', select: %w[id title], order: { 'id' => 'asc' } }
    valid_cases = [
      [{ 'status' => 20 }, [[2, 'Beta']]],
      [['status >= ?', 20], [[2, 'Beta'], [3, 'Gamma']]],
      [['posts.status = ?', 10], [[1, 'Alpha']]]
    ]
    invalid_scopes = [
      'status = 10',
      [],
      ['status = ?'],
      ['status = ?', 10, 20],
      [1, 10],
      ['status = 10', 10],
      ['status = ? OR title = ?', 10],
      ['status = ?', [10]],
      ['status = ?', { value: 10 }],
      ['bad key = ?', 10],
      ['status = ?; DROP TABLE posts', 10],
      ['status = ? UNION SELECT title FROM posts', 10]
    ]

    aggregate_failures do
      valid_cases.each do |scope, expected_rows|
        arguments = base.merge(scope: scope)
        execution = execute_after_schema('console_query', arguments)
        response = tools_call(server, 'console_query', arguments)

        expect(schema_accepts?(server, 'console_query', arguments)).to be(true), scope.inspect
        expect(execution.fetch('ok')).to be(true), scope.inspect
        expect(execution.dig('result', 'rows')).to eq(expected_rows), scope.inspect
        expect(tool_result(response).fetch('rows')).to eq(expected_rows), scope.inspect
      end

      invalid_scopes.each do |scope|
        arguments = base.merge(scope: scope)

        expect(schema_accepts?(server, 'console_query', arguments)).to be(false), scope.inspect
        expect(execute_after_schema('console_query', arguments).fetch('ok')).to be(false), scope.inspect
        expect(tools_call(server, 'console_query', arguments).dig('result', 'isError')).to be(true), scope.inspect
      end
    end
  end

  it 'validates object scope keys consistently for every advertised scoped tool' do
    server = build_server
    cases = {
      'console_count' => [{ model: 'Post' }, 'status', 'status_gteq', 'Post'],
      'console_sample' => [{ model: 'Post', columns: %w[id title] }, 'status', 'status_gteq', 'Post'],
      'console_pluck' => [{ model: 'Post', columns: ['id'] }, 'status', 'status_gteq', 'Post'],
      'console_aggregate' => [{ model: 'Post', function: 'count' }, 'status', 'status_gteq', 'Post'],
      'console_association_count' => [
        { model: 'Post', id: 1, association: 'comments' }, 'body', 'id_gteq', 'Comment'
      ],
      'console_recent' => [{ model: 'Post', columns: %w[id title] }, 'status', 'status_gteq', 'Post'],
      'console_query' => [{ model: 'Post', select: ['id'] }, 'status', 'status_gteq', 'Post']
    }

    expect(cases.keys).to contain_exactly(
      *matrix.select { |row| row.dig(:arguments, :constraints, :properties, :scope) }
             .map { |row| row.fetch(:name) }
    )

    aggregate_failures do
      cases.each do |name, (base, equality_key, predicate_key, scope_model)|
        [{ equality_key => equality_key == 'body' ? 'First' : 20 }, { predicate_key => 2 }].each do |scope|
          arguments = base.merge(scope: scope)
          expect(schema_errors(server, name, arguments)).to be_empty, "#{name}: #{scope.inspect}"
          expect(execute_direct(name, arguments).fetch('ok')).to be(true), "#{name}: #{scope.inspect}"
          expect(execute_after_schema(name, arguments).fetch('ok')).to be(true), "#{name}: #{scope.inspect}"
          expect(tools_call(server, name, arguments).dig('result', 'isError')).to be(false),
                                                                                  "#{name}: #{scope.inspect}"
        end

        non_object = base.merge(scope: name == 'console_query' ? 'status = 20' : [])
        type_error = schema_errors(server, name, non_object).find do |error|
          schema_keyword(error) == 'type' && error.fetch('data_pointer') == '/scope'
        end
        expect(type_error).not_to be_nil, name
        schema_message = schema_error_message(server, name, non_object)
        [execute_direct(name, non_object), execute_after_schema(name, non_object)].each do |execution|
          expect(execution).to include(
            'ok' => false, 'error_type' => 'validation', 'error' => schema_message
          ), name
        end
        expect(tool_error(tools_call(server, name, non_object))).to eq(schema_message), name

        malformed = base.merge(scope: { 'bad key' => 1 })
        malformed_error = schema_errors(server, name, malformed).find do |error|
          error.fetch('type') == 'pattern' && error.fetch('data_pointer') == '/scope'
        end
        expect(malformed_error).not_to be_nil, name
        schema_message = schema_error_message(server, name, malformed)
        expect(execute_direct(name, malformed)).to include(
          'ok' => false, 'error_type' => 'validation', 'error' => schema_message
        ), name
        expect(execute_after_schema(name, malformed)).to include(
          'ok' => false, 'error_type' => 'validation', 'error' => schema_message
        ), name
        expect(tool_error(tools_call(server, name, malformed))).to eq(schema_message), name

        unknown = base.merge(scope: { 'missing' => 1 })
        available = validator.columns_for(scope_model).join(', ')
        expected_message = "Unknown column 'missing' on #{scope_model}. Available: #{available}"
        expect(schema_errors(server, name, unknown)).to be_empty, name
        expect(execute_direct(name, unknown)).to include(
          'ok' => false, 'error_type' => 'validation', 'error' => expected_message
        ), name
        expect(execute_after_schema(name, unknown)).to include(
          'ok' => false, 'error_type' => 'validation', 'error' => expected_message
        ), name
        expect(tool_error(tools_call(server, name, unknown))).to eq("validation: #{expected_message}"), name
      end
    end
  end

  it 'enforces the audited validation catalog at schema, executor, handler, and public MCP boundaries' do
    server = build_server
    cases = ConsoleContractMatrixRuntime::VALIDATION_CASES

    expect(cases.keys).to contain_exactly(*matrix.map { |row| row.fetch(:name) })

    aggregate_failures do
      cases.each do |name, constraints|
        constraints.each do |constraint|
          arguments = constraint.fetch(:arguments)
          failure_message = "#{name}.#{constraint.fetch(:label)}: #{arguments.inspect}"
          errors = schema_errors(server, name, arguments)

          if constraint[:schema]
            expected = constraint.fetch(:schema)
            matching_error = errors.find do |error|
              schema_keyword(error) == expected.fetch(:keyword) &&
                error.fetch('data_pointer') == expected.fetch(:path)
            end
            expect(matching_error).not_to be_nil, failure_message
            expected_message = schema_error_message(server, name, arguments)

            [execute_direct(name, arguments), execute_after_schema(name, arguments)].each do |execution|
              expect(execution).to include(
                'ok' => false,
                'error_type' => 'validation',
                'error' => expected_message
              ), failure_message
            end

            expect(tool_error(tools_call(server, name, arguments))).to eq(expected_message), failure_message
          else
            expected = constraint.fetch(:execution)
            expect(errors).to be_empty, failure_message

            [execute_direct(name, arguments), execute_after_schema(name, arguments)].each do |execution|
              expect(execution).to include(
                'ok' => false,
                'error_type' => expected.fetch(:error_type),
                'error' => expected.fetch(:message)
              ), failure_message
            end

            expect(tool_error(tools_call(server, name, arguments))).to eq(
              "#{expected.fetch(:public_prefix)}#{expected.fetch(:message)}"
            ), failure_message
          end
        end
      end
    end
  end

  it 'gates base model, association, join, and SQL-derived table access independently' do
    cases = [
      [%w[posts], 'console_count', { model: 'Post' }, 'posts'],
      [%w[comments], 'console_association_count', { model: 'Post', id: 1, association: 'comments' }, 'comments'],
      [%w[comments], 'console_query', { model: 'Post', select: ['posts.id'], joins: ['comments'] }, 'comments'],
      [%w[comments], 'console_sql', { sql: 'SELECT * FROM comments' }, 'comments']
    ]

    cases.each do |blocked, name, arguments, expected_table|
      Woods.configuration.console_blocked_tables = blocked
      text = tool_error(tools_call(build_server, name, arguments))

      expect(text).to include(expected_table), name
    end
  end

  it 'applies configured EAV redaction to every claimed record and positional result' do
    pattern = { key_column: 'status', value_column: 'title', sensitive_keys: ['10'] }
    server = build_server(redacted_key_values: [pattern])
    calls = {
      'console_sample' => {
        arguments: [{ model: 'Post', limit: 25, columns: %w[status title] }],
        expected: [{
          'records' => [
            { 'status' => 10, 'title' => '[REDACTED]' },
            { 'status' => 20, 'title' => 'Beta' },
            { 'status' => 30, 'title' => 'Gamma' }
          ]
        }]
      },
      'console_find' => {
        arguments: [
          { model: 'Post', id: 1, columns: %w[status title] },
          { model: 'Post', id: 2, columns: %w[status title] },
          { model: 'Post', id: 3, columns: %w[status title] }
        ],
        expected: [
          { 'record' => { 'status' => 10, 'title' => '[REDACTED]' } },
          { 'record' => { 'status' => 20, 'title' => 'Beta' } },
          { 'record' => { 'status' => 30, 'title' => 'Gamma' } }
        ]
      },
      'console_pluck' => {
        arguments: [{ model: 'Post', columns: %w[status title] }],
        expected: [{
          'columns' => %w[status title],
          'values' => [[10, '[REDACTED]'], [20, 'Beta'], [30, 'Gamma']]
        }]
      },
      'console_recent' => {
        arguments: [{ model: 'Post', limit: 3, columns: %w[status title] }],
        expected: [{
          'records' => [
            { 'status' => 30, 'title' => 'Gamma' },
            { 'status' => 20, 'title' => 'Beta' },
            { 'status' => 10, 'title' => '[REDACTED]' }
          ]
        }]
      },
      'console_sql' => {
        arguments: [{ sql: 'SELECT status, title FROM posts ORDER BY id' }],
        expected: [{
          'columns' => %w[status title],
          'rows' => [[10, '[REDACTED]'], [20, 'Beta'], [30, 'Gamma']],
          'count' => 3
        }]
      },
      'console_query' => {
        arguments: [{ model: 'Post', select: %w[status title], order: { 'id' => 'asc' } }],
        expected: [{
          'columns' => %w[status title],
          'rows' => [[10, '[REDACTED]'], [20, 'Beta'], [30, 'Gamma']],
          'count' => 3
        }]
      }
    }

    calls.each do |name, contract|
      row = matrix.find { |candidate| candidate.fetch(:name) == name }
      results = contract.fetch(:arguments).map { |arguments| tool_result(tools_call(server, name, arguments)) }
      results.first.fetch('records').sort_by! { |record| record.fetch('status') } if name == 'console_sample'

      expect(row.fetch(:redaction)).to match(/_and_eav\z/), name
      expect(results).to eq(contract.fetch(:expected)), name
    end
  end

  it 'credential-scans an early table-gate error through registered server dispatch' do
    credential = 'sk_live_abcdefghijklmnopqrstuvwx'
    Woods.configuration.console_blocked_tables = [credential]
    server = build_server

    text = tool_error(tools_call(server, 'console_sql', { sql: "SELECT * FROM #{credential}" }))

    expect(text).to include('[REDACTED]')
    expect(text).not_to include(credential)
  end
end
