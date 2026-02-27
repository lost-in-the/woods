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
    allow(connection).to receive(:transaction).and_yield
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
end
