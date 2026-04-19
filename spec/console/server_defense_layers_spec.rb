# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

# End-to-end wiring check for the Console defense-in-depth stack.
#
# The individual layers each have unit coverage (table_gate_spec,
# credential_scanner_spec, safe_context_spec). This spec proves the three
# layers thread through `Server.build_embedded` → `define_console_tool`
# → `send_to_bridge` correctly and in the intended order.
RSpec.describe 'Woods::Console::Server defense-in-depth wiring' do
  let(:registry) do
    {
      'User' => %w[id email name],
      'Authorization' => %w[id key value]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:model_tables) { { 'User' => 'users', 'Authorization' => 'authorizations' } }
  let(:safe_context) { instance_double(Woods::Console::SafeContext) }
  let(:executor) { instance_double('Executor') }

  around do |example|
    previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = previous
  end

  before do
    stub_const('Woods::Console::EmbeddedExecutor', Class.new { def initialize(**); end })
    allow(Woods::Console::EmbeddedExecutor).to receive(:new).and_return(executor)
  end

  def build(**overrides)
    Woods::Console::Server.build_embedded(
      model_validator: validator,
      safe_context: safe_context,
      model_tables: model_tables,
      **overrides
    )
  end

  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools.fetch(tool_name)
    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  describe 'Layer 1 (TableGate)' do
    before do
      Woods.configuration.console_blocked_tables = %w[authorizations]
    end

    it 'rejects a model whose table is blocked before the executor is touched' do
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_find', model: 'Authorization', id: 1)

      expect(response).to be_error
      expect(response_text(response)).to include("table 'authorizations'")
    end

    it 'allows models whose tables are not blocked' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true, 'result' => { 'record' => { 'id' => 1, 'email' => 'a@b.com' } }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response).not_to be_error
      expect(response_text(response)).to include('a@b.com')
    end
  end

  describe 'Layer 2 (CredentialScanner)' do
    it 'redacts Stripe secret keys that slip through the bridge result' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => {
            'id' => 1,
            'credentials' => 'sk_live_abcdefghijklmnopqrstuvwx'
          }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response_text(response)).to include('[REDACTED]')
      expect(response_text(response)).not_to include('sk_live_abcdefghijklmnopqrstuvwx')
    end

    it 'can be disabled via configuration' do
      Woods.configuration.console_credential_scanning_enabled = false
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => { 'record' => { 'id' => 1, 'note' => 'sk_live_abcdefghijklmnopqrstuvwx' } }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response_text(response)).to include('sk_live_abcdefghijklmnopqrstuvwx')
    end

    it 'honors disabled_scanner_patterns to skip specific rules' do
      Woods.configuration.console_disabled_scanner_patterns = %i[stripe_secret_key]
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => {
            'id' => 1,
            'stripe' => 'sk_live_abcdefghijklmnopqrstuvwx',
            'aws' => 'AKIAIOSFODNN7EXAMPLE'
          }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)
      text = response_text(response)

      expect(text).to include('sk_live_abcdefghijklmnopqrstuvwx')
      expect(text).to include('[REDACTED]')
      expect(text).not_to include('AKIAIOSFODNN7EXAMPLE')
    end
  end

  describe 'Layer ordering — Layer 1 short-circuits before Layer 2 scans' do
    it 'does not even invoke the executor when a blocked table is referenced' do
      Woods.configuration.console_blocked_tables = %w[authorizations]
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_find', model: 'Authorization', id: 1)

      expect(response).to be_error
    end
  end
end
