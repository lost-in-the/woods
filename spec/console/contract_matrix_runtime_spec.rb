# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
ENV['WOODS_DUMMY_DB'] ||= File.join(Dir.tmpdir, "woods-console-contract-#{Process.pid}.sqlite3")
require_relative 'support/booted_console_app' if ENV['WOODS_RUN_BOOTED_APP']
require 'woods/console/server'

module ConsoleContractMatrixRuntime
  SEMANTIC_PREDICATES = {
    integer: ->(value) { value.is_a?(Integer) },
    number_or_null: ->(value) { value.nil? || value.is_a?(Numeric) },
    string: ->(value) { value.is_a?(String) },
    array: ->(value) { value.is_a?(Array) },
    array_of_strings: ->(value) { value.is_a?(Array) && value.all?(String) },
    array_of_arrays: ->(value) { value.is_a?(Array) && value.all?(Array) },
    array_of_records: ->(value) { value.is_a?(Array) && value.all?(Hash) },
    record_or_null: ->(value) { value.nil? || value.is_a?(Hash) },
    column_metadata_by_name: ->(value) { value.is_a?(Hash) && value.values.all?(Hash) },
    optional_index_metadata: ->(value) { value.nil? || value.is_a?(Array) }
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

  before do
    @original_context_format = Woods.configuration.context_format
    @original_blocked_tables = Woods.configuration.console_blocked_tables
    Woods.configuration.context_format = :json
    Woods.configuration.console_blocked_tables = %w[schema_migrations ar_internal_metadata]
    Comment.find_or_create_by!(post: Post.first, body: 'Console contract comment')
  end

  after do
    Woods.configuration.context_format = @original_context_format
    Woods.configuration.console_blocked_tables = @original_blocked_tables
  end

  def build_server(redacted_columns: [])
    Woods::Console::Server.build_embedded(
      model_validator: validator,
      safe_context: safe_context,
      redacted_columns: redacted_columns,
      connection: connection,
      read_tools_enabled: true,
      model_tables: model_tables,
      model_reflections: model_reflections
    )
  end

  def registered_tools(server)
    server.instance_variable_get(:@tools)
  end

  def call_tool(server, name, arguments)
    tool = registered_tools(server).fetch(name)
    tool.input_schema_value.validate_arguments(arguments)
    tool.call(**arguments, server_context: {})
  end

  def parsed_result(response)
    expect(response).not_to be_error
    JSON.parse(response.content.first.fetch(:text))
  end

  def expect_semantic_value(value, semantic)
    predicate = ConsoleContractMatrixRuntime::SEMANTIC_PREDICATES.fetch(semantic)
    expect(value).to satisfy("match #{semantic}") { |candidate| predicate.call(candidate) }
  end

  def expect_semantic_shape(result, shape)
    shape.each do |key, semantic|
      value = result[key.to_s]
      expect(result).to have_key(key.to_s) unless semantic == :optional_index_metadata
      expect_semantic_value(value, semantic)
    end
  end

  it 'executes every registered row through ActiveRecord and its full dispatch pipeline' do
    server = build_server

    expect(matrix.size).to eq(11)
    expect(registered_tools(server).keys).to contain_exactly(*matrix.map { |row| row.fetch(:name) })

    matrix.each do |row|
      response = call_tool(server, row.fetch(:name), row.fetch(:representative_valid_input))
      result = parsed_result(response)

      expect_semantic_shape(result, row.dig(:semantic_output, :shape))
    end
  end

  it 'drives every registered invalid representative to its declared schema error' do
    server = build_server

    matrix.each do |row|
      tool = registered_tools(server).fetch(row.fetch(:name))
      invalid = row.fetch(:representative_invalid_input)

      expect(invalid.fetch(:error_class)).to eq('MCP::Tool::InputSchema::ValidationError')
      expect { tool.input_schema_value.validate_arguments(invalid.fetch(:arguments)) }
        .to raise_error(MCP::Tool::InputSchema::ValidationError), row.fetch(:name)
    end
  end

  it 'enforces every executable table-gate claim before a real query' do
    Woods.configuration.console_blocked_tables = ['posts']
    server = build_server
    gated_rows = matrix.reject { |row| row.fetch(:table_gate) == :not_applicable_status_metadata }

    gated_rows.each do |row|
      arguments = row.fetch(:representative_valid_input)
      arguments = { sql: 'SELECT * FROM posts' } if row.fetch(:name) == 'console_sql'
      response = call_tool(server, row.fetch(:name), arguments)

      expect(response).to be_error, row.fetch(:name)
      expect(response.content.first.fetch(:text)).to include('posts'), row.fetch(:name)
    end
  end

  it 'redacts real record and positional outputs for every claimed data-bearing path' do
    source = Post.first.title
    server = build_server(redacted_columns: ['title'])
    calls = {
      'console_sample' => { model: 'Post' },
      'console_find' => { model: 'Post', id: Post.first.id, columns: %w[id title] },
      'console_pluck' => { model: 'Post', columns: ['title'] },
      'console_recent' => { model: 'Post', columns: %w[id title] },
      'console_sql' => { sql: 'SELECT title FROM posts' },
      'console_query' => { model: 'Post', select: ['title'] }
    }

    calls.each do |name, arguments|
      row = matrix.find { |candidate| candidate.fetch(:name) == name }
      expect(row.fetch(:redaction)).not_to match(/^not_applicable/)

      text = call_tool(server, name, arguments).content.first.fetch(:text)
      expect(text).to include('[REDACTED]'), name
      expect(text).not_to include(source), name
    end
  end

  it 'credential-scans a real executor result before rendering' do
    credential = 'sk_live_abcdefghijklmnopqrstuvwx'
    post = Post.first
    original_title = post.title
    post.update!(title: credential)
    server = build_server

    arguments = { model: 'Post', id: post.id, columns: ['title'] }
    text = call_tool(server, 'console_find', arguments).content.first.fetch(:text)

    expect(text).to include('[REDACTED]')
    expect(text).not_to include(credential)
  ensure
    post&.update!(title: original_title) if original_title
  end
end
