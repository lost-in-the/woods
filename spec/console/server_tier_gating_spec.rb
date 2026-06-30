# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

# Covers the console toolset gating added for catalog-bloat reduction:
#   - Woods.configuration.console_enabled_tiers restricts which tiers register
#   - console_eval registers only under the unsafe-eval opt-in
#   - Configuration normalizes tier numbers, names, "all", and env input
RSpec.describe 'Woods::Console::Server tier gating' do
  let(:config) { { 'mode' => 'direct', 'command' => 'echo test' } }

  def tool_names(server)
    server.instance_variable_get(:@tools).keys
  end

  before do
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    Woods.configure do |c|
      c.console_enabled_tiers = [1, 2, 3, 4]
      c.console_unsafe_eval_enabled = nil
    end
  end

  after do
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    ENV.delete('WOODS_CONSOLE_TIERS')
    Woods.configure do |c|
      c.console_enabled_tiers = [1, 2, 3, 4]
      c.console_unsafe_eval_enabled = nil
    end
  end

  describe 'console_enabled_tiers restricts the registered catalog' do
    it 'registers only Tier 1 tools when configured to [1]' do
      Woods.configure { |c| c.console_enabled_tiers = [1] }
      names = tool_names(described_class_server)

      Woods::Console::Server::TIER1_TOOLS.each { |t| expect(names).to include("console_#{t}") }
      (Woods::Console::Server::TIER2_TOOLS +
       Woods::Console::Server::TIER3_TOOLS +
       Woods::Console::Server::TIER4_TOOLS).each do |t|
        expect(names).not_to include("console_#{t}")
      end
    end

    it 'supports toolset names (read + analytics => tiers 1 and 3)' do
      Woods.configure { |c| c.console_enabled_tiers = %w[read analytics] }
      names = tool_names(described_class_server)

      expect(names).to include('console_count') # tier 1
      expect(names).to include('console_slow_endpoints') # tier 3
      expect(names).not_to include('console_diagnose_model') # tier 2
      expect(names).not_to include('console_sql')            # tier 4
    end

    it 'registers all four tiers by default (eval excepted)' do
      names = tool_names(described_class_server)
      expect(names).to include('console_count', 'console_diagnose_model',
                               'console_slow_endpoints', 'console_sql', 'console_query')
      expect(names).not_to include('console_eval')
    end
  end

  describe 'console_eval gating' do
    it 'is absent when the unsafe-eval opt-in is off (default)' do
      expect(tool_names(described_class_server)).not_to include('console_eval')
    end

    it 'registers when console_unsafe_eval_enabled is true and tier 4 is enabled' do
      Woods.configure { |c| c.console_unsafe_eval_enabled = true }
      expect(tool_names(described_class_server)).to include('console_eval')
    end

    it 'stays absent when enabled via opt-in but tier 4 is not selected' do
      Woods.configure do |c|
        c.console_unsafe_eval_enabled = true
        c.console_enabled_tiers = [1]
      end
      expect(tool_names(described_class_server)).not_to include('console_eval')
    end
  end

  # Build a bridge-mode server (no Rails needed) under the current config.
  def described_class_server
    Woods::Console::Server.build(config: config)
  end
end

RSpec.describe Woods::Configuration, '#console_enabled_tiers' do
  subject(:configuration) { described_class.new }

  around do |example|
    saved = ENV.fetch('WOODS_CONSOLE_TIERS', nil)
    ENV.delete('WOODS_CONSOLE_TIERS')
    example.run
    saved.nil? ? ENV.delete('WOODS_CONSOLE_TIERS') : ENV['WOODS_CONSOLE_TIERS'] = saved
  end

  it 'defaults to all four tiers' do
    expect(configuration.console_enabled_tiers).to eq([1, 2, 3, 4])
  end

  it 'normalizes, de-duplicates, and sorts integer input' do
    configuration.console_enabled_tiers = [3, 1, 1]
    expect(configuration.console_enabled_tiers).to eq([1, 3])
  end

  it 'accepts toolset names' do
    configuration.console_enabled_tiers = %w[read analytics]
    expect(configuration.console_enabled_tiers).to eq([1, 3])
  end

  it 'accepts "all"' do
    configuration.console_enabled_tiers = 'all'
    expect(configuration.console_enabled_tiers).to eq([1, 2, 3, 4])
  end

  it 'accepts a comma-joined string' do
    configuration.console_enabled_tiers = '1,3'
    expect(configuration.console_enabled_tiers).to eq([1, 3])
  end

  it 'raises on an empty selection' do
    expect { configuration.console_enabled_tiers = [] }
      .to raise_error(Woods::ConfigurationError, /at least one tier/)
  end

  it 'raises on an unknown toolset name' do
    expect { configuration.console_enabled_tiers = %w[bogus] }
      .to raise_error(Woods::ConfigurationError, /unknown console tier/)
  end

  it 'raises on an out-of-range tier number' do
    expect { configuration.console_enabled_tiers = [5] }
      .to raise_error(Woods::ConfigurationError, /1-4/)
  end

  it 'reads WOODS_CONSOLE_TIERS from the environment at construction' do
    ENV['WOODS_CONSOLE_TIERS'] = 'read,analytics'
    expect(described_class.new.console_enabled_tiers).to eq([1, 3])
  end
end
