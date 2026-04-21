# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

RSpec.describe 'console_eval opt-in safety contract' do
  let(:registry) { { 'User' => %w[id email] } }
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:connection) { instance_double('Connection') }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    # Clear the flag across tests — it is env-backed and persistent otherwise.
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    Woods.configure { |c| c.console_unsafe_eval_enabled = nil }
  end

  after do
    ENV.delete('WOODS_CONSOLE_UNSAFE_EVAL')
    Woods.configure { |c| c.console_unsafe_eval_enabled = nil }
  end

  describe 'Woods::Console::Server.unsafe_eval_enabled?' do
    it 'defaults to false' do
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end

    it 'is true when WOODS_CONSOLE_UNSAFE_EVAL=true in the environment' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be true
    end

    it 'is false for WOODS_CONSOLE_UNSAFE_EVAL values other than "true"' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = '1'
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end

    it 'is true when console_unsafe_eval_enabled is explicitly set in config' do
      Woods.configure { |c| c.console_unsafe_eval_enabled = true }
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be true
    end

    it 'explicit config false overrides the env var' do
      ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'
      Woods.configure { |c| c.console_unsafe_eval_enabled = false }
      expect(Woods::Console::Server.unsafe_eval_enabled?).to be false
    end
  end

  describe 'console_eval tool description' do
    let(:server) do
      Woods::Console::Server.build_embedded(model_validator: validator, safe_context: safe_context)
    end
    let(:description) { server.instance_variable_get(:@tools)['console_eval'].description }

    it 'states the tool is currently disabled' do
      expect(description).to match(/disabled|refusal/i)
    end

    it 'instructs the agent to surface the proposed snippet to the user before invoking' do
      expect(description).to match(/show|surface|present/i)
      expect(description).to match(/before|first|manually/i)
    end

    it 'names console_query and console_sql as the alternatives' do
      expect(description).to include('console_query')
      expect(description).to include('console_sql')
    end
  end

  describe 'build_embedded with unsafe eval flag' do
    context 'when the flag is off (default)' do
      it 'does not emit a banner' do
        expect do
          Woods::Console::Server.build_embedded(
            model_validator: validator, safe_context: safe_context
          )
        end.not_to output(/WOODS_CONSOLE_UNSAFE_EVAL/).to_stderr
      end
    end

    context 'when the flag is on in a non-production environment' do
      before { ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true' }

      it 'emits a loud warning banner to stderr' do
        expect do
          Woods::Console::Server.build_embedded(
            model_validator: validator, safe_context: safe_context
          )
        end.to output(/WOODS_CONSOLE_UNSAFE_EVAL/).to_stderr
      end

      it 'still builds the server (eval remains disabled, not enabled by the flag)' do
        server = Woods::Console::Server.build_embedded(
          model_validator: validator, safe_context: safe_context
        )
        expect(server).to be_a(MCP::Server)
      end
    end

    context 'when the flag is on in Rails production' do
      before do
        ENV['WOODS_CONSOLE_UNSAFE_EVAL'] = 'true'
        rails = class_double('Rails').as_stubbed_const
        env = instance_double('Rails::Env', production?: true)
        allow(rails).to receive(:env).and_return(env)
      end

      it 'refuses to boot and raises a ConfigurationError' do
        expect do
          Woods::Console::Server.build_embedded(
            model_validator: validator, safe_context: safe_context
          )
        end.to raise_error(Woods::ConfigurationError, /production/i)
      end
    end
  end
end
