# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/server'

RSpec.describe CodebaseIndex::Console::Server do
  let(:config) do
    { 'mode' => 'direct', 'command' => 'echo test' }
  end

  describe '.build' do
    it 'returns an MCP::Server instance' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'accepts nested console config' do
      nested_config = { 'console' => config }
      server = described_class.build(config: nested_config)
      expect(server).to be_a(MCP::Server)
    end
  end

  describe '.register_tier1_tools' do
    it 'registers 9 tools on the server' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      expect(tools.size).to eq(9)
    end

    it 'registers expected tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      expect(tools.keys).to contain_exactly(
        'console_count',
        'console_sample',
        'console_find',
        'console_pluck',
        'console_aggregate',
        'console_association_count',
        'console_schema',
        'console_recent',
        'console_status'
      )
    end
  end
end
