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

  describe 'tool registration' do
    it 'registers all tools on the server' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      expected_count = described_class::TIER1_TOOLS.size +
                       described_class::TIER2_TOOLS.size +
                       described_class::TIER3_TOOLS.size +
                       described_class::TIER4_TOOLS.size
      expect(tools.size).to eq(expected_count)
    end

    it 'registers all Tier 1 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER1_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 2 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER2_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 3 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER3_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 4 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER4_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end
  end
end
