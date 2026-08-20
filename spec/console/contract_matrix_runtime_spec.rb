# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
ENV['WOODS_DUMMY_DB'] ||= File.join(Dir.tmpdir, "woods-console-contract-#{Process.pid}.sqlite3")
require_relative 'support/booted_console_app' if ENV['WOODS_RUN_BOOTED_APP']
require 'woods/console/server'

module ConsoleContractMatrixRuntime
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
      'indexes' => []
    },
    'console_recent' => { 'records' => RECORD_ROWS.reverse },
    'console_status' => { 'status' => 'ok', 'models' => %w[Comment Post], 'adapter' => 'SQLite' },
    'console_sql' => { 'columns' => %w[id title], 'rows' => POSITIONAL_ROWS, 'count' => 3 },
    'console_query' => { 'columns' => %w[id title], 'rows' => POSITIONAL_ROWS, 'count' => 3 }
  }.freeze
end

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
    result = response.fetch('result')
    expect(result.fetch('isError')).to be(true)
    expect(result.dig('content', 0, 'type')).to eq('text')
    result.dig('content', 0, 'text')
  end

  def execute_after_schema(name, arguments)
    spec = Woods::Console::Server::TOOL_SPECS.find { |candidate| candidate.name == name }
    request = spec.handler.call(arguments.transform_keys(&:to_sym))
    direct_executor.send_request(request)
  rescue Woods::Console::SqlValidationError => e
    { 'ok' => false, 'error' => e.message, 'error_type' => 'validation' }
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
      result.merge('columns' => result.fetch('columns').keys.sort)
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

  it 'rejects every predictable registered executor validation in the SDK schema' do
    server = build_server
    cases = [
      ['console_count', { model: ' ' }],
      ['console_sample', { model: 'Post', columns: ['bad key'] }],
      ['console_find', { model: 'Post', by: { 'bad key' => 1 } }],
      ['console_pluck', { model: 'Post', columns: ['bad key'] }],
      ['console_aggregate', { model: 'Post', function: 'sum', column: 'bad key' }],
      ['console_association_count', { model: 'Post', id: 1, association: 'bad key' }],
      ['console_schema', { model: ' ' }],
      ['console_recent', { model: 'Post', order_by: 'bad key' }],
      ['console_sql', { sql: " \n\t" }],
      ['console_query', { model: 'Post', select: ['bad key'] }]
    ]

    aggregate_failures do
      cases.each do |name, arguments|
        expect(execute_after_schema(name, arguments).fetch('ok')).to be(false), name
        expect(schema_accepts?(server, name, arguments)).to be(false), name
        expect(tools_call(server, name, arguments).dig('result', 'isError')).to be(true), name
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
      'console_sample' => { model: 'Post', limit: 25, columns: %w[status title] },
      'console_find' => { model: 'Post', id: 1, columns: %w[status title] },
      'console_pluck' => { model: 'Post', columns: %w[status title] },
      'console_recent' => { model: 'Post', limit: 3, columns: %w[status title] },
      'console_sql' => { sql: 'SELECT status, title FROM posts ORDER BY id' },
      'console_query' => { model: 'Post', select: %w[status title], order: { 'id' => 'asc' } }
    }

    calls.each do |name, arguments|
      row = matrix.find { |candidate| candidate.fetch(:name) == name }
      result_text = JSON.generate(tool_result(tools_call(server, name, arguments)))

      expect(row.fetch(:redaction)).to match(/_and_eav\z/), name
      expect(result_text).to include('[REDACTED]'), name
      expect(result_text).not_to include('Alpha'), name
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
