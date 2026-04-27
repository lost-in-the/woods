# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/bridge_protocol'

RSpec.describe Woods::Console::BridgeProtocol do
  describe '::SUPPORTED_TOOLS' do
    it 'is the canonical list of Tier 1 console tools' do
      expect(described_class::SUPPORTED_TOOLS).to eq(
        %w[count sample find pluck aggregate association_count schema recent status]
      )
    end

    it 'is frozen so callers can assume the list is immutable' do
      expect(described_class::SUPPORTED_TOOLS).to be_frozen
    end
  end

  describe '::TIER1_TOOLS' do
    it 'aliases SUPPORTED_TOOLS (Tier 1 is the always-on bucket)' do
      expect(described_class::TIER1_TOOLS).to eq(described_class::SUPPORTED_TOOLS)
    end
  end

  describe '::TOOL_HANDLERS' do
    it 'maps each tool to the handle_<tool> method symbol' do
      described_class::SUPPORTED_TOOLS.each do |tool|
        expect(described_class::TOOL_HANDLERS[tool]).to eq(:"handle_#{tool}")
      end
    end

    it 'is frozen' do
      expect(described_class::TOOL_HANDLERS).to be_frozen
    end

    it 'covers every SUPPORTED_TOOLS entry' do
      expect(described_class::TOOL_HANDLERS.keys).to match_array(described_class::SUPPORTED_TOOLS)
    end
  end

  describe 'sharing across executors' do
    # `equal?` asserts object identity, not value equality. It's load-
    # bearing here: if a future refactor does
    # `SUPPORTED_TOOLS = BridgeProtocol::SUPPORTED_TOOLS.dup.freeze` the
    # executors silently fork into separate frozen copies, defeating the
    # single-source-of-truth that B-054 extracted the module to establish.
    it 'binds StubBridge::SUPPORTED_TOOLS to the same frozen Array (not a copy)' do
      require 'woods/console/bridge'
      expect(Woods::Console::StubBridge::SUPPORTED_TOOLS)
        .to equal(described_class::SUPPORTED_TOOLS)
    end

    it 'binds EmbeddedExecutor::TIER1_TOOLS to the same frozen Array (not a copy)' do
      require 'woods/console/embedded_executor'
      expect(Woods::Console::EmbeddedExecutor::TIER1_TOOLS)
        .to equal(described_class::TIER1_TOOLS)
    end
  end
end
