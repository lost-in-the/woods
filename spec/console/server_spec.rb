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

    it 'builds without redaction when no redacted_columns configured' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'builds with redaction when redacted_columns are configured' do
      config_with_redaction = config.merge('redacted_columns' => %w[ssn password])
      server = described_class.build(config: config_with_redaction)
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

  describe 'redaction via SafeContext' do
    let(:conn_mgr) do
      instance_double(CodebaseIndex::Console::ConnectionManager).tap do |m|
        allow(m).to receive(:send_request).and_return(
          'ok' => true,
          'result' => { 'name' => 'Alice', 'ssn' => '123-45-6789', 'email' => 'alice@example.com' }
        )
      end
    end

    before do
      allow(CodebaseIndex::Console::ConnectionManager).to receive(:new).and_return(conn_mgr)
    end

    it 'builds successfully when no redacted_columns configured' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'applies SafeContext redaction to Hash results' do
      safe_ctx = CodebaseIndex::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[ssn]
      )
      result = { 'name' => 'Alice', 'ssn' => '123-45-6789', 'email' => 'alice@example.com' }
      redacted = safe_ctx.redact(result)
      expect(redacted['ssn']).to eq('[REDACTED]')
      expect(redacted['name']).to eq('Alice')
      expect(redacted['email']).to eq('alice@example.com')
    end

    it 'applies SafeContext redaction to Array of Hashes' do
      safe_ctx = CodebaseIndex::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[password]
      )
      result = [
        { 'id' => 1, 'password' => 'secret1' },
        { 'id' => 2, 'password' => 'secret2' }
      ]
      redacted = described_class.send(:apply_redaction, result, safe_ctx)
      expect(redacted.map { |r| r['password'] }).to all(eq('[REDACTED]'))
      expect(redacted.map { |r| r['id'] }).to eq([1, 2])
    end

    it 'passes through non-Hash non-Array results unchanged' do
      safe_ctx = CodebaseIndex::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[ssn]
      )
      result = 42
      redacted = described_class.send(:apply_redaction, result, safe_ctx)
      expect(redacted).to eq(42)
    end
  end
end
