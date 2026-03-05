# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/server'

RSpec.describe 'CodebaseIndex::Console::Server.build_embedded' do
  let(:registry) do
    { 'User' => %w[id email name], 'Post' => %w[id title body] }
  end
  let(:validator) { CodebaseIndex::Console::ModelValidator.new(registry: registry) }
  let(:connection) { instance_double('Connection') }
  let(:safe_context) { CodebaseIndex::Console::SafeContext.new(connection: connection) }

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
  end

  describe '.build_embedded' do
    it 'returns an MCP::Server instance' do
      server = CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context
      )

      expect(server).to be_a(MCP::Server)
    end

    it 'registers all 31 tools (same as bridge-based build)' do
      server = CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context
      )
      tools = server.instance_variable_get(:@tools)

      expected_count = CodebaseIndex::Console::Server::TIER1_TOOLS.size +
                       CodebaseIndex::Console::Server::TIER2_TOOLS.size +
                       CodebaseIndex::Console::Server::TIER3_TOOLS.size +
                       CodebaseIndex::Console::Server::TIER4_TOOLS.size
      expect(tools.size).to eq(expected_count)
    end

    it 'registers all Tier 1 tool names' do
      server = CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context
      )
      tools = server.instance_variable_get(:@tools)

      CodebaseIndex::Console::Server::TIER1_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'accepts redacted_columns parameter' do
      server = CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context,
        redacted_columns: %w[ssn password]
      )

      expect(server).to be_a(MCP::Server)
    end

    it 'works without redacted_columns' do
      server = CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context,
        redacted_columns: []
      )

      expect(server).to be_a(MCP::Server)
    end
  end

  describe 'integer parameter coercion' do
    let(:server) do
      CodebaseIndex::Console::Server.build_embedded(
        model_validator: validator,
        safe_context: safe_context,
        connection: connection
      )
    end

    let(:user_model) { class_double('User') }
    let(:ordered) { instance_double('ActiveRecord::Relation', 'ordered') }
    let(:limited) { instance_double('ActiveRecord::Relation', 'limited') }
    let(:record) { instance_double('User', attributes: { 'id' => 1, 'email' => 'a@b.com' }) }

    before do
      stub_const('User', user_model)
      unless defined?(Arel)
        stub_const('Arel', Module.new.tap { |m| m.define_singleton_method(:sql) { |raw_sql| raw_sql } })
      end
      Arel.define_singleton_method(:sql) { |raw_sql| raw_sql } unless Arel.respond_to?(:sql)
      allow(user_model).to receive(:order).and_return(ordered)
      allow(ordered).to receive(:limit).and_return(limited)
      allow(limited).to receive(:map).and_yield(record).and_return([record.attributes])
    end

    it 'coerces string limit in console_sample tool' do
      response = call_tool(server, 'console_sample', model: 'User', limit: '3')
      text = response_text(response)
      # Should succeed without type errors — coercion prevents NoMethodError on String
      expect(text).to include('records')
      expect(text).not_to include('execution:')
    end

    it 'coerces string id in console_find tool' do
      allow(user_model).to receive(:find_by).with(id: 1).and_return(record)

      response = call_tool(server, 'console_find', model: 'User', id: '1')
      text = response_text(response)
      expect(text).to include('record')
      expect(text).not_to include('execution:')
    end
  end

  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  def parse_response(response)
    JSON.parse(response_text(response))
  end
end
