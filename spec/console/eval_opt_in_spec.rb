# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

RSpec.describe 'console_eval capability contract' do
  let(:registry) { { 'User' => %w[id email] } }
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:connection) { double('Connection') }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    Woods.configure { |config| config.console_unsafe_eval_enabled = nil }
  end

  after do
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    Woods.configure { |config| config.console_unsafe_eval_enabled = nil }
  end

  describe 'Woods::Console::Server.unsafe_eval_enabled?' do
    it 'defaults to false' do
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end

    it 'recognizes only the exact true environment value' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be true

      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = '1'
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end

    it 'lets explicit configuration override the environment' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'
      Woods.configure { |config| config.console_unsafe_eval_enabled = false }

      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end
  end

  describe 'supported registration' do
    it 'does not register console_eval in either embedded mode' do
      default_server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context
      )
      read_server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, read_tools_enabled: true
      )

      expect(default_server.instance_variable_get(:@tools)).not_to have_key('console_eval')
      expect(read_server.instance_variable_get(:@tools)).not_to have_key('console_eval')
    end
  end

  describe 'legacy unsafe-eval flag' do
    it 'fails closed instead of claiming eval is live' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'

      expect do
        Woods::Console::Server.build_embedded(
          model_validator: validator, safe_context: safe_context,
          unsafe_eval_confirmation: Woods::Console::Confirmation.new(mode: :auto_deny),
          unsafe_eval_audit_log_path: '/tmp/audit.jsonl'
        )
      end.to raise_error(Woods::ConfigurationError, /not available in a supported Console MCP mode/)
    end
  end
end
