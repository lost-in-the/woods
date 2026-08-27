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

  describe 'sharing across executors' do
    it 'binds EmbeddedExecutor::TIER1_TOOLS to the same frozen Array (not a copy)' do
      require 'woods/console/embedded_executor'
      expect(Woods::Console::EmbeddedExecutor::TIER1_TOOLS)
        .to equal(described_class::TIER1_TOOLS)
    end
  end
end
